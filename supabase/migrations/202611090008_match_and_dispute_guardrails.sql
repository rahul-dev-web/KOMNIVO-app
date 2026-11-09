-- Match group integrity and opponent dispute review workflow.
-- Apply after 202611090007_roster_and_group_automation.sql.

alter table public.opponent_confirmations
  add column if not exists review_status text not null default 'none'
    check (review_status in ('none', 'open', 'resolved')),
  add column if not exists reviewed_by uuid references public.profiles(id),
  add column if not exists reviewed_at timestamptz,
  add column if not exists review_note text not null default '';

create or replace function app_private.set_opponent_confirmation_review_state()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.decision = 'disputed' and new.review_status = 'none' then
    new.review_status := 'open';
  elsif new.decision = 'confirmed' then
    new.review_status := 'none';
  end if;
  return new;
end;
$$;
revoke all on function app_private.set_opponent_confirmation_review_state() from public, anon, authenticated;
drop trigger if exists set_opponent_confirmation_review_state on public.opponent_confirmations;
create trigger set_opponent_confirmation_review_state
before insert or update of decision on public.opponent_confirmations
for each row execute procedure app_private.set_opponent_confirmation_review_state();

drop policy if exists opponent_confirmations_update_staff on public.opponent_confirmations;
create policy opponent_confirmations_update_staff on public.opponent_confirmations
for update to authenticated
using (exists (
  select 1 from public.match_results r
  join public.matches m on m.id = r.match_id
  where r.id = result_id and public.is_event_staff(m.event_id)
))
with check (exists (
  select 1 from public.match_results r
  join public.matches m on m.id = r.match_id
  where r.id = result_id and public.is_event_staff(m.event_id)
));
grant update (review_status, reviewed_by, reviewed_at, review_note)
on public.opponent_confirmations to authenticated;

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
  v_group_id uuid;
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

  if p_group_label is not null then
    select g.id into v_group_id
    from public.event_groups g
    join public.event_rounds r on r.id = g.round_id
    where r.event_id = p_event_id and r.round_number = 1 and g.label = p_group_label
    limit 1;
    if v_group_id is null then raise exception 'The selected tournament group does not exist'; end if;

    if exists (
      select 1 from unnest(p_team_ids) selected(team_id)
      where not exists (
        select 1 from public.event_group_teams gt
        where gt.group_id = v_group_id and gt.team_id = selected.team_id
      )
    ) then
      raise exception 'Every selected team must belong to the selected group';
    end if;
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

  insert into public.audit_logs (actor_id, event_id, entity_type, entity_id, action, metadata)
  values (auth.uid(), p_event_id, 'match', v_match_id, 'match_created',
    jsonb_build_object('teams', p_team_ids, 'group_label', p_group_label));

  return v_match_id;
end;
$$;
revoke all on function public.create_match(uuid, uuid[], timestamptz, text) from public, anon;
grant execute on function public.create_match(uuid, uuid[], timestamptz, text) to authenticated;

-- Disputed opponent confirmations must be explicitly reviewed before an organiser
-- can approve the official result.
create or replace function public.approve_match_result(
  p_result_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result public.match_results%rowtype;
  v_match public.matches%rowtype;
  v_event public.events%rowtype;
  v_placement_points integer;
  v_kill_points integer;
  v_penalty_points integer;
  v_total integer;
  v_placement_key text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_result from public.match_results where id = p_result_id for update;
  if not found then raise exception 'Result not found'; end if;
  if v_result.status = 'approved' then raise exception 'Result is already approved'; end if;
  if v_result.status not in ('submitted', 'under_review', 'disputed') then
    raise exception 'Only a submitted or reviewed result can be approved';
  end if;

  if exists (
    select 1 from public.opponent_confirmations
    where result_id = p_result_id and decision = 'disputed' and review_status <> 'resolved'
  ) then
    raise exception 'An opponent dispute must be reviewed before result approval';
  end if;

  select * into v_match from public.matches where id = v_result.match_id;
  if not found then raise exception 'Match not found'; end if;
  select * into v_event from public.events where id = v_match.event_id;
  if not found then raise exception 'Event not found'; end if;
  if not public.is_event_staff(v_event.id) then
    raise exception 'Only an authorised organiser can approve results';
  end if;
  if not exists (
    select 1 from public.match_participants mp
    where mp.match_id = v_result.match_id and mp.team_id = v_result.team_id
  ) then
    raise exception 'The result team is not a participant in this match';
  end if;

  v_placement_key := coalesce(v_result.placement::text, '0');
  v_placement_points := coalesce(nullif(v_event.scoring_config->'placement_points'->>v_placement_key, '')::integer, 0);
  v_kill_points := v_result.kills * coalesce(nullif(v_event.scoring_config->>'kill_point', '')::integer, 1);
  v_penalty_points := coalesce(nullif(v_result.result_json->>'penalty_points', '')::integer, 0);
  v_total := greatest(0, v_placement_points + v_kill_points - greatest(v_penalty_points, 0));

  update public.match_results
  set status = 'approved', points = v_total, approved_at = now(), approved_by = auth.uid()
  where id = p_result_id;

  insert into public.event_standings (event_id, team_id, points, kills, matches_played, first_places, updated_at)
  values (v_event.id, v_result.team_id, v_total, v_result.kills, 1,
    case when v_result.placement = 1 then 1 else 0 end, now())
  on conflict (event_id, team_id) do update
    set points = public.event_standings.points + excluded.points,
        kills = public.event_standings.kills + excluded.kills,
        matches_played = public.event_standings.matches_played + 1,
        first_places = public.event_standings.first_places + excluded.first_places,
        updated_at = now();

  insert into public.audit_logs (actor_id, event_id, entity_type, entity_id, action, reason, metadata)
  values (
    auth.uid(), v_event.id, 'match_result', p_result_id, 'result_approved', left(coalesce(p_reason, ''), 500),
    jsonb_build_object('placement_points', v_placement_points, 'kill_points', v_kill_points, 'penalty_points', v_penalty_points, 'total_points', v_total)
  );

  return jsonb_build_object('result_id', p_result_id, 'status', 'approved', 'points', v_total);
end;
$$;
revoke all on function public.approve_match_result(uuid, text) from public, anon;
grant execute on function public.approve_match_result(uuid, text) to authenticated;
