-- Move privileged RPC implementations out of the exposed public schema.
-- Keep thin SECURITY INVOKER wrappers in public for PostgREST RPC compatibility.
-- Apply after 202611090008_match_and_dispute_guardrails.sql.

-- The schema is not exposed through the Data API. Authenticated callers need only
-- PostgreSQL USAGE/EXECUTE so the public invoker wrappers and RLS predicates can call
-- the internal, tightly-scoped functions.
grant usage on schema app_private to authenticated;

alter function public.is_community_member(uuid) set schema app_private;
alter function public.can_manage_community(uuid) set schema app_private;
alter function public.is_team_member(uuid) set schema app_private;
alter function public.is_event_staff(uuid) set schema app_private;

alter function public.register_for_event(uuid, uuid) set schema app_private;
alter function public.approve_match_result(uuid, text) set schema app_private;
alter function public.consume_community_invite(uuid, text) set schema app_private;
alter function public.lock_event_rosters(uuid) set schema app_private;
alter function public.create_match(uuid, uuid[], timestamptz, text) set schema app_private;
alter function public.generate_event_groups(uuid, integer, integer) set schema app_private;

-- Revoke default function access and explicitly grant only to authenticated callers.
revoke all on function app_private.is_community_member(uuid) from public, anon, authenticated;
revoke all on function app_private.can_manage_community(uuid) from public, anon, authenticated;
revoke all on function app_private.is_team_member(uuid) from public, anon, authenticated;
revoke all on function app_private.is_event_staff(uuid) from public, anon, authenticated;
revoke all on function app_private.register_for_event(uuid, uuid) from public, anon, authenticated;
revoke all on function app_private.approve_match_result(uuid, text) from public, anon, authenticated;
revoke all on function app_private.consume_community_invite(uuid, text) from public, anon, authenticated;
revoke all on function app_private.lock_event_rosters(uuid) from public, anon, authenticated;
revoke all on function app_private.create_match(uuid, uuid[], timestamptz, text) from public, anon, authenticated;
revoke all on function app_private.generate_event_groups(uuid, integer, integer) from public, anon, authenticated;

grant execute on function app_private.is_community_member(uuid) to authenticated;
grant execute on function app_private.can_manage_community(uuid) to authenticated;
grant execute on function app_private.is_team_member(uuid) to authenticated;
grant execute on function app_private.is_event_staff(uuid) to authenticated;
grant execute on function app_private.register_for_event(uuid, uuid) to authenticated;
grant execute on function app_private.approve_match_result(uuid, text) to authenticated;
grant execute on function app_private.consume_community_invite(uuid, text) to authenticated;
grant execute on function app_private.lock_event_rosters(uuid) to authenticated;
grant execute on function app_private.create_match(uuid, uuid[], timestamptz, text) to authenticated;
grant execute on function app_private.generate_event_groups(uuid, integer, integer) to authenticated;

-- Public RPC wrapper: no privilege escalation; internal function checks auth.uid(), ownership,
-- event/community permissions, registration state and input constraints itself.
create or replace function public.is_community_member(p_community_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = public, app_private, pg_temp
as $$ select app_private.is_community_member(p_community_id) $$;

create or replace function public.can_manage_community(p_community_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = public, app_private, pg_temp
as $$ select app_private.can_manage_community(p_community_id) $$;

create or replace function public.is_team_member(p_team_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = public, app_private, pg_temp
as $$ select app_private.is_team_member(p_team_id) $$;

create or replace function public.is_event_staff(p_event_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = public, app_private, pg_temp
as $$ select app_private.is_event_staff(p_event_id) $$;

create or replace function public.register_for_event(p_event_id uuid, p_team_id uuid default null)
returns jsonb
language sql
security invoker
set search_path = public, app_private, pg_temp
as $$ select app_private.register_for_event(p_event_id, p_team_id) $$;

create or replace function public.approve_match_result(p_result_id uuid, p_reason text default null)
returns jsonb
language sql
security invoker
set search_path = public, app_private, pg_temp
as $$ select app_private.approve_match_result(p_result_id, p_reason) $$;

create or replace function public.consume_community_invite(p_community_id uuid, p_token_hash text)
returns boolean
language sql
security invoker
set search_path = public, app_private, pg_temp
as $$ select app_private.consume_community_invite(p_community_id, p_token_hash) $$;

create or replace function public.lock_event_rosters(p_event_id uuid)
returns jsonb
language sql
security invoker
set search_path = public, app_private, pg_temp
as $$ select app_private.lock_event_rosters(p_event_id) $$;

create or replace function public.create_match(
  p_event_id uuid,
  p_team_ids uuid[],
  p_starts_at timestamptz default null,
  p_group_label text default null
)
returns uuid
language sql
security invoker
set search_path = public, app_private, pg_temp
as $$ select app_private.create_match(p_event_id, p_team_ids, p_starts_at, p_group_label) $$;

create or replace function public.generate_event_groups(
  p_event_id uuid,
  p_round_number integer,
  p_group_size integer
)
returns jsonb
language sql
security invoker
set search_path = public, app_private, pg_temp
as $$ select app_private.generate_event_groups(p_event_id, p_round_number, p_group_size) $$;

revoke all on function public.is_community_member(uuid) from public, anon;
revoke all on function public.can_manage_community(uuid) from public, anon;
revoke all on function public.is_team_member(uuid) from public, anon;
revoke all on function public.is_event_staff(uuid) from public, anon;
revoke all on function public.register_for_event(uuid, uuid) from public, anon;
revoke all on function public.approve_match_result(uuid, text) from public, anon;
revoke all on function public.consume_community_invite(uuid, text) from public, anon;
revoke all on function public.lock_event_rosters(uuid) from public, anon;
revoke all on function public.create_match(uuid, uuid[], timestamptz, text) from public, anon;
revoke all on function public.generate_event_groups(uuid, integer, integer) from public, anon;

grant execute on function public.is_community_member(uuid) to authenticated;
grant execute on function public.can_manage_community(uuid) to authenticated;
grant execute on function public.is_team_member(uuid) to authenticated;
grant execute on function public.is_event_staff(uuid) to authenticated;
grant execute on function public.register_for_event(uuid, uuid) to authenticated;
grant execute on function public.approve_match_result(uuid, text) to authenticated;
grant execute on function public.consume_community_invite(uuid, text) to authenticated;
grant execute on function public.lock_event_rosters(uuid) to authenticated;
grant execute on function public.create_match(uuid, uuid[], timestamptz, text) to authenticated;
grant execute on function public.generate_event_groups(uuid, integer, integer) to authenticated;
