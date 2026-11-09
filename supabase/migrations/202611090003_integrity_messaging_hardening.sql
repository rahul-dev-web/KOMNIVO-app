-- KOMNIVO integrity and messaging hardening.
-- Apply after 202611090002_rls_scoring_corrections.sql.

-- Private community channels and DM/group conversations must only be visible to their explicit members.
drop policy if exists channels_read_member on public.channels;
create policy channels_read_member on public.channels
for select to authenticated
using (
  (
    community_id is not null
    and public.is_community_member(community_id)
    and (
      not is_private
      or public.can_manage_community(community_id)
      or exists (select 1 from public.channel_members cm where cm.channel_id = id and cm.user_id = auth.uid())
    )
  )
  or (
    community_id is null
    and exists (select 1 from public.channel_members cm where cm.channel_id = id and cm.user_id = auth.uid())
  )
);

drop policy if exists channel_members_add_self on public.channel_members;
create policy channel_members_add_self on public.channel_members
for insert to authenticated
with check (
  user_id = auth.uid()
  and exists (
    select 1 from public.channels c
    where c.id = channel_id
      and c.community_id is not null
      and not c.is_private
      and public.is_community_member(c.community_id)
  )
);

drop policy if exists channel_members_add_manager on public.channel_members;
create policy channel_members_add_manager on public.channel_members
for insert to authenticated
with check (
  exists (
    select 1 from public.channels c
    where c.id = channel_id
      and c.community_id is not null
      and c.is_private
      and public.can_manage_community(c.community_id)
  )
);

drop policy if exists messages_read_channel_member on public.messages;
create policy messages_read_channel_member on public.messages
for select to authenticated
using (
  exists (
    select 1 from public.channels c
    where c.id = channel_id
      and (
        (
          c.community_id is not null
          and public.is_community_member(c.community_id)
          and (
            not c.is_private
            or public.can_manage_community(c.community_id)
            or exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = auth.uid())
          )
        )
        or (
          c.community_id is null
          and exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = auth.uid())
        )
      )
  )
);

drop policy if exists messages_send_channel_member on public.messages;
create policy messages_send_channel_member on public.messages
for insert to authenticated
with check (
  sender_id = auth.uid()
  and exists (
    select 1 from public.channels c
    where c.id = channel_id
      and (
        (
          c.community_id is not null
          and public.is_community_member(c.community_id)
          and (
            not c.is_private
            or public.can_manage_community(c.community_id)
            or exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = auth.uid())
          )
        )
        or (
          c.community_id is null
          and exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = auth.uid())
        )
      )
  )
);

drop policy if exists messages_update_sender_or_manager on public.messages;
create policy messages_update_sender_or_manager on public.messages
for update to authenticated
using (
  sender_id = auth.uid()
  or exists (select 1 from public.channels c where c.id = channel_id and c.community_id is not null and public.can_manage_community(c.community_id))
)
with check (
  sender_id = auth.uid()
  or exists (select 1 from public.channels c where c.id = channel_id and c.community_id is not null and public.can_manage_community(c.community_id))
);

-- Enforce capacity and team/captain checks in a single privileged RPC rather than allowing direct inserts.
create or replace function public.register_for_event(p_event_id uuid, p_team_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event public.events%rowtype;
  v_status text;
  v_registration public.event_registrations%rowtype;
  v_count integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select * into v_event from public.events where id = p_event_id for update;
  if not found then raise exception 'Event not found'; end if;
  if v_event.status not in ('published', 'registration_open') then raise exception 'Registration is closed'; end if;
  if v_event.registration_closes_at is not null and v_event.registration_closes_at <= now() then
    raise exception 'Registration deadline has passed';
  end if;

  if v_event.format = 'solo' and p_team_id is not null then
    raise exception 'Solo events do not accept a team registration';
  end if;
  if v_event.format <> 'solo' and p_team_id is null then
    raise exception 'Select a team before registering for this event';
  end if;

  if p_team_id is not null and not exists (
    select 1 from public.team_members tm
    join public.teams t on t.id = tm.team_id
    where tm.team_id = p_team_id
      and tm.user_id = auth.uid()
      and tm.role in ('owner', 'captain')
      and t.game_id = v_event.game_id
  ) then
    raise exception 'You must be a team owner/captain and the team must match this event game';
  end if;

  select count(*) into v_count
  from public.event_registrations
  where event_id = p_event_id
    and status in ('pending', 'approved', 'checked_in');

  v_status := case when v_count >= v_event.capacity then 'waitlisted' else 'pending' end;

  insert into public.event_registrations (event_id, team_id, captain_user_id, status)
  values (p_event_id, p_team_id, auth.uid(), v_status)
  returning * into v_registration;

  return jsonb_build_object('registration_id', v_registration.id, 'status', v_registration.status);
exception
  when unique_violation then raise exception 'This player or team is already registered';
end;
$$;
revoke all on function public.register_for_event(uuid, uuid) from public, anon;
grant execute on function public.register_for_event(uuid, uuid) to authenticated;
revoke insert on public.event_registrations from authenticated;

-- A captain may withdraw their own registration; a staff member may also withdraw any event registration.
create or replace function public.withdraw_event_registration(p_registration_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_registration public.event_registrations%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_registration from public.event_registrations where id = p_registration_id for update;
  if not found then raise exception 'Registration not found'; end if;
  if v_registration.captain_user_id <> auth.uid() and not public.is_event_staff(v_registration.event_id) then
    raise exception 'Not authorised to withdraw this registration';
  end if;
  if v_registration.status not in ('pending', 'approved', 'waitlisted', 'checked_in') then
    raise exception 'This registration can no longer be withdrawn';
  end if;
  update public.event_registrations set status = 'withdrawn' where id = p_registration_id;
  return jsonb_build_object('registration_id', p_registration_id, 'status', 'withdrawn');
end;
$$;
revoke all on function public.withdraw_event_registration(uuid) from public, anon;
grant execute on function public.withdraw_event_registration(uuid) to authenticated;

-- Organisers generate matches from approved registrations. Every team must belong to the selected event.
create or replace function public.create_match(
  p_event_id uuid,
  p_team_ids uuid[],
  p_starts_at timestamptz default null,
  p_group_label text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_match_id uuid;
  v_team_id uuid;
  v_registration_id uuid;
  v_match_number integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.is_event_staff(p_event_id) then raise exception 'Only event organisers can create matches'; end if;
  if p_team_ids is null or cardinality(p_team_ids) < 2 or cardinality(p_team_ids) > 24 then
    raise exception 'Select between 2 and 24 registered teams';
  end if;
  if (select count(distinct x) from unnest(p_team_ids) as x) <> cardinality(p_team_ids) then
    raise exception 'Duplicate team selected';
  end if;

  select coalesce(max(match_number), 0) + 1 into v_match_number
  from public.matches where event_id = p_event_id;

  insert into public.matches (event_id, round_number, group_label, match_number, starts_at, status, host_user_id)
  values (p_event_id, 1, nullif(trim(p_group_label), ''), v_match_number, p_starts_at, 'scheduled', auth.uid())
  returning id into v_match_id;

  foreach v_team_id in array p_team_ids loop
    select id into v_registration_id
    from public.event_registrations
    where event_id = p_event_id
      and team_id = v_team_id
      and status in ('approved', 'checked_in')
    limit 1;
    if v_registration_id is null then
      raise exception 'Every selected team must have an approved registration';
    end if;
    insert into public.match_participants (match_id, team_id, registration_id)
    values (v_match_id, v_team_id, v_registration_id);
  end loop;
  return v_match_id;
exception
  when others then
    if v_match_id is not null then delete from public.matches where id = v_match_id; end if;
    raise;
end;
$$;
revoke all on function public.create_match(uuid, uuid[], timestamptz, text) from public, anon;
grant execute on function public.create_match(uuid, uuid[], timestamptz, text) to authenticated;

-- Registration status can only be changed by event staff after the registration is submitted.
drop policy if exists registrations_update_staff_or_captain on public.event_registrations;
create policy registrations_update_staff_only on public.event_registrations
for update to authenticated
using (public.is_event_staff(event_id))
with check (public.is_event_staff(event_id));
revoke update on public.event_registrations from authenticated;
grant update (status, approved_at) on public.event_registrations to authenticated;

-- Prevent an invited member from changing invitation ownership or team references.
revoke update on public.team_invites from authenticated;
grant update (status) on public.team_invites to authenticated;

-- Evidence rows must belong to an event participant or authorised organiser.
drop policy if exists evidence_insert_owner on public.result_evidence;
create policy evidence_insert_owner_or_staff on public.result_evidence
for insert to authenticated
with check (
  uploaded_by = auth.uid()
  and exists (
    select 1 from public.match_results r
    join public.matches m on m.id = r.match_id
    where r.id = result_id
      and (public.is_team_member(r.team_id) or public.is_event_staff(m.event_id))
  )
);

-- Update community member counts from the actual membership table.
create or replace function app_private.refresh_community_member_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_community_id uuid;
begin
  v_community_id := coalesce(new.community_id, old.community_id);
  update public.communities
    set member_count = (select count(*) from public.community_members where community_id = v_community_id)
    where id = v_community_id;
  return coalesce(new, old);
end;
$$;
revoke all on function app_private.refresh_community_member_count() from public, anon, authenticated;
drop trigger if exists refresh_community_member_count on public.community_members;
create trigger refresh_community_member_count
after insert or delete on public.community_members
for each row execute procedure app_private.refresh_community_member_count();

-- Notify community/channel members when a new message is posted.
create or replace function app_private.notify_channel_members()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_channel public.channels%rowtype;
begin
  select * into v_channel from public.channels where id = new.channel_id;
  if v_channel.community_id is not null then
    insert into public.notifications (user_id, title, body, kind, entity_type, entity_id)
    select cm.user_id, 'New message in ' || v_channel.name,
      left(new.body, 180), 'message', 'channel', new.channel_id
    from public.community_members cm
    where cm.community_id = v_channel.community_id and cm.user_id <> new.sender_id;
  else
    insert into public.notifications (user_id, title, body, kind, entity_type, entity_id)
    select cm.user_id, 'New message in ' || v_channel.name,
      left(new.body, 180), 'message', 'channel', new.channel_id
    from public.channel_members cm
    where cm.channel_id = new.channel_id and cm.user_id <> new.sender_id;
  end if;
  return new;
end;
$$;
revoke all on function app_private.notify_channel_members() from public, anon, authenticated;
drop trigger if exists notify_channel_members_after_message on public.messages;
create trigger notify_channel_members_after_message
after insert on public.messages
for each row execute procedure app_private.notify_channel_members();

