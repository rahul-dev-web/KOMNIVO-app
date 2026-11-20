-- Trigger functions are SECURITY DEFINER; use session_user, not current_user,
-- to distinguish database-owned cron execution from PostgREST callers.
create or replace function app_private.guard_batch3_channel_message()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_settings public.channel_settings%rowtype;
  v_last_sent timestamptz;
  v_kind text;
  v_community_id uuid;
begin
  if session_user='postgres' or auth.role()='service_role' then return new; end if;
  select c.kind,c.community_id into v_kind,v_community_id
  from public.channels c where c.id=new.channel_id and c.archived_at is null;
  if v_kind is null then raise exception 'Channel is unavailable or archived'; end if;
  select * into v_settings from public.channel_settings where channel_id=new.channel_id;
  if v_settings.channel_id is not null and v_settings.read_only
    and not app_private.resolve_permission('channel.manage_messages','community',v_community_id,null,new.channel_id)
  then raise exception 'This channel is read-only'; end if;
  if not app_private.can_send_channel_message(new.channel_id)
    and not app_private.resolve_permission('channel.manage_messages','community',v_community_id,null,new.channel_id)
  then raise exception 'You cannot send messages in this channel'; end if;
  if v_settings.channel_id is not null then
    if v_settings.announcement_publishers_only
      and not app_private.resolve_permission('channel.manage_messages','community',v_community_id,null,new.channel_id)
    then raise exception 'Only authorised announcement publishers can post'; end if;
    if not v_settings.allow_links and new.body ~* '(https?://|www\\.)'
    then raise exception 'Links are disabled in this channel'; end if;
    if not v_settings.allow_everyone_mention and new.body ~ '(^|[[:space:]])@everyone([[:space:]]|$)'
    then raise exception '@everyone mentions are disabled in this channel'; end if;
    if not v_settings.allow_role_mentions and new.body ~ '<@&[0-9a-fA-F-]{36}>'
    then raise exception 'Role mentions are disabled in this channel'; end if;
    if not v_settings.allow_user_mentions and new.body ~ '<@[0-9a-fA-F-]{36}>'
    then raise exception 'User mentions are disabled in this channel'; end if;
    if v_settings.slow_mode_seconds > 0
      and not app_private.resolve_permission('channel.manage_messages','community',v_community_id,null,new.channel_id)
    then
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
begin
  if session_user='postgres' or auth.role()='service_role' then return new; end if;
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if old.author_id = auth.uid()
    and not app_private.resolve_permission('channel.manage_messages','community',old.community_id,null,old.channel_id)
  then
    if new.author_id is distinct from old.author_id
      or new.community_id is distinct from old.community_id
      or new.channel_id is distinct from old.channel_id
      or new.status is distinct from old.status
      or new.is_locked is distinct from old.is_locked
      or new.is_pinned is distinct from old.is_pinned
    then raise exception 'Authors may edit topic content, not moderation state'; end if;
  elsif not app_private.resolve_permission('channel.manage_messages','community',old.community_id,null,old.channel_id)
  then raise exception 'You cannot moderate this forum post';
  end if;
  return new;
end;
$function$;

create or replace function app_private.guard_batch3_attachment_insert()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_channel_id uuid; v_allowed boolean;
begin
  if session_user='postgres' or auth.role()='service_role' then return new; end if;
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
  if session_user='postgres' or auth.role()='service_role' then return new; end if;
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
  if session_user='postgres' or auth.role()='service_role' then return new; end if;
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
  if new.created_by <> auth.uid()
    and not app_private.resolve_permission('channel.manage_messages','community',old.community_id,null,old.channel_id)
  then raise exception 'You cannot update this announcement'; end if;
  return new;
end;
$function$;
