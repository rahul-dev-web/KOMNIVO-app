-- Batch 3 backend hardening and atomic poll creation.
create or replace function app_private.guard_batch3_channel_message()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_settings public.channel_settings%rowtype;
  v_last_sent timestamptz;
  v_kind text;
  v_community_id uuid;
begin
  -- Scheduled publisher uses a service-role-only RPC and is allowed to bypass
  -- user posting throttles; direct client calls cannot assume this role.
  if auth.role() = 'service_role' then return new; end if;

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
  if auth.role() = 'service_role' then return new; end if;
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
revoke all on function app_private.guard_forum_post_moderation_fields() from public,anon,authenticated;
drop trigger if exists forum_posts_moderation_guard on public.forum_posts;
create trigger forum_posts_moderation_guard before update on public.forum_posts
for each row execute function app_private.guard_forum_post_moderation_fields();

create or replace function public.create_channel_poll(
  p_channel_id uuid, p_community_id uuid, p_question text,
  p_options text[], p_allow_multiple boolean default false, p_closes_at timestamptz default null
) returns uuid language plpgsql security invoker set search_path = ''
as $function$
declare v_poll_id uuid; v_option text; v_position integer := 0;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if char_length(trim(p_question)) not between 3 and 240 then raise exception 'Poll question must be 3-240 characters'; end if;
  if cardinality(p_options) not between 2 and 20 then raise exception 'A poll needs 2-20 options'; end if;
  if exists(select 1 from unnest(p_options) o where char_length(trim(o)) not between 1 and 120)
  then raise exception 'Poll options must be 1-120 characters'; end if;
  if p_closes_at is not null and p_closes_at <= now() then raise exception 'Poll closing time must be in the future'; end if;
  if not exists(select 1 from public.channels c where c.id=p_channel_id and c.community_id=p_community_id and c.archived_at is null)
  then raise exception 'Channel/community mismatch'; end if;
  if not app_private.can_send_channel_message(p_channel_id) then raise exception 'You cannot create a poll in this channel'; end if;
  insert into public.channel_polls(channel_id,community_id,created_by,question,allow_multiple,closes_at)
  values(p_channel_id,p_community_id,auth.uid(),trim(p_question),p_allow_multiple,p_closes_at)
  returning id into v_poll_id;
  foreach v_option in array p_options loop
    insert into public.channel_poll_options(poll_id,label,position)
    values(v_poll_id,trim(v_option),v_position);
    v_position := v_position+1;
  end loop;
  return v_poll_id;
end;
$function$;
revoke all on function public.create_channel_poll(uuid,uuid,text,text[],boolean,timestamptz) from public,anon;
grant execute on function public.create_channel_poll(uuid,uuid,text,text[],boolean,timestamptz) to authenticated;

create or replace function public.cancel_channel_announcement(p_announcement_id uuid)
returns boolean language plpgsql security invoker set search_path = ''
as $function$
declare v_row public.scheduled_channel_announcements%rowtype;
begin
  select * into v_row from public.scheduled_channel_announcements where id=p_announcement_id for update;
  if not found then return false; end if;
  if v_row.created_by <> auth.uid()
    and not app_private.resolve_permission('channel.manage_messages','community',v_row.community_id,null,v_row.channel_id)
  then raise exception 'You cannot cancel this announcement'; end if;
  if v_row.status <> 'scheduled' then return false; end if;
  update public.scheduled_channel_announcements set status='cancelled',updated_at=now() where id=p_announcement_id;
  return true;
end;
$function$;
revoke all on function public.cancel_channel_announcement(uuid) from public,anon;
grant execute on function public.cancel_channel_announcement(uuid) to authenticated;
