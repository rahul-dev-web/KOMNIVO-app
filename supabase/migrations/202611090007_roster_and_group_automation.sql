-- Registration snapshots, roster locks and balanced group allocation.
-- Apply after 202611090006_invite_and_messaging_security.sql.

alter table public.event_registrations
  add column if not exists roster_locked boolean not null default false,
  add column if not exists roster_locked_at timestamptz;

create or replace function public.register_for_event(p_event_id uuid, p_team_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event public.events%rowtype;
  v_registration public.event_registrations%rowtype;
  v_count integer;
  v_roster_count integer;
  v_min_roster integer;
  v_max_roster integer;
  v_require_uid boolean;
  v_status text;
  v_duplicate_uid boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select * into v_event from public.events where id = p_event_id for update;
  if not found then raise exception 'Event not found'; end if;
  if v_event.status not in ('published', 'registration_open') then raise exception 'Registration is closed'; end if;
  if v_event.registration_closes_at is not null and v_event.registration_closes_at <= now() then
    raise exception 'Registration deadline has passed';
  end if;

  select count(*) into v_count
  from public.event_registrations
  where event_id = p_event_id and status in ('pending', 'approved', 'checked_in');

  v_status := case when v_count >= v_event.capacity then 'waitlisted' else 'pending' end;

  if v_event.format = 'solo' then
    if p_team_id is not null then raise exception 'Solo events do not accept a team registration'; end if;
    v_require_uid := coalesce((v_event.rules_json->>'require_game_uid')::boolean, false);
    if v_require_uid and not exists (
      select 1 from public.game_accounts ga
      where ga.user_id = auth.uid() and ga.game_id = v_event.game_id
        and ga.ownership_status <> 'rejected'
    ) then
      raise exception 'Link the required game UID before registering';
    end if;

    insert into public.event_registrations (event_id, team_id, captain_user_id, status)
    values (p_event_id, null, auth.uid(), v_status)
    returning * into v_registration;

    insert into public.registration_players (registration_id, user_id, game_account_id)
    select v_registration.id, auth.uid(), ga.id
    from public.game_accounts ga
    where ga.user_id = auth.uid() and ga.game_id = v_event.game_id
    order by ga.last_synced_at desc nulls last
    limit 1;

    if not found then
      insert into public.registration_players (registration_id, user_id)
      values (v_registration.id, auth.uid());
    end if;
  else
    if p_team_id is null then raise exception 'Select a team before registering for this event'; end if;

    if not exists (
      select 1 from public.team_members tm
      join public.teams t on t.id = tm.team_id
      where tm.team_id = p_team_id
        and tm.user_id = auth.uid()
        and tm.role in ('owner', 'captain')
        and t.game_id = v_event.game_id
    ) then
      raise exception 'You must be a team owner/captain and the team must match this event game';
    end if;

    select count(*) into v_roster_count
    from public.team_members tm
    where tm.team_id = p_team_id;

    v_min_roster := coalesce(
      nullif(v_event.rules_json->>'min_roster_size', '')::integer,
      1
    );
    v_max_roster := coalesce(
      nullif(v_event.rules_json->>'max_roster_size', '')::integer,
      case v_event.format when 'duo' then 2 when 'squad' then 4 else 8 end
    );
    if v_roster_count < v_min_roster or v_roster_count > v_max_roster then
      raise exception 'Team roster size must be between % and %', v_min_roster, v_max_roster;
    end if;

    v_require_uid := coalesce((v_event.rules_json->>'require_game_uid')::boolean, false);
    if v_require_uid and (
      select count(*) from public.team_members tm
      join public.game_accounts ga on ga.user_id = tm.user_id and ga.game_id = v_event.game_id
      where tm.team_id = p_team_id and ga.ownership_status <> 'rejected'
    ) < v_roster_count then
      raise exception 'Every roster member must link a game UID before registration';
    end if;

    select exists (
      select 1
      from public.team_members current_member
      join public.game_accounts current_account
        on current_account.user_id = current_member.user_id
       and current_account.game_id = v_event.game_id
      join public.event_registrations existing_registration
        on existing_registration.event_id = p_event_id
       and existing_registration.status in ('pending', 'approved', 'checked_in')
      join public.registration_players existing_player
        on existing_player.registration_id = existing_registration.id
      join public.game_accounts existing_account
        on existing_account.id = existing_player.game_account_id
      where current_member.team_id = p_team_id
        and existing_account.uid = current_account.uid
        and existing_registration.team_id is distinct from p_team_id
    ) into v_duplicate_uid;

    if v_duplicate_uid then
      raise exception 'One or more game UIDs are already registered with another team';
    end if;

    insert into public.event_registrations (event_id, team_id, captain_user_id, status)
    values (p_event_id, p_team_id, auth.uid(), v_status)
    returning * into v_registration;

    insert into public.registration_players (registration_id, user_id, game_account_id)
    select v_registration.id, tm.user_id, ga.id
    from public.team_members tm
    left join lateral (
      select id from public.game_accounts
      where user_id = tm.user_id and game_id = v_event.game_id
      order by last_synced_at desc nulls last
      limit 1
    ) ga on true
    where tm.team_id = p_team_id;
  end if;

  return jsonb_build_object(
    'registration_id', v_registration.id,
    'status', v_registration.status,
    'roster_size', v_roster_count,
    'roster_locked', false
  );
exception
  when unique_violation then raise exception 'This player or team is already registered';
end;
$$;
revoke all on function public.register_for_event(uuid, uuid) from public, anon;
grant execute on function public.register_for_event(uuid, uuid) to authenticated;

create or replace function public.lock_event_rosters(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.is_event_staff(p_event_id) then
    raise exception 'Only event organisers can lock rosters';
  end if;

  update public.event_registrations
  set roster_locked = true, roster_locked_at = coalesce(roster_locked_at, now())
  where event_id = p_event_id and status in ('approved', 'checked_in') and not roster_locked;

  get diagnostics v_count = row_count;

  update public.registration_players rp
  set roster_locked = true
  from public.event_registrations er
  where er.id = rp.registration_id and er.event_id = p_event_id
    and er.status in ('approved', 'checked_in');

  insert into public.audit_logs (actor_id, event_id, entity_type, action, metadata)
  values (auth.uid(), p_event_id, 'event_roster', 'rosters_locked', jsonb_build_object('newly_locked', v_count));

  return jsonb_build_object('locked', v_count);
end;
$$;
revoke all on function public.lock_event_rosters(uuid) from public, anon;
grant execute on function public.lock_event_rosters(uuid) to authenticated;

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

  if exists (
    select 1 from unnest(p_team_ids) selected(team_id)
    where not exists (
      select 1 from public.event_registrations er
      where er.event_id = p_event_id
        and er.team_id = selected.team_id
        and er.status in ('approved', 'checked_in')
        and er.roster_locked
    )
  ) then
    raise exception 'Every selected team must have an approved and locked roster';
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
      and roster_locked
    limit 1;
    insert into public.match_participants (match_id, team_id, registration_id)
    values (v_match_id, v_team_id, v_registration_id);
  end loop;

  return v_match_id;
end;
$$;
revoke all on function public.create_match(uuid, uuid[], timestamptz, text) from public, anon;
grant execute on function public.create_match(uuid, uuid[], timestamptz, text) to authenticated;

create or replace function public.generate_event_groups(
  p_event_id uuid,
  p_round_number integer,
  p_group_size integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_round_id uuid;
  v_team_count integer;
  v_group_count integer;
  v_group_labels text[];
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.is_event_staff(p_event_id) then
    raise exception 'Only event organisers can generate groups';
  end if;
  if p_round_number < 1 or p_group_size < 2 or p_group_size > 24 then
    raise exception 'Round number or group size is invalid';
  end if;

  select count(*) into v_team_count
  from public.event_registrations
  where event_id = p_event_id and status in ('approved', 'checked_in')
    and roster_locked and team_id is not null;

  if v_team_count < 2 then
    raise exception 'At least two approved teams with locked rosters are required';
  end if;

  v_group_count := ceil(v_team_count::numeric / p_group_size)::integer;

  insert into public.event_rounds (event_id, round_number, name, status)
  values (p_event_id, p_round_number, 'Round ' || p_round_number, 'draft')
  on conflict (event_id, round_number) do update
    set name = excluded.name
  returning id into v_round_id;

  delete from public.event_groups where round_id = v_round_id;

  insert into public.event_groups (round_id, label, sort_order)
  select v_round_id, 'Group ' || n, n
  from generate_series(1, v_group_count) n;

  insert into public.event_group_teams (group_id, team_id, seeded_by)
  select g.id, ranked.team_id, auth.uid()
  from (
    select team_id,
      ntile(v_group_count) over (order by registered_at, team_id) as group_number
    from public.event_registrations
    where event_id = p_event_id and status in ('approved', 'checked_in')
      and roster_locked and team_id is not null
  ) ranked
  join public.event_groups g
    on g.round_id = v_round_id and g.sort_order = ranked.group_number;

  select array_agg(label order by sort_order) into v_group_labels
  from public.event_groups where round_id = v_round_id;

  insert into public.audit_logs (actor_id, event_id, entity_type, action, metadata)
  values (
    auth.uid(), p_event_id, 'event_groups', 'groups_generated',
    jsonb_build_object('round_number', p_round_number, 'group_size_target', p_group_size, 'groups', v_group_labels, 'teams', v_team_count)
  );

  return jsonb_build_object(
    'round_id', v_round_id,
    'team_count', v_team_count,
    'group_count', v_group_count,
    'groups', v_group_labels
  );
end;
$$;
revoke all on function public.generate_event_groups(uuid, integer, integer) from public, anon;
grant execute on function public.generate_event_groups(uuid, integer, integer) to authenticated;
