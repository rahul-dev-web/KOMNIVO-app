-- Batch 3: close direct-write gaps around attachments, poll ballots and announcement lifecycle.
create or replace function app_private.guard_batch3_attachment_insert()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_channel_id uuid; v_allowed boolean;
begin
  if current_user='postgres' or auth.role()='service_role' then return new; end if;
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
revoke all on function app_private.guard_batch3_attachment_insert() from public,anon,authenticated;
drop trigger if exists message_attachments_batch3_guard on public.message_attachments;
create trigger message_attachments_batch3_guard before insert on public.message_attachments
for each row execute function app_private.guard_batch3_attachment_insert();

create or replace function app_private.guard_batch3_poll_vote()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_multiple boolean; v_closed timestamptz; v_channel uuid; v_count integer;
begin
  if current_user='postgres' or auth.role()='service_role' then return new; end if;
  select p.allow_multiple,p.closes_at,p.channel_id into v_multiple,v_closed,v_channel
    from public.channel_polls p where p.id=new.poll_id;
  if v_channel is null then raise exception 'Poll not found'; end if;
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
revoke all on function app_private.guard_batch3_poll_vote() from public,anon,authenticated;
drop trigger if exists channel_poll_votes_batch3_guard on public.channel_poll_votes;
create trigger channel_poll_votes_batch3_guard before insert on public.channel_poll_votes
for each row execute function app_private.guard_batch3_poll_vote();

create or replace function app_private.guard_batch3_announcement_update()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  if current_user='postgres' or auth.role()='service_role' then return new; end if;
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
  if new.status='cancelled' and old.status <> 'scheduled' then raise exception 'Announcement is not pending'; end if;
  if new.publish_at <= now() and new.status='scheduled' then raise exception 'Publish time must be in the future'; end if;
  if new.created_by <> auth.uid()
    and not app_private.resolve_permission('channel.manage_messages','community',old.community_id,null,old.channel_id)
  then raise exception 'You cannot update this announcement'; end if;
  return new;
end;
$function$;
revoke all on function app_private.guard_batch3_announcement_update() from public,anon,authenticated;
drop trigger if exists scheduled_announcements_batch3_guard on public.scheduled_channel_announcements;
create trigger scheduled_announcements_batch3_guard before update on public.scheduled_channel_announcements
for each row execute function app_private.guard_batch3_announcement_update();
