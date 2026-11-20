-- Batch 3: align attachment, pin, forum and scheduled-announcement moderation
-- paths with the canonical community/event channel permission resolver.

drop policy if exists message_pins_manage_community_staff on public.message_pins;
create policy message_pins_manage_community_staff on public.message_pins
for all to authenticated
using (exists(
  select 1 from public.channels c
  where c.id=message_pins.channel_id and c.event_id is null
    and c.community_id is not null
    and app_private.resolve_permission('channel.manage_messages','community',c.community_id,null,c.id)
))
with check (exists(
  select 1 from public.channels c
  where c.id=message_pins.channel_id and c.event_id is null
    and c.community_id is not null
    and app_private.resolve_permission('channel.manage_messages','community',c.community_id,null,c.id)
));

drop policy if exists forum_replies_author_delete on public.forum_post_replies;
create policy forum_replies_author_delete on public.forum_post_replies
for delete to authenticated
using (
  author_id=auth.uid()
  or exists(
    select 1 from public.forum_posts p
    join public.channels c on c.id=p.channel_id
    where p.id=forum_post_replies.post_id and (
      (c.event_id is not null and app_private.can_manage_event_channel(c.id))
      or (c.event_id is null and app_private.resolve_permission('channel.manage_messages','community',c.community_id,null,c.id))
    )
  )
);

drop policy if exists scheduled_announcements_create on public.scheduled_channel_announcements;
create policy scheduled_announcements_create on public.scheduled_channel_announcements
for insert to authenticated
with check (
  created_by=auth.uid()
  and public.can_manage_channel_messages(channel_id)
);

drop policy if exists scheduled_announcements_read on public.scheduled_channel_announcements;
create policy scheduled_announcements_read on public.scheduled_channel_announcements
for select to authenticated
using (
  app_private.can_view_channel_resource(channel_id)
  and (created_by=auth.uid() or public.can_manage_channel_messages(channel_id))
);

drop policy if exists scheduled_announcements_update on public.scheduled_channel_announcements;
create policy scheduled_announcements_update on public.scheduled_channel_announcements
for update to authenticated
using (created_by=auth.uid() or public.can_manage_channel_messages(channel_id))
with check (created_by=auth.uid() or public.can_manage_channel_messages(channel_id));

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
  if new.created_by <> auth.uid() and not public.can_manage_channel_messages(old.channel_id)
  then raise exception 'You cannot update this announcement'; end if;
  return new;
end;
$function$;

create or replace function public.cancel_channel_announcement(p_announcement_id uuid)
returns boolean language plpgsql security invoker set search_path = ''
as $function$
declare v_row public.scheduled_channel_announcements%rowtype;
begin
  select * into v_row from public.scheduled_channel_announcements where id=p_announcement_id for update;
  if not found then return false; end if;
  if v_row.created_by <> auth.uid()
    and not public.can_manage_channel_messages(v_row.channel_id)
  then raise exception 'You cannot cancel this announcement'; end if;
  if v_row.status <> 'scheduled' then return false; end if;
  update public.scheduled_channel_announcements set status='cancelled',updated_at=now() where id=p_announcement_id;
  return true;
end;
$function$;
revoke all on function public.cancel_channel_announcement(uuid) from public,anon;
grant execute on function public.cancel_channel_announcement(uuid) to authenticated;

-- Attachments use the same channel visibility helper for private event channels.
drop policy if exists message_attachments_read_channel_member on public.message_attachments;
create policy message_attachments_read_channel_member on public.message_attachments
for select to authenticated
using (exists(
  select 1 from public.messages m
  join public.channels c on c.id=m.channel_id
  where m.id=message_attachments.message_id
    and (
      app_private.can_view_channel_resource(c.id)
      or (c.community_id is null and app_private.is_channel_member(c.id))
    )
));

drop policy if exists community_media_read_member on storage.objects;
create policy community_media_read_member on storage.objects
for select to authenticated
using (
  bucket_id='community-media'
  and (
    (storage.foldername(name))[1]=(select auth.uid())::text
    or exists(
      select 1
      from public.message_attachments ma
      join public.messages m on m.id=ma.message_id
      join public.channels c on c.id=m.channel_id
      where ma.storage_path=objects.name
        and (
          app_private.can_view_channel_resource(c.id)
          or (c.community_id is null and app_private.is_channel_member(c.id))
        )
    )
  )
);

-- Lifecycle notifications go to channel members, active event registrants and
-- staff assigned at the event/stage/group/match scope.
create or replace function app_private.apply_event_channel_lifecycle(
  p_event_id uuid,p_scope_type text,p_scope_id uuid,p_trigger text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_rule public.event_channel_lifecycle_rules%rowtype;
  v_rows integer;
  v_affected integer := 0;
begin
  for v_rule in
    select * from public.event_channel_lifecycle_rules
    where event_id=p_event_id and scope_type=p_scope_type
      and scope_id is not distinct from p_scope_id
      and lifecycle_trigger=p_trigger and enabled
  loop
    if v_rule.action='archive' then
      update public.channels set archived_at=coalesce(archived_at,now())
      where event_id=p_event_id
        and (not v_rule.only_temporary or is_temporary)
        and (case p_scope_type
          when 'stage' then stage_id=p_scope_id
          when 'group' then group_id=p_scope_id
          when 'match' then match_id=p_scope_id
          else true end);
    else
      insert into public.channel_settings(channel_id,community_id,read_only)
      select c.id,c.community_id,true from public.channels c
      where c.event_id=p_event_id
        and (not v_rule.only_temporary or c.is_temporary)
        and (case p_scope_type
          when 'stage' then c.stage_id=p_scope_id
          when 'group' then c.group_id=p_scope_id
          when 'match' then c.match_id=p_scope_id
          else true end)
      on conflict(channel_id) do update set read_only=true,updated_at=now();
    end if;
    get diagnostics v_rows = row_count;
    v_affected := v_affected + v_rows;

    if v_rule.notify_affected then
      insert into public.notifications(user_id,title,body,kind,entity_type,entity_id)
      select distinct recipient.user_id,
        'Event communication access updated',
        'A '||p_scope_type||' communication channel was '||
          case when v_rule.action='archive' then 'archived' else 'locked for new messages' end||
          ' after the configured '||p_trigger||' lifecycle step. Official event records were preserved.',
        'event','event',p_event_id
      from (
        select cm.user_id
        from public.channels c
        join public.channel_members cm on cm.channel_id=c.id
        where c.event_id=p_event_id
          and (not v_rule.only_temporary or c.is_temporary)
          and (case p_scope_type
            when 'stage' then c.stage_id=p_scope_id
            when 'group' then c.group_id=p_scope_id
            when 'match' then c.match_id=p_scope_id
            else true end)
        union
        select coalesce(rp.user_id,er.captain_user_id) as user_id
        from public.event_registrations er
        left join public.registration_players rp on rp.registration_id=er.id
        where er.event_id=p_event_id
          and er.status in ('approved','checked_in')
          and case p_scope_type
            when 'event' then true
            when 'stage' then exists(
              select 1 from public.event_group_teams egt
              join public.event_groups eg on eg.id=egt.group_id
              where eg.round_id=p_scope_id and egt.team_id=er.team_id
            )
            when 'group' then exists(
              select 1 from public.event_group_teams egt
              where egt.group_id=p_scope_id and egt.team_id=er.team_id
            )
            when 'match' then exists(
              select 1 from public.match_participants mp
              where mp.match_id=p_scope_id and mp.registration_id=er.id
            )
            else false end
        union
        select esa.user_id
        from public.event_staff_assignments esa
        where esa.event_id=p_event_id
          and (
            esa.scope_type='event'
            or (p_scope_type='stage' and esa.stage_id=p_scope_id)
            or (p_scope_type='group' and esa.group_id=p_scope_id)
            or (p_scope_type='match' and esa.match_id=p_scope_id)
          )
      ) recipient
      where recipient.user_id is not null
        and recipient.user_id <> auth.uid();
    end if;
  end loop;
  return v_affected;
end;
$function$;
revoke all on function app_private.apply_event_channel_lifecycle(uuid,text,uuid,text) from public,anon,authenticated;
