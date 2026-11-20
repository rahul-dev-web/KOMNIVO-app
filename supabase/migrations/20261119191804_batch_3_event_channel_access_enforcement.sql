-- Batch 3: make event-scoped channels writable by the same authorised audiences
-- that can read them, while keeping event staff moderation and private match
-- visibility governed by the existing event/match scope resolvers.

create or replace function app_private.can_manage_event_channel(p_channel_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists (
    select 1
    from public.channels c
    where c.id=p_channel_id and c.event_id is not null
      and (
        app_private.resolve_permission('event.manage','event',c.event_id,null,null)
        or app_private.resolve_permission('event.matches.operate','event',c.event_id,null,null)
        or (c.match_id is not null and (
          app_private.resolve_permission('match.operate','match',c.match_id,null,null)
          or app_private.resolve_permission('match.results.review','match',c.match_id,null,null)
          or app_private.resolve_permission('match.disputes.review','match',c.match_id,null,null)
        ))
        or (c.stage_id is not null and app_private.has_stage_staff_scope(
          c.stage_id,
          array['competition_manager','tournament_director','match_operator','referee','result_reviewer','dispute_reviewer','support_staff']::text[]
        ))
      )
  );
$function$;
revoke all on function app_private.can_manage_event_channel(uuid) from public,anon;
grant execute on function app_private.can_manage_event_channel(uuid) to authenticated;

create or replace function app_private.can_view_channel_resource(p_channel_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists (
    select 1 from public.channels c
    where c.id=p_channel_id and (
      (c.event_id is not null and app_private.can_access_event_channel_scope(
        c.event_id,c.stage_id,c.group_id,c.match_id,c.id
      ))
      or
      (c.event_id is null and c.community_id is not null and app_private.resolve_permission(
        'channel.view','community',c.community_id,null,c.id
      ))
    )
  );
$function$;
revoke all on function app_private.can_view_channel_resource(uuid) from public,anon;
grant execute on function app_private.can_view_channel_resource(uuid) to authenticated;

create or replace function app_private.can_manage_channel(p_channel_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists (
    select 1 from public.channels c
    where c.id=p_channel_id and (
      (c.event_id is not null and app_private.can_manage_event_channel(c.id))
      or
      (c.event_id is null and c.community_id is not null and app_private.resolve_permission(
        'community.manage_structure','community',c.community_id,null,null
      ))
    )
  );
$function$;
revoke all on function app_private.can_manage_channel(uuid) from public,anon;
grant execute on function app_private.can_manage_channel(uuid) to authenticated;

create or replace function app_private.can_send_channel_message(p_channel_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists (
    select 1 from public.channels c
    where c.id=p_channel_id and c.archived_at is null and (
      (c.event_id is not null and app_private.can_access_event_channel_scope(
        c.event_id,c.stage_id,c.group_id,c.match_id,c.id
      ))
      or
      (c.event_id is null and c.community_id is not null and app_private.resolve_permission(
        'channel.send_messages','community',c.community_id,null,c.id
      ))
    )
  ) and not coalesce((select cs.read_only from public.channel_settings cs where cs.channel_id=p_channel_id),false);
$function$;
revoke all on function app_private.can_send_channel_message(uuid) from public,anon;
grant execute on function app_private.can_send_channel_message(uuid) to authenticated;

create or replace function app_private.guard_batch3_channel_message()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_settings public.channel_settings%rowtype;
  v_last_sent timestamptz;
  v_channel public.channels%rowtype;
  v_can_manage boolean;
begin
  if session_user='postgres' or auth.role()='service_role' then return new; end if;
  select * into v_channel from public.channels c
  where c.id=new.channel_id and c.archived_at is null;
  if not found then raise exception 'Channel is unavailable or archived'; end if;
  select * into v_settings from public.channel_settings where channel_id=new.channel_id;

  v_can_manage := case
    when v_channel.event_id is not null then app_private.can_manage_event_channel(v_channel.id)
    else app_private.resolve_permission('channel.manage_messages','community',v_channel.community_id,null,v_channel.id)
  end;

  if v_settings.channel_id is not null and v_settings.read_only and not v_can_manage
  then raise exception 'This channel is read-only'; end if;
  if not app_private.can_send_channel_message(new.channel_id) and not v_can_manage
  then raise exception 'You cannot send messages in this channel'; end if;
  if new.parent_message_id is not null and v_settings.channel_id is not null
    and not v_settings.allow_threads and not v_can_manage
  then raise exception 'Message threads are disabled in this channel'; end if;
  if v_settings.channel_id is not null then
    if v_settings.announcement_publishers_only and not v_can_manage
    then raise exception 'Only authorised announcement publishers can post'; end if;
    if not v_settings.allow_links and new.body ~* '(https?://|www\\.)'
    then raise exception 'Links are disabled in this channel'; end if;
    if not v_settings.allow_everyone_mention and new.body ~ '(^|[[:space:]])@everyone([[:space:]]|$)'
    then raise exception '@everyone mentions are disabled in this channel'; end if;
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

create or replace function app_private.guard_batch3_message_pin()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_allowed boolean; v_channel_id uuid; v_event_id uuid; v_community_id uuid;
begin
  if session_user='postgres' or auth.role()='service_role' then return case when tg_op='DELETE' then old else new end; end if;
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

drop policy if exists message_pins_manage_event_staff on public.message_pins;
create policy message_pins_manage_event_staff on public.message_pins
for all to authenticated
using (exists(
  select 1 from public.channels c where c.id=message_pins.channel_id
    and c.event_id is not null and app_private.can_manage_event_channel(c.id)
))
with check (exists(
  select 1 from public.channels c where c.id=message_pins.channel_id
    and c.event_id is not null and app_private.can_manage_event_channel(c.id)
));

create or replace function app_private.guard_forum_post_moderation_fields()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_can_moderate boolean;
begin
  if session_user='postgres' or auth.role()='service_role' then return new; end if;
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_can_moderate := case
    when old.community_id is not null and exists(select 1 from public.channels c where c.id=old.channel_id and c.event_id is not null)
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
    raise exception 'You cannot moderate this forum post';
  end if;
  return new;
end;
$function$;

create or replace function public.set_forum_post_status(p_post_id uuid,p_status text,p_locked boolean default null,p_pinned boolean default null)
returns public.forum_posts language plpgsql security invoker set search_path = ''
as $function$
declare
  v_post public.forum_posts%rowtype;
  v_can_moderate boolean;
begin
  if p_status not in ('Open','In discussion','Filled','Closed') then raise exception 'Invalid forum status'; end if;
  select * into v_post from public.forum_posts where id=p_post_id for update;
  if not found then raise exception 'Forum post not found'; end if;
  select case
    when c.event_id is not null then app_private.can_manage_event_channel(c.id)
    else app_private.resolve_permission('channel.manage_messages','community',v_post.community_id,null,v_post.channel_id)
  end into v_can_moderate
  from public.channels c where c.id=v_post.channel_id;
  if not coalesce(v_can_moderate,false) then raise exception 'You cannot moderate this forum'; end if;
  update public.forum_posts set status=p_status,
    is_locked=coalesce(p_locked,is_locked), is_pinned=coalesce(p_pinned,is_pinned),updated_at=now()
  where id=p_post_id returning * into v_post;
  return v_post;
end;
$function$;

drop policy if exists forum_posts_moderate on public.forum_posts;
create policy forum_posts_moderate on public.forum_posts for update to authenticated
using (exists(select 1 from public.channels c where c.id=forum_posts.channel_id and (
  (c.event_id is not null and app_private.can_manage_event_channel(c.id))
  or (c.event_id is null and app_private.resolve_permission('channel.manage_messages','community',c.community_id,null,c.id))
)))
with check (exists(select 1 from public.channels c where c.id=forum_posts.channel_id and (
  (c.event_id is not null and app_private.can_manage_event_channel(c.id))
  or (c.event_id is null and app_private.resolve_permission('channel.manage_messages','community',c.community_id,null,c.id))
)));

drop policy if exists channel_polls_moderate on public.channel_polls;
create policy channel_polls_moderate on public.channel_polls for update to authenticated
using (exists(select 1 from public.channels c where c.id=channel_polls.channel_id and (
  (c.event_id is not null and app_private.can_manage_event_channel(c.id))
  or (c.event_id is null and app_private.resolve_permission('channel.manage_messages','community',c.community_id,null,c.id))
)))
with check (exists(select 1 from public.channels c where c.id=channel_polls.channel_id and (
  (c.event_id is not null and app_private.can_manage_event_channel(c.id))
  or (c.event_id is null and app_private.resolve_permission('channel.manage_messages','community',c.community_id,null,c.id))
)));

drop policy if exists poll_options_manage on public.channel_poll_options;
create policy poll_options_manage on public.channel_poll_options for delete to authenticated
using (exists(select 1 from public.channel_polls p join public.channels c on c.id=p.channel_id
  where p.id=poll_id and (p.created_by=auth.uid()
    or (c.event_id is not null and app_private.can_manage_event_channel(c.id))
    or (c.event_id is null and app_private.resolve_permission('channel.manage_messages','community',c.community_id,null,c.id)))));

drop policy if exists scheduled_announcements_read on public.scheduled_channel_announcements;
create policy scheduled_announcements_read on public.scheduled_channel_announcements for select to authenticated
using (app_private.can_view_channel_resource(channel_id) and (
  created_by=auth.uid() or app_private.can_manage_channel(channel_id)
));
drop policy if exists scheduled_announcements_create on public.scheduled_channel_announcements;
create policy scheduled_announcements_create on public.scheduled_channel_announcements for insert to authenticated
with check (created_by=auth.uid() and app_private.can_manage_channel(channel_id));
drop policy if exists scheduled_announcements_update on public.scheduled_channel_announcements;
create policy scheduled_announcements_update on public.scheduled_channel_announcements for update to authenticated
using (created_by=auth.uid() or app_private.can_manage_channel(channel_id))
with check (created_by=auth.uid() or app_private.can_manage_channel(channel_id));

