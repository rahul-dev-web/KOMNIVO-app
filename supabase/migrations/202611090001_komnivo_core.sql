-- KOMNIVO core schema. Apply to a NEW, dedicated Supabase project.
-- Public schema tables all use RLS. Privileged provider secrets remain in Edge Function secrets.

create extension if not exists pgcrypto;
create schema if not exists app_private;
revoke all on schema app_private from public, anon, authenticated;

create or replace function app_private.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
revoke all on function app_private.set_updated_at() from public, anon, authenticated;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Player',
  username text unique,
  avatar_url text,
  bio text not null default '',
  region text not null default 'IN',
  is_public boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.games (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  publisher text,
  platform text not null default 'multi',
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
insert into public.games (id, code, name, publisher, platform)
values ('11111111-1111-4111-8111-111111111111', 'free_fire_max', 'Free Fire MAX', 'Garena', 'android')
on conflict (code) do update set name = excluded.name;

create table if not exists public.game_accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  game_id uuid not null references public.games(id),
  uid text not null,
  region text not null default 'ind',
  nickname text,
  level integer,
  rank_label text,
  avatar_url text,
  provider text not null,
  ownership_status text not null default 'linked_unverified'
    check (ownership_status in ('linked_unverified', 'proof_pending', 'verified', 'rejected')),
  sync_status text not null default 'synced'
    check (sync_status in ('synced', 'pending', 'not_found', 'provider_unavailable', 'needs_review')),
  last_synced_at timestamptz,
  raw_profile jsonb not null default '{}'::jsonb,
  raw_stats jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, game_id)
);
create index if not exists game_accounts_uid_idx on public.game_accounts(game_id, uid, region);

create table if not exists public.game_profile_snapshots (
  id uuid primary key default gen_random_uuid(),
  game_account_id uuid not null references public.game_accounts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  provider text not null,
  region text not null,
  profile_json jsonb not null default '{}'::jsonb,
  stats_json jsonb not null default '{}'::jsonb,
  captured_at timestamptz not null default now()
);

create table if not exists public.communities (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 3 and 60),
  slug text not null unique,
  description text not null default '',
  visibility text not null default 'public' check (visibility in ('public', 'private')),
  owner_user_id uuid not null references public.profiles(id),
  icon_url text,
  member_count integer not null default 1 check (member_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.community_members (
  community_id uuid not null references public.communities(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'admin', 'moderator', 'organiser', 'member', 'spectator')),
  joined_at timestamptz not null default now(),
  muted_until timestamptz,
  primary key (community_id, user_id)
);

create table if not exists public.community_invites (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  token_hash text not null unique,
  created_by uuid not null references public.profiles(id),
  expires_at timestamptz,
  max_uses integer,
  uses integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.channels (
  id uuid primary key default gen_random_uuid(),
  community_id uuid references public.communities(id) on delete cascade,
  name text not null,
  description text not null default '',
  kind text not null default 'text' check (kind in ('text', 'announcement', 'voice', 'dm', 'group', 'match')),
  is_private boolean not null default false,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.channel_members (
  channel_id uuid not null references public.channels(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (channel_id, user_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null references public.channels(id) on delete cascade,
  sender_id uuid not null references public.profiles(id),
  parent_message_id uuid references public.messages(id) on delete set null,
  body text not null check (char_length(body) between 1 and 10000),
  edited_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists messages_channel_time_idx on public.messages(channel_id, created_at desc);

create table if not exists public.message_reactions (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  emoji text not null check (char_length(emoji) between 1 and 24),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);

create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 60),
  tag text not null default '',
  description text not null default '',
  game_id uuid not null references public.games(id),
  community_id uuid references public.communities(id) on delete set null,
  owner_user_id uuid not null references public.profiles(id),
  is_public boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.team_members (
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'captain', 'member', 'substitute')),
  joined_at timestamptz not null default now(),
  primary key (team_id, user_id)
);

create table if not exists public.team_invites (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  invited_user_id uuid not null references public.profiles(id) on delete cascade,
  invited_by uuid not null references public.profiles(id),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'cancelled')),
  expires_at timestamptz not null default now() + interval '7 days',
  created_at timestamptz not null default now()
);

create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  community_id uuid references public.communities(id) on delete set null,
  game_id uuid not null references public.games(id),
  organizer_id uuid not null references public.profiles(id),
  name text not null check (char_length(name) between 3 and 100),
  description text not null default '',
  format text not null default 'squad' check (format in ('solo', 'duo', 'squad', 'custom')),
  status text not null default 'draft' check (status in ('draft', 'published', 'registration_open', 'registration_closed', 'live', 'completed', 'cancelled')),
  starts_at timestamptz not null,
  registration_closes_at timestamptz,
  capacity integer not null default 48 check (capacity > 0),
  rules_json jsonb not null default '{}'::jsonb,
  scoring_config jsonb not null default '{"kill_point": 1, "placement_points": {}}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists events_status_start_idx on public.events(status, starts_at);

create table if not exists public.event_registrations (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  team_id uuid references public.teams(id) on delete set null,
  captain_user_id uuid not null references public.profiles(id),
  status text not null default 'pending' check (status in ('pending', 'approved', 'waitlisted', 'rejected', 'checked_in', 'withdrawn')),
  registered_at timestamptz not null default now(),
  approved_at timestamptz,
  unique (event_id, team_id)
);
create unique index if not exists event_solo_registration_unique_idx
on public.event_registrations(event_id, captain_user_id) where team_id is null;

create table if not exists public.registration_players (
  registration_id uuid not null references public.event_registrations(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  game_account_id uuid references public.game_accounts(id),
  roster_locked boolean not null default false,
  primary key (registration_id, user_id)
);

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  round_number integer not null default 1,
  group_label text,
  match_number integer not null default 1,
  starts_at timestamptz,
  status text not null default 'scheduled' check (status in ('scheduled', 'check_in', 'room_setup', 'lobby_review', 'live', 'awaiting_result', 'review', 'completed', 'cancelled')),
  host_user_id uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.match_participants (
  match_id uuid not null references public.matches(id) on delete cascade,
  team_id uuid not null references public.teams(id),
  registration_id uuid references public.event_registrations(id),
  check_in_status text not null default 'pending' check (check_in_status in ('pending', 'ready', 'late', 'absent')),
  checked_in_at timestamptz,
  primary key (match_id, team_id)
);

create table if not exists public.match_checkins (
  match_id uuid not null references public.matches(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'ready' check (status in ('ready', 'late', 'absent')),
  checked_in_at timestamptz not null default now(),
  primary key (match_id, user_id)
);

create table if not exists public.room_credentials (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null unique references public.matches(id) on delete cascade,
  room_code text not null,
  room_password text,
  release_at timestamptz not null,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.match_results (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  team_id uuid not null references public.teams(id),
  submitted_by uuid not null references public.profiles(id),
  placement integer check (placement is null or placement > 0),
  kills integer not null default 0 check (kills >= 0),
  points integer not null default 0,
  status text not null default 'submitted' check (status in ('submitted', 'under_review', 'approved', 'rejected', 'disputed')),
  result_json jsonb not null default '{}'::jsonb,
  submitted_at timestamptz not null default now(),
  approved_at timestamptz,
  approved_by uuid references public.profiles(id)
);

create table if not exists public.result_evidence (
  id uuid primary key default gen_random_uuid(),
  result_id uuid not null references public.match_results(id) on delete cascade,
  uploaded_by uuid not null references public.profiles(id),
  storage_path text not null,
  content_type text,
  file_size bigint,
  created_at timestamptz not null default now()
);

create table if not exists public.result_disputes (
  id uuid primary key default gen_random_uuid(),
  result_id uuid not null references public.match_results(id) on delete cascade,
  opened_by uuid not null references public.profiles(id),
  reason text not null,
  status text not null default 'open' check (status in ('open', 'under_review', 'resolved', 'rejected')),
  decision text,
  decided_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create table if not exists public.event_standings (
  event_id uuid not null references public.events(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  points integer not null default 0,
  kills integer not null default 0,
  matches_played integer not null default 0,
  first_places integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (event_id, team_id)
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  body text not null,
  kind text not null default 'general',
  entity_type text,
  entity_id uuid,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_time_idx on public.notifications(user_id, created_at desc);

create table if not exists public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  token text not null unique,
  platform text not null default 'flutter',
  updated_at timestamptz not null default now()
);

create table if not exists public.moderation_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id),
  target_user_id uuid references public.profiles(id),
  message_id uuid references public.messages(id) on delete set null,
  community_id uuid references public.communities(id) on delete cascade,
  reason text not null,
  details text not null default '',
  status text not null default 'open' check (status in ('open', 'reviewing', 'resolved', 'dismissed')),
  assigned_to uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create table if not exists public.user_blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles(id),
  community_id uuid references public.communities(id) on delete cascade,
  event_id uuid references public.events(id) on delete cascade,
  entity_type text not null,
  entity_id uuid,
  action text not null,
  reason text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.liveops_sessions (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.profiles(id) on delete cascade,
  match_id uuid references public.matches(id) on delete set null,
  state text not null default 'created' check (state in ('created', 'capturing', 'paused', 'stopped', 'failed')),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  device_info jsonb not null default '{}'::jsonb
);

create table if not exists public.screen_observations (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.liveops_sessions(id) on delete cascade,
  screen_state text not null default 'unknown',
  confidence numeric(5,4) not null default 0 check (confidence >= 0 and confidence <= 1),
  extracted_text text not null default '',
  extracted_fields jsonb not null default '{}'::jsonb,
  observed_at timestamptz not null default now()
);

create table if not exists public.lobby_checks (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.liveops_sessions(id) on delete cascade,
  match_id uuid references public.matches(id) on delete set null,
  roster_version text,
  matched_players jsonb not null default '[]'::jsonb,
  missing_players jsonb not null default '[]'::jsonb,
  unknown_players jsonb not null default '[]'::jsonb,
  ambiguous_players jsonb not null default '[]'::jsonb,
  human_decision text not null default 'needs_review',
  decided_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.result_candidates (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  source_observation_id uuid references public.screen_observations(id) on delete set null,
  team_id uuid references public.teams(id),
  candidate_placement integer,
  candidate_kills integer,
  confidence numeric(5,4) not null default 0,
  review_status text not null default 'provisional' check (review_status in ('provisional', 'needs_review', 'accepted', 'rejected')),
  created_at timestamptz not null default now()
);

-- Helper predicates used by RLS. These functions run as invoker; they do not elevate privileges.
create or replace function public.is_community_member(p_community_id uuid)
returns boolean language sql stable security invoker set search_path = public
as $$ select exists (select 1 from public.community_members cm where cm.community_id = p_community_id and cm.user_id = auth.uid()) $$;

create or replace function public.can_manage_community(p_community_id uuid)
returns boolean language sql stable security invoker set search_path = public
as $$ select exists (
  select 1 from public.community_members cm
  where cm.community_id = p_community_id and cm.user_id = auth.uid()
    and cm.role in ('owner', 'admin', 'moderator', 'organiser')
) $$;

create or replace function public.is_team_member(p_team_id uuid)
returns boolean language sql stable security invoker set search_path = public
as $$ select exists (select 1 from public.team_members tm where tm.team_id = p_team_id and tm.user_id = auth.uid()) $$;

create or replace function public.is_event_staff(p_event_id uuid)
returns boolean language sql stable security invoker set search_path = public
as $$ select exists (
  select 1 from public.events e
  where e.id = p_event_id and (
    e.organizer_id = auth.uid()
    or (e.community_id is not null and public.can_manage_community(e.community_id))
  )
) $$;

-- Auth user -> platform profile.
create or replace function app_private.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, auth
as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', split_part(coalesce(new.email, 'Player'), '@', 1)),
    new.raw_user_meta_data->>'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;
revoke all on function app_private.handle_new_user() from public, anon, authenticated;
drop trigger if exists on_auth_user_created_komnivo on auth.users;
create trigger on_auth_user_created_komnivo after insert on auth.users
for each row execute procedure app_private.handle_new_user();

-- Community creator becomes owner and gets standard channel templates.
create or replace function app_private.after_community_created()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.community_members (community_id, user_id, role)
  values (new.id, new.owner_user_id, 'owner')
  on conflict do nothing;

  insert into public.channels (community_id, name, description, kind, created_by)
  values
    (new.id, 'announcements', 'Official organiser updates', 'announcement', new.owner_user_id),
    (new.id, 'general', 'Everyday community conversation', 'text', new.owner_user_id),
    (new.id, 'looking-for-team', 'Find players, teams and substitutes', 'text', new.owner_user_id),
    (new.id, 'scrim-hub', 'Scrim coordination and availability', 'text', new.owner_user_id),
    (new.id, 'voice-lounge', 'Community voice room', 'voice', new.owner_user_id);
  return new;
end;
$$;
revoke all on function app_private.after_community_created() from public, anon, authenticated;
drop trigger if exists community_owner_and_channels on public.communities;
create trigger community_owner_and_channels after insert on public.communities
for each row execute procedure app_private.after_community_created();

create or replace function app_private.after_team_created()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.team_members (team_id, user_id, role) values (new.id, new.owner_user_id, 'owner')
  on conflict do nothing;
  return new;
end;
$$;
revoke all on function app_private.after_team_created() from public, anon, authenticated;
drop trigger if exists team_owner_membership on public.teams;
create trigger team_owner_membership after insert on public.teams
for each row execute procedure app_private.after_team_created();

-- Capacity-safe registration. Event row lock serialises last-slot registrations.
create or replace function public.register_for_event(p_event_id uuid, p_team_id uuid default null)
returns jsonb language plpgsql security invoker set search_path = public
as $$
declare
  v_event public.events%rowtype;
  v_registration public.event_registrations%rowtype;
  v_count integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_event from public.events where id = p_event_id for update;
  if not found then raise exception 'Event not found'; end if;
  if v_event.status not in ('published', 'registration_open') then raise exception 'Registration is closed'; end if;
  if v_event.registration_closes_at is not null and v_event.registration_closes_at <= now() then raise exception 'Registration deadline has passed'; end if;

  if p_team_id is not null and not exists (
    select 1 from public.team_members tm
    where tm.team_id = p_team_id and tm.user_id = auth.uid() and tm.role in ('owner', 'captain')
  ) then raise exception 'Only a team owner or captain can register this team'; end if;

  select count(*) into v_count from public.event_registrations
  where event_id = p_event_id and status not in ('rejected', 'withdrawn');
  if v_count >= v_event.capacity then raise exception 'Event is full'; end if;

  insert into public.event_registrations (event_id, team_id, captain_user_id, status)
  values (p_event_id, p_team_id, auth.uid(), 'pending')
  returning * into v_registration;

  return jsonb_build_object('registration_id', v_registration.id, 'status', v_registration.status);
exception
  when unique_violation then raise exception 'This player or team is already registered';
end;
$$;
revoke all on function public.register_for_event(uuid, uuid) from public, anon;
grant execute on function public.register_for_event(uuid, uuid) to authenticated;

-- Authorised organiser approves a result; official points are calculated only here.
create or replace function public.approve_match_result(p_result_id uuid, p_reason text default null)
returns jsonb language plpgsql security invoker set search_path = public
as $$
declare
  v_result public.match_results%rowtype;
  v_match public.matches%rowtype;
  v_event public.events%rowtype;
  v_placement_points integer;
  v_kill_points integer;
  v_total integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_result from public.match_results where id = p_result_id for update;
  if not found then raise exception 'Result not found'; end if;
  select * into v_match from public.matches where id = v_result.match_id;
  select * into v_event from public.events where id = v_match.event_id;
  if not public.is_event_staff(v_event.id) then raise exception 'Only an authorised organiser can approve results'; end if;
  if v_result.status = 'approved' then raise exception 'Result is already approved'; end if;

  v_placement_points := coalesce((v_event.scoring_config->'placement_points'->>coalesce(v_result.placement::text, '0'))::integer, 0);
  v_kill_points := v_result.kills * coalesce((v_event.scoring_config->>'kill_point')::integer, 1);
  v_total := v_placement_points + v_kill_points;

  update public.match_results
    set status = 'approved', points = v_total, approved_at = now(), approved_by = auth.uid()
    where id = p_result_id;

  insert into public.event_standings (event_id, team_id, points, kills, matches_played, first_places, updated_at)
  values (v_event.id, v_result.team_id, v_total, v_result.kills, 1, case when v_result.placement = 1 then 1 else 0 end, now())
  on conflict (event_id, team_id) do update
    set points = public.event_standings.points + excluded.points,
        kills = public.event_standings.kills + excluded.kills,
        matches_played = public.event_standings.matches_played + 1,
        first_places = public.event_standings.first_places + excluded.first_places,
        updated_at = now();

  insert into public.audit_logs (actor_id, event_id, entity_type, entity_id, action, reason, metadata)
  values (auth.uid(), v_event.id, 'match_result', p_result_id, 'result_approved', p_reason,
    jsonb_build_object('placement_points', v_placement_points, 'kill_points', v_kill_points, 'total_points', v_total));

  return jsonb_build_object('result_id', p_result_id, 'status', 'approved', 'points', v_total);
end;
$$;
revoke all on function public.approve_match_result(uuid, text) from public, anon;
grant execute on function public.approve_match_result(uuid, text) to authenticated;

-- Updated-at triggers.
do $$
declare t text;
begin
  foreach t in array array['profiles','game_accounts','communities','teams','events','matches'] loop
    execute format('drop trigger if exists set_updated_at on public.%I', t);
    execute format('create trigger set_updated_at before update on public.%I for each row execute procedure app_private.set_updated_at()', t);
  end loop;
end $$;

-- RLS on every exposed application table.
alter table public.profiles enable row level security;
alter table public.games enable row level security;
alter table public.game_accounts enable row level security;
alter table public.game_profile_snapshots enable row level security;
alter table public.communities enable row level security;
alter table public.community_members enable row level security;
alter table public.community_invites enable row level security;
alter table public.channels enable row level security;
alter table public.channel_members enable row level security;
alter table public.messages enable row level security;
alter table public.message_reactions enable row level security;
alter table public.teams enable row level security;
alter table public.team_members enable row level security;
alter table public.team_invites enable row level security;
alter table public.events enable row level security;
alter table public.event_registrations enable row level security;
alter table public.registration_players enable row level security;
alter table public.matches enable row level security;
alter table public.match_participants enable row level security;
alter table public.match_checkins enable row level security;
alter table public.room_credentials enable row level security;
alter table public.match_results enable row level security;
alter table public.result_evidence enable row level security;
alter table public.result_disputes enable row level security;
alter table public.event_standings enable row level security;
alter table public.notifications enable row level security;
alter table public.device_tokens enable row level security;
alter table public.moderation_reports enable row level security;
alter table public.user_blocks enable row level security;
alter table public.audit_logs enable row level security;
alter table public.liveops_sessions enable row level security;
alter table public.screen_observations enable row level security;
alter table public.lobby_checks enable row level security;
alter table public.result_candidates enable row level security;

-- Public identity is intentionally limited to the profile fields stored in this table.
create policy profiles_read_public on public.profiles for select to authenticated using (is_public or id = auth.uid());
create policy profiles_insert_self on public.profiles for insert to authenticated with check (id = auth.uid());
create policy profiles_update_self on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy games_read_all on public.games for select to anon, authenticated using (is_active);
create policy game_accounts_read_self on public.game_accounts for select to authenticated using (user_id = auth.uid());
create policy game_accounts_insert_self on public.game_accounts for insert to authenticated with check (user_id = auth.uid());
create policy game_accounts_update_self on public.game_accounts for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy game_snapshots_read_self on public.game_profile_snapshots for select to authenticated using (user_id = auth.uid());
create policy game_snapshots_insert_self on public.game_profile_snapshots for insert to authenticated with check (user_id = auth.uid());

create policy communities_read_visible on public.communities for select to authenticated using (visibility = 'public' or public.is_community_member(id) or owner_user_id = auth.uid());
create policy communities_insert_owner on public.communities for insert to authenticated with check (owner_user_id = auth.uid());
create policy communities_update_manager on public.communities for update to authenticated using (owner_user_id = auth.uid() or public.can_manage_community(id)) with check (owner_user_id = auth.uid() or public.can_manage_community(id));
create policy communities_delete_owner on public.communities for delete to authenticated using (owner_user_id = auth.uid());

create policy community_members_read_members on public.community_members for select to authenticated using (public.is_community_member(community_id) or user_id = auth.uid());
create policy community_members_join_self on public.community_members for insert to authenticated with check (user_id = auth.uid() and role = 'member' and exists (select 1 from public.communities c where c.id = community_id and c.visibility = 'public'));
create policy community_members_leave_self on public.community_members for delete to authenticated using (user_id = auth.uid() or public.can_manage_community(community_id));
create policy community_members_manage_roles on public.community_members for update to authenticated using (public.can_manage_community(community_id)) with check (public.can_manage_community(community_id));
create policy community_invites_manager on public.community_invites for all to authenticated using (public.can_manage_community(community_id)) with check (public.can_manage_community(community_id));

create policy channels_read_member on public.channels for select to authenticated using (
  (community_id is not null and public.is_community_member(community_id) and (not is_private or public.can_manage_community(community_id)))
  or (community_id is null and exists (select 1 from public.channel_members cm where cm.channel_id = id and cm.user_id = auth.uid()))
);
create policy channels_create_manager on public.channels for insert to authenticated with check (community_id is not null and public.can_manage_community(community_id));
create policy channels_update_manager on public.channels for update to authenticated using (community_id is not null and public.can_manage_community(community_id)) with check (community_id is not null and public.can_manage_community(community_id));
create policy channel_members_read_self_or_manager on public.channel_members for select to authenticated using (user_id = auth.uid() or exists (select 1 from public.channels c where c.id = channel_id and c.community_id is not null and public.can_manage_community(c.community_id)));
create policy channel_members_add_self on public.channel_members for insert to authenticated with check (user_id = auth.uid());
create policy channel_members_remove_self_or_manager on public.channel_members for delete to authenticated using (user_id = auth.uid());

create policy messages_read_channel_member on public.messages for select to authenticated using (
  exists (select 1 from public.channels c where c.id = channel_id and c.community_id is not null and public.is_community_member(c.community_id))
  or exists (select 1 from public.channel_members cm where cm.channel_id = channel_id and cm.user_id = auth.uid())
);
create policy messages_send_channel_member on public.messages for insert to authenticated with check (
  sender_id = auth.uid() and (
    exists (select 1 from public.channels c where c.id = channel_id and c.community_id is not null and public.is_community_member(c.community_id))
    or exists (select 1 from public.channel_members cm where cm.channel_id = channel_id and cm.user_id = auth.uid())
  )
);
create policy messages_update_sender_or_manager on public.messages for update to authenticated using (
  sender_id = auth.uid() or exists (select 1 from public.channels c where c.id = channel_id and c.community_id is not null and public.can_manage_community(c.community_id))
) with check (
  sender_id = auth.uid() or exists (select 1 from public.channels c where c.id = channel_id and c.community_id is not null and public.can_manage_community(c.community_id))
);
create policy reactions_read_channel_member on public.message_reactions for select to authenticated using (exists (
  select 1 from public.messages m join public.channels c on c.id = m.channel_id
  where m.id = message_id and c.community_id is not null and public.is_community_member(c.community_id)
));
create policy reactions_manage_self on public.message_reactions for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy teams_read_visible on public.teams for select to authenticated using (is_public or owner_user_id = auth.uid() or public.is_team_member(id));
create policy teams_insert_owner on public.teams for insert to authenticated with check (owner_user_id = auth.uid());
create policy teams_update_owner on public.teams for update to authenticated using (owner_user_id = auth.uid() or exists (select 1 from public.team_members tm where tm.team_id = id and tm.user_id = auth.uid() and tm.role = 'captain')) with check (owner_user_id = auth.uid() or exists (select 1 from public.team_members tm where tm.team_id = id and tm.user_id = auth.uid() and tm.role = 'captain'));
create policy teams_delete_owner on public.teams for delete to authenticated using (owner_user_id = auth.uid());
create policy team_members_read_roster on public.team_members for select to authenticated using (public.is_team_member(team_id) or exists (select 1 from public.teams t where t.id = team_id and t.is_public));
create policy team_members_add_self on public.team_members for insert to authenticated with check (user_id = auth.uid() and exists (select 1 from public.teams t where t.id = team_id and t.owner_user_id = auth.uid()));
create policy team_members_leave on public.team_members for delete to authenticated using (user_id = auth.uid() or exists (select 1 from public.teams t where t.id = team_id and t.owner_user_id = auth.uid()));
create policy team_invites_participants on public.team_invites for select to authenticated using (invited_user_id = auth.uid() or invited_by = auth.uid() or public.is_team_member(team_id));
create policy team_invites_create_captain on public.team_invites for insert to authenticated with check (invited_by = auth.uid() and exists (select 1 from public.team_members tm where tm.team_id = team_id and tm.user_id = auth.uid() and tm.role in ('owner','captain')));
create policy team_invites_respond_invitee on public.team_invites for update to authenticated using (invited_user_id = auth.uid()) with check (invited_user_id = auth.uid());

create policy events_read_published on public.events for select to authenticated using (
  status <> 'draft' or organizer_id = auth.uid() or (community_id is not null and public.can_manage_community(community_id))
);
create policy events_create_organizer on public.events for insert to authenticated with check (organizer_id = auth.uid());
create policy events_update_organizer on public.events for update to authenticated using (public.is_event_staff(id)) with check (public.is_event_staff(id));
create policy events_delete_organizer on public.events for delete to authenticated using (organizer_id = auth.uid());

create policy registrations_read_owner_or_staff on public.event_registrations for select to authenticated using (
  captain_user_id = auth.uid() or (team_id is not null and public.is_team_member(team_id)) or public.is_event_staff(event_id)
);
create policy registrations_insert_self on public.event_registrations for insert to authenticated with check (captain_user_id = auth.uid());
create policy registrations_update_staff_or_captain on public.event_registrations for update to authenticated using (captain_user_id = auth.uid() or public.is_event_staff(event_id)) with check (captain_user_id = auth.uid() or public.is_event_staff(event_id));
create policy registration_players_read_owner_or_staff on public.registration_players for select to authenticated using (user_id = auth.uid() or exists (select 1 from public.event_registrations r where r.id = registration_id and public.is_event_staff(r.event_id)));
create policy registration_players_add_captain on public.registration_players for insert to authenticated with check (user_id = auth.uid() or exists (select 1 from public.event_registrations r where r.id = registration_id and r.captain_user_id = auth.uid()));

create policy matches_read_event_members on public.matches for select to authenticated using (
  public.is_event_staff(event_id) or exists (
    select 1 from public.match_participants mp where mp.match_id = id and public.is_team_member(mp.team_id)
  )
);
create policy matches_create_staff on public.matches for insert to authenticated with check (public.is_event_staff(event_id));
create policy matches_update_staff on public.matches for update to authenticated using (public.is_event_staff(event_id)) with check (public.is_event_staff(event_id));
create policy participants_read_team_or_staff on public.match_participants for select to authenticated using (public.is_team_member(team_id) or exists (select 1 from public.matches m where m.id = match_id and public.is_event_staff(m.event_id)));
create policy participants_manage_staff on public.match_participants for all to authenticated using (exists (select 1 from public.matches m where m.id = match_id and public.is_event_staff(m.event_id))) with check (exists (select 1 from public.matches m where m.id = match_id and public.is_event_staff(m.event_id)));
create policy checkins_read_self_or_staff on public.match_checkins for select to authenticated using (user_id = auth.uid() or exists (select 1 from public.matches m where m.id = match_id and public.is_event_staff(m.event_id)));
create policy checkins_upsert_self on public.match_checkins for insert to authenticated with check (user_id = auth.uid() and exists (
  select 1 from public.match_participants mp join public.team_members tm on tm.team_id = mp.team_id
  where mp.match_id = match_id and tm.user_id = auth.uid()
));
create policy checkins_update_self on public.match_checkins for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy room_credentials_read_eligible on public.room_credentials for select to authenticated using (
  release_at <= now() and exists (
    select 1 from public.matches m
    join public.match_participants mp on mp.match_id = m.id
    where m.id = match_id and public.is_team_member(mp.team_id)
  ) or exists (select 1 from public.matches m where m.id = match_id and public.is_event_staff(m.event_id))
);
create policy room_credentials_create_staff on public.room_credentials for insert to authenticated with check (exists (select 1 from public.matches m where m.id = match_id and public.is_event_staff(m.event_id)));

create policy results_read_participant_or_staff on public.match_results for select to authenticated using (
  public.is_team_member(team_id) or exists (
    select 1 from public.matches m where m.id = match_id and public.is_event_staff(m.event_id)
  )
);
create policy results_submit_team_member on public.match_results for insert to authenticated with check (submitted_by = auth.uid() and public.is_team_member(team_id) and status in ('submitted','under_review'));
create policy evidence_read_uploader_or_staff on public.result_evidence for select to authenticated using (
  uploaded_by = auth.uid() or exists (
    select 1 from public.match_results r join public.matches m on m.id = r.match_id
    where r.id = result_id and public.is_event_staff(m.event_id)
  )
);
create policy evidence_insert_owner on public.result_evidence for insert to authenticated with check (uploaded_by = auth.uid());
create policy disputes_read_reporter_or_staff on public.result_disputes for select to authenticated using (
  opened_by = auth.uid() or exists (select 1 from public.match_results r join public.matches m on m.id = r.match_id where r.id = result_id and public.is_event_staff(m.event_id))
);
create policy disputes_open_team_member on public.result_disputes for insert to authenticated with check (opened_by = auth.uid() and exists (select 1 from public.match_results r where r.id = result_id and public.is_team_member(r.team_id)));
create policy disputes_decide_staff on public.result_disputes for update to authenticated using (exists (select 1 from public.match_results r join public.matches m on m.id = r.match_id where r.id = result_id and public.is_event_staff(m.event_id))) with check (exists (select 1 from public.match_results r join public.matches m on m.id = r.match_id where r.id = result_id and public.is_event_staff(m.event_id)));

create policy standings_read_published on public.event_standings for select to authenticated using (exists (select 1 from public.events e where e.id = event_id and e.status <> 'draft'));
create policy notifications_read_self on public.notifications for select to authenticated using (user_id = auth.uid());
create policy notifications_update_self on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy device_tokens_self on public.device_tokens for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy moderation_reports_read_reporter_or_staff on public.moderation_reports for select to authenticated using (
  reporter_id = auth.uid() or (community_id is not null and public.can_manage_community(community_id))
);
create policy moderation_reports_insert_self on public.moderation_reports for insert to authenticated with check (reporter_id = auth.uid());
create policy moderation_reports_update_staff on public.moderation_reports for update to authenticated using (community_id is not null and public.can_manage_community(community_id)) with check (community_id is not null and public.can_manage_community(community_id));
create policy blocks_self on public.user_blocks for all to authenticated using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

create policy audit_logs_read_staff on public.audit_logs for select to authenticated using (
  (community_id is not null and public.can_manage_community(community_id)) or (event_id is not null and public.is_event_staff(event_id))
);
create policy liveops_sessions_read_owner_or_staff on public.liveops_sessions for select to authenticated using (
  operator_id = auth.uid() or (match_id is not null and exists (select 1 from public.matches m where m.id = match_id and public.is_event_staff(m.event_id)))
);
create policy liveops_sessions_insert_self on public.liveops_sessions for insert to authenticated with check (operator_id = auth.uid());
create policy liveops_sessions_update_owner on public.liveops_sessions for update to authenticated using (operator_id = auth.uid()) with check (operator_id = auth.uid());
create policy observations_read_session_owner_or_staff on public.screen_observations for select to authenticated using (exists (
  select 1 from public.liveops_sessions s where s.id = session_id and (s.operator_id = auth.uid() or (s.match_id is not null and exists (select 1 from public.matches m where m.id = s.match_id and public.is_event_staff(m.event_id))))
));
create policy observations_insert_session_owner on public.screen_observations for insert to authenticated with check (exists (select 1 from public.liveops_sessions s where s.id = session_id and s.operator_id = auth.uid()));
create policy lobby_checks_read_session_owner_or_staff on public.lobby_checks for select to authenticated using (exists (
  select 1 from public.liveops_sessions s where s.id = session_id and (s.operator_id = auth.uid() or (s.match_id is not null and exists (select 1 from public.matches m where m.id = s.match_id and public.is_event_staff(m.event_id))))
));
create policy lobby_checks_insert_session_owner on public.lobby_checks for insert to authenticated with check (exists (select 1 from public.liveops_sessions s where s.id = session_id and s.operator_id = auth.uid()));
create policy result_candidates_read_team_or_staff on public.result_candidates for select to authenticated using (
  (team_id is not null and public.is_team_member(team_id)) or exists (select 1 from public.matches m where m.id = match_id and public.is_event_staff(m.event_id))
);
create policy result_candidates_insert_operator on public.result_candidates for insert to authenticated with check (exists (
  select 1 from public.screen_observations o join public.liveops_sessions s on s.id = o.session_id
  where o.id = source_observation_id and s.operator_id = auth.uid()
));

-- Evidence bucket is private. Object path must begin with the uploader's UUID.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('match-evidence', 'match-evidence', false, 10485760, array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;

create policy match_evidence_upload_own on storage.objects for insert to authenticated
with check (bucket_id = 'match-evidence' and (storage.foldername(name))[1] = auth.uid()::text);
create policy match_evidence_read_own on storage.objects for select to authenticated
using (bucket_id = 'match-evidence' and (storage.foldername(name))[1] = auth.uid()::text);

-- Enable message changes for Supabase Realtime if the default publication exists.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table public.messages;
    exception when duplicate_object then null;
    end;
  end if;
end $$;

-- Least-privilege Data API grants. RLS above controls rows.
grant usage on schema public to anon, authenticated;
grant select on public.games to anon, authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update on public.game_accounts to authenticated;
grant select, insert on public.game_profile_snapshots to authenticated;
grant select, insert, update, delete on public.communities to authenticated;
grant select, insert, update, delete on public.community_members to authenticated;
grant select, insert, update, delete on public.community_invites to authenticated;
grant select, insert, update, delete on public.channels to authenticated;
grant select, insert, delete on public.channel_members to authenticated;
grant select, insert, update on public.messages to authenticated;
grant select, insert, delete on public.message_reactions to authenticated;
grant select, insert, update, delete on public.teams to authenticated;
grant select, insert, update, delete on public.team_members to authenticated;
grant select, insert, update on public.team_invites to authenticated;
grant select, insert, update, delete on public.events to authenticated;
grant select, insert, update on public.event_registrations to authenticated;
grant select, insert, update on public.registration_players to authenticated;
grant select, insert, update on public.matches to authenticated;
grant select, insert, update on public.match_participants to authenticated;
grant select, insert, update on public.match_checkins to authenticated;
grant select, insert on public.room_credentials to authenticated;
grant select, insert on public.match_results to authenticated;
grant select, insert on public.result_evidence to authenticated;
grant select, insert, update on public.result_disputes to authenticated;
grant select on public.event_standings to authenticated;
grant select, update on public.notifications to authenticated;
grant select, insert, update, delete on public.device_tokens to authenticated;
grant select, insert, update on public.moderation_reports to authenticated;
grant select, insert, delete on public.user_blocks to authenticated;
grant select on public.audit_logs to authenticated;
grant select, insert, update on public.liveops_sessions to authenticated;
grant select, insert on public.screen_observations to authenticated;
grant select, insert on public.lobby_checks to authenticated;
grant select, insert on public.result_candidates to authenticated;
