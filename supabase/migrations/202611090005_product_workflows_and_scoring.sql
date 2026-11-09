-- KOMNIVO data model completion and scoring integrity.
-- Apply after 202611090004_trigger_and_storage_hardening.sql.

alter table public.game_accounts drop constraint if exists game_accounts_user_id_game_id_key;
create unique index if not exists game_accounts_user_game_uid_key
  on public.game_accounts(user_id, game_id, uid);

create table if not exists public.channel_read_states (
  channel_id uuid not null references public.channels(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  last_read_message_id uuid references public.messages(id) on delete set null,
  last_read_at timestamptz not null default now(),
  muted_until timestamptz,
  primary key (channel_id, user_id)
);

create table if not exists public.message_attachments (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages(id) on delete cascade,
  uploaded_by uuid not null references public.profiles(id),
  storage_path text not null unique,
  content_type text not null,
  file_size bigint not null check (file_size between 1 and 10485760),
  created_at timestamptz not null default now()
);

create table if not exists public.message_pins (
  channel_id uuid not null references public.channels(id) on delete cascade,
  message_id uuid not null references public.messages(id) on delete cascade,
  pinned_by uuid not null references public.profiles(id),
  pinned_at timestamptz not null default now(),
  primary key (channel_id, message_id)
);

create table if not exists public.notification_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  push_enabled boolean not null default true,
  message_push boolean not null default true,
  mention_push boolean not null default true,
  event_push boolean not null default true,
  tournament_push boolean not null default true,
  marketing_push boolean not null default false,
  quiet_hours jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.event_follows (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  followed_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

create table if not exists public.event_rounds (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  round_number integer not null,
  name text not null,
  status text not null default 'draft' check (status in ('draft', 'published', 'live', 'completed')),
  starts_at timestamptz,
  configuration jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (event_id, round_number)
);

create table if not exists public.event_groups (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.event_rounds(id) on delete cascade,
  label text not null,
  sort_order integer not null default 1,
  created_at timestamptz not null default now(),
  unique (round_id, label)
);

create table if not exists public.event_group_teams (
  group_id uuid not null references public.event_groups(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  seeded_by uuid references public.profiles(id),
  seeded_at timestamptz not null default now(),
  primary key (group_id, team_id)
);

create table if not exists public.opponent_confirmations (
  id uuid primary key default gen_random_uuid(),
  result_id uuid not null references public.match_results(id) on delete cascade,
  confirming_team_id uuid not null references public.teams(id),
  confirmed_by uuid not null references public.profiles(id),
  decision text not null check (decision in ('confirmed', 'disputed')),
  note text not null default '',
  created_at timestamptz not null default now(),
  unique (result_id, confirming_team_id)
);

create unique index if not exists match_results_one_team_per_match
  on public.match_results(match_id, team_id);

drop policy if exists results_submit_team_member on public.match_results;
create policy results_submit_registered_team_member on public.match_results
for insert to authenticated
with check (
  submitted_by = auth.uid()
  and status in ('submitted', 'under_review')
  and public.is_team_member(team_id)
  and exists (
    select 1 from public.match_participants mp
    where mp.match_id = match_id and mp.team_id = team_id
  )
);

revoke update on public.match_results from authenticated;
drop policy if exists match_results_update_staff on public.match_results;

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
  v_placement_points := coalesce(
    nullif(v_event.scoring_config->'placement_points'->>v_placement_key, '')::integer,
    0
  );
  v_kill_points := v_result.kills * coalesce(
    nullif(v_event.scoring_config->>'kill_point', '')::integer,
    1
  );
  v_penalty_points := coalesce(
    nullif(v_result.result_json->>'penalty_points', '')::integer,
    0
  );
  v_total := greatest(0, v_placement_points + v_kill_points - greatest(v_penalty_points, 0));

  update public.match_results
    set status = 'approved', points = v_total, approved_at = now(), approved_by = auth.uid()
    where id = p_result_id;

  insert into public.event_standings (
    event_id, team_id, points, kills, matches_played, first_places, updated_at
  )
  values (
    v_event.id, v_result.team_id, v_total, v_result.kills, 1,
    case when v_result.placement = 1 then 1 else 0 end, now()
  )
  on conflict (event_id, team_id) do update
    set points = public.event_standings.points + excluded.points,
        kills = public.event_standings.kills + excluded.kills,
        matches_played = public.event_standings.matches_played + 1,
        first_places = public.event_standings.first_places + excluded.first_places,
        updated_at = now();

  insert into public.audit_logs (
    actor_id, event_id, entity_type, entity_id, action, reason, metadata
  )
  values (
    auth.uid(), v_event.id, 'match_result', p_result_id, 'result_approved',
    left(coalesce(p_reason, ''), 500),
    jsonb_build_object(
      'placement_points', v_placement_points,
      'kill_points', v_kill_points,
      'penalty_points', v_penalty_points,
      'total_points', v_total
    )
  );

  return jsonb_build_object('result_id', p_result_id, 'status', 'approved', 'points', v_total);
end;
$$;
revoke all on function public.approve_match_result(uuid, text) from public, anon;
grant execute on function public.approve_match_result(uuid, text) to authenticated;

alter table public.opponent_confirmations enable row level security;
create policy opponent_confirmations_read_participant_or_staff
on public.opponent_confirmations for select to authenticated
using (
  confirmed_by = auth.uid()
  or public.is_team_member(confirming_team_id)
  or exists (
    select 1 from public.match_results r
    join public.matches m on m.id = r.match_id
    where r.id = result_id and public.is_event_staff(m.event_id)
  )
);
create policy opponent_confirmations_insert_opponent
on public.opponent_confirmations for insert to authenticated
with check (
  confirmed_by = auth.uid()
  and public.is_team_member(confirming_team_id)
  and exists (
    select 1 from public.match_results r
    join public.match_participants mp on mp.match_id = r.match_id and mp.team_id = confirming_team_id
    where r.id = result_id and r.team_id <> confirming_team_id
  )
);

alter table public.channel_read_states enable row level security;
alter table public.message_attachments enable row level security;
alter table public.message_pins enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.event_follows enable row level security;
alter table public.event_rounds enable row level security;
alter table public.event_groups enable row level security;
alter table public.event_group_teams enable row level security;

create policy channel_read_states_self
on public.channel_read_states for all to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy message_attachments_read_channel_member
on public.message_attachments for select to authenticated
using (exists (
  select 1 from public.messages m
  where m.id = message_id and (
    exists (select 1 from public.channels c where c.id = m.channel_id and c.community_id is not null and public.is_community_member(c.community_id))
    or exists (select 1 from public.channel_members cm where cm.channel_id = m.channel_id and cm.user_id = auth.uid())
  )
));
create policy message_attachments_insert_own_message
on public.message_attachments for insert to authenticated
with check (
  uploaded_by = auth.uid()
  and exists (select 1 from public.messages m where m.id = message_id and m.sender_id = auth.uid())
);

create policy message_pins_read_channel_member
on public.message_pins for select to authenticated
using (
  exists (select 1 from public.channels c where c.id = channel_id and c.community_id is not null and public.is_community_member(c.community_id))
  or exists (select 1 from public.channel_members cm where cm.channel_id = channel_id and cm.user_id = auth.uid())
);
create policy message_pins_manage_community_staff
on public.message_pins for all to authenticated
using (exists (select 1 from public.channels c where c.id = channel_id and c.community_id is not null and public.can_manage_community(c.community_id)))
with check (exists (select 1 from public.channels c where c.id = channel_id and c.community_id is not null and public.can_manage_community(c.community_id)));

create policy notification_preferences_self
on public.notification_preferences for all to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy event_follows_self
on public.event_follows for all to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy event_rounds_read_visible
on public.event_rounds for select to authenticated
using (exists (select 1 from public.events e where e.id = event_id and (e.status <> 'draft' or public.is_event_staff(e.id))));
create policy event_rounds_manage_staff
on public.event_rounds for all to authenticated
using (public.is_event_staff(event_id)) with check (public.is_event_staff(event_id));

create policy event_groups_read_visible
on public.event_groups for select to authenticated
using (exists (
  select 1 from public.event_rounds r join public.events e on e.id = r.event_id
  where r.id = round_id and (e.status <> 'draft' or public.is_event_staff(e.id))
));
create policy event_groups_manage_staff
on public.event_groups for all to authenticated
using (exists (select 1 from public.event_rounds r where r.id = round_id and public.is_event_staff(r.event_id)))
with check (exists (select 1 from public.event_rounds r where r.id = round_id and public.is_event_staff(r.event_id)));

create policy event_group_teams_read_visible
on public.event_group_teams for select to authenticated
using (exists (
  select 1 from public.event_groups g
  join public.event_rounds r on r.id = g.round_id
  join public.events e on e.id = r.event_id
  where g.id = group_id and (e.status <> 'draft' or public.is_event_staff(e.id))
));
create policy event_group_teams_manage_staff
on public.event_group_teams for all to authenticated
using (exists (
  select 1 from public.event_groups g join public.event_rounds r on r.id = g.round_id
  where g.id = group_id and public.is_event_staff(r.event_id)
))
with check (exists (
  select 1 from public.event_groups g join public.event_rounds r on r.id = g.round_id
  where g.id = group_id and public.is_event_staff(r.event_id)
));

drop policy if exists reactions_read_channel_member on public.message_reactions;
create policy reactions_read_channel_member
on public.message_reactions for select to authenticated
using (exists (
  select 1 from public.messages m
  where m.id = message_id and (
    exists (select 1 from public.channels c where c.id = m.channel_id and c.community_id is not null and public.is_community_member(c.community_id))
    or exists (select 1 from public.channel_members cm where cm.channel_id = m.channel_id and cm.user_id = auth.uid())
  )
));

grant select, insert, update, delete on public.channel_read_states to authenticated;
grant select, insert on public.message_attachments to authenticated;
grant select, insert, delete on public.message_pins to authenticated;
grant select, insert, update on public.notification_preferences to authenticated;
grant select, insert, delete on public.event_follows to authenticated;
grant select, insert, update, delete on public.event_rounds to authenticated;
grant select, insert, update, delete on public.event_groups to authenticated;
grant select, insert, update, delete on public.event_group_teams to authenticated;
grant select, insert on public.opponent_confirmations to authenticated;
