-- Batch 3 trigger bypass must distinguish a true database maintenance/cron
-- session from a test/client session that temporarily SET ROLE authenticated.
create or replace function app_private.is_batch3_maintenance_context()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select
    (
      session_user = 'postgres'
      and coalesce(current_setting('role', true), 'none') in ('none','')
    )
    or coalesce(auth.role(), '') = 'service_role';
$function$;
revoke all on function app_private.is_batch3_maintenance_context() from public,anon,authenticated;

create or replace function app_private.guard_batch3_channel_message()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_settings public.channel_settings%rowtype;
  v_last_sent timestamptz;
  v_channel public.channels%rowtype;
  v_can_manage boolean;
  v_announcement_publishers_only boolean;
begin
  if app_private.is_batch3_maintenance_context() then return new; end if;

  select * into v_channel from public.channels c
  where c.id=new.channel_id and c.archived_at is null;
  if not found then raise exception 'Channel is unavailable or archived'; end if;
  select * into v_settings from public.channel_settings where channel_id=new.channel_id;

  v_can_manage := case
    when v_channel.event_id is not null then app_private.can_manage_event_channel(v_channel.id)
    else app_private.resolve_permission('channel.manage_messages','community',v_channel.community_id,null,v_channel.id)
  end;
  v_announcement_publishers_only := case
    when v_settings.channel_id is null then v_channel.kind='announcement'
    else v_settings.announcement_publishers_only
  end;

  if v_settings.channel_id is not null and v_settings.read_only and not v_can_manage
  then raise exception 'This channel is read-only'; end if;
  if not app_private.can_send_channel_message(new.channel_id) and not v_can_manage
  then raise exception 'You cannot send messages in this channel'; end if;
  if new.parent_message_id is not null and v_settings.channel_id is not null
    and not v_settings.allow_threads and not v_can_manage
  then raise exception 'Message threads are disabled in this channel'; end if;

  if v_announcement_publishers_only and not v_can_manage
  then raise exception 'Only authorised announcement publishers can post'; end if;
  if v_settings.channel_id is not null then
    if not v_settings.allow_links and new.body ~* '(https?://|www[.])'
    then raise exception 'Links are disabled in this channel'; end if;
    if not v_settings.allow_everyone_mention
      and new.body ~* '(^|[[:space:]])@(everyone|here)([[:space:]]|$)'
    then raise exception 'Broad mentions are disabled in this channel'; end if;
    if not v_settings.allow_role_mentions and new.body ~ '<@&[0-9a-fA-F-]{36}>'
    then raise exception 'Role mentions are disabled in this channel'; end if;
    if not v_settings.allow_user_mentions and new.body ~ '<@[0-9a-fA-F-]{36}>'
    then raise exception 'User mentions are disabled in this channel'; end if;

    if v_settings.slow_mode_seconds > 0 and not v_can_manage then
      perform pg_advisory_xact_lock(hashtextextended(new.channel_id::text||':'||new.sender_id::text,0));
      select max(m.created_at) into v_last_sent from public.messages m
      where m.channel_id=new.channel_id and m.sender_id=new.sender_id and m.deleted_at is null;
      if v_last_sent is not null and v_last_sent > now() - make_interval(secs => v_settings.slow_mode_seconds)
      then raise exception 'Slow mode is active. Please wait before sending again'; end if;
    end if;
  end if;
  return new;
end;
$function$;

create or replace function app_private.guard_forum_post_moderation_fields()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_can_moderate boolean;
begin
  if app_private.is_batch3_maintenance_context() then return new; end if;
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  v_can_moderate := case
    when old.community_id is not null
      and exists(select 1 from public.channels c where c.id=old.channel_id and c.event_id is not null)
      then app_private.can_manage_event_channel(old.channel_id)
    else app_private.resolve_permission('channel.manage_messages','community',old.community_id,null,old.channel_id)
  end;
  if old.author_id = auth.uid() and not v_can_moderate then
    if new.author_id is distinct from old.author_id
      or new.community_id is distinct from old.community_id
      or new.channel_id is distinct from old.channel_id
      or new.status is distinct from old.status
      or new.is_locked is distinct from old.is_locked
      or new.is_pinned is distinct from old.is_pinned
    then raise exception 'Authors may edit topic content, not moderation state'; end if;
  elsif not v_can_moderate then
    raise exception 'You cannot moderate this forum';
  end if;
  return new;
end;
$function$;

create or replace function app_private.guard_batch3_attachment_insert()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_channel_id uuid; v_allowed boolean;
begin
  if app_private.is_batch3_maintenance_context() then return new; end if;
  select m.channel_id into v_channel_id from public.messages m where m.id=new.message_id;
  if v_channel_id is null then raise exception 'Attachment message does not exist'; end if;
  select coalesce(cs.allow_attachments,true) into v_allowed
    from public.channel_settings cs where cs.channel_id=v_channel_id;
  if not coalesce(v_allowed,true) then raise exception 'Attachments are disabled in this channel'; end if;
  if not app_private.can_send_channel_message(v_channel_id) then
    raise exception 'You cannot attach files in this channel';
  end if;
  return new;
end;
$function$;

create or replace function app_private.guard_batch3_poll_vote()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_multiple boolean; v_closed timestamptz; v_channel uuid; v_count integer;
begin
  if app_private.is_batch3_maintenance_context() then return new; end if;
  select p.allow_multiple,p.closes_at,p.channel_id into v_multiple,v_closed,v_channel
    from public.channel_polls p where p.id=new.poll_id;
  if v_channel is null then raise exception 'Poll not found'; end if;
  if new.user_id is distinct from auth.uid() then raise exception 'You can only cast your own vote'; end if;
  if v_closed is not null and v_closed <= now() then raise exception 'Poll is closed'; end if;
  if not app_private.can_view_channel_resource(v_channel) then raise exception 'You cannot vote in this poll'; end if;
  if not v_multiple then
    select count(*) into v_count from public.channel_poll_votes
      where poll_id=new.poll_id and user_id=new.user_id;
    if v_count > 0 then raise exception 'This poll allows one choice only'; end if;
  end if;
  return new;
end;
$function$;

create or replace function app_private.guard_batch3_announcement_update()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  if app_private.is_batch3_maintenance_context() then return new; end if;
  if new.id is distinct from old.id or new.channel_id is distinct from old.channel_id
    or new.community_id is distinct from old.community_id
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
    or new.published_message_id is distinct from old.published_message_id
    or new.published_at is distinct from old.published_at
    or new.failure_reason is distinct from old.failure_reason
  then raise exception 'Announcement identity and publisher fields are immutable'; end if;
  if old.status <> 'scheduled' then raise exception 'Only scheduled announcements can be changed'; end if;
  if new.status not in ('scheduled','cancelled') then raise exception 'Only the scheduler can publish announcements'; end if;
  if new.publish_at <= now() and new.status='scheduled' then raise exception 'Publish time must be in the future'; end if;
  if new.created_by <> auth.uid() and not public.can_manage_channel_messages(old.channel_id)
  then raise exception 'You cannot update this announcement'; end if;
  return new;
end;
$function$;

create or replace function app_private.guard_batch3_message_pin()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_allowed boolean; v_channel_id uuid; v_event_id uuid; v_community_id uuid;
begin
  if app_private.is_batch3_maintenance_context() then
    return case when tg_op='DELETE' then old else new end;
  end if;
  v_channel_id := case when tg_op='DELETE' then old.channel_id else new.channel_id end;
  select c.event_id,c.community_id into v_event_id,v_community_id
  from public.channels c where c.id=v_channel_id;
  select coalesce(cs.allow_pins,true) into v_allowed
  from public.channel_settings cs where cs.channel_id=v_channel_id;
  if not coalesce(v_allowed,true) then raise exception 'Pins are disabled in this channel'; end if;
  if v_event_id is not null then
    if not app_private.can_manage_event_channel(v_channel_id) then
      raise exception 'You cannot manage pinned messages in this event channel';
    end if;
  elsif not app_private.resolve_permission('channel.manage_messages','community',v_community_id,null,v_channel_id) then
    raise exception 'You cannot manage pinned messages in this channel';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$function$;
