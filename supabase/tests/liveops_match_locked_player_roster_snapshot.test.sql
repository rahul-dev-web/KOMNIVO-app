BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT extensions.plan(14);

SELECT extensions.ok(
  to_regclass('public.liveops_match_roster_snapshots') IS NOT NULL,
  'An immutable persisted roster snapshot table exists'
);
SELECT extensions.ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid='public.liveops_match_roster_snapshots'::regclass),
  'RLS is enabled on persisted LiveOps roster snapshots'
);
SELECT extensions.ok(
  NOT has_table_privilege('authenticated','public.liveops_match_roster_snapshots','SELECT')
  AND NOT has_table_privilege('anon','public.liveops_match_roster_snapshots','SELECT'),
  'Authenticated and anonymous clients cannot read the private snapshot table directly'
);
SELECT extensions.ok(
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.liveops_match_roster_snapshots'::regclass
      AND tgname='liveops_match_roster_snapshots_immutable'
      AND NOT tgisinternal
  ),
  'Updates and deletes are rejected by an immutability trigger'
);
SELECT extensions.ok(
  position('FOR UPDATE' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('FROM public.liveops_match_roster_snapshots' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'Snapshot creation is serialised and later reads reuse the stored Match snapshot'
);
SELECT extensions.ok(
  position('INSERT INTO public.liveops_match_roster_snapshots' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('ON CONFLICT (match_id) DO NOTHING' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'The first complete team-member snapshot is stored once per Match ID'
);
SELECT extensions.ok(
  position('public.team_members' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('LEFT JOIN LATERAL' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('registration_players' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) = 0,
  'Every current Team member is sourced from team_members, not the submitted registration player list'
);
SELECT extensions.ok(
  position('ownership_status = ''verified''' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('is_community_member' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'Only verified game accounts expose matchable identity; Community membership is reported separately'
);
SELECT extensions.ok(
  position('roster_locked' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) = 0
  AND position('snapshot_ready' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'LiveOps snapshot readiness no longer depends on Organizer roster locking'
);
SELECT extensions.ok(
  position('team_members_at_capture' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('gps.captured_at <= v_snapshot_at' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'The snapshot records its Team-member capture basis and profile values as-of capture time'
);
SELECT extensions.ok(
  position('roster_locked' IN pg_get_functiondef('public.generate_event_roadmap(uuid,integer,integer)'::regprocedure)) = 0
  AND position('roster_locked' IN pg_get_functiondef('app_private.generate_event_stage_matches(uuid,integer,integer,timestamp with time zone)'::regprocedure)) = 0
  AND position('roster_locked' IN pg_get_functiondef('public.advance_event_stage_from_roadmap(uuid,integer,integer,timestamp with time zone)'::regprocedure)) = 0,
  'Approval status, not roster_locked, gates Stage 1, match generation and direct-entry validation'
);
SELECT extensions.ok(
  NOT has_function_privilege('authenticated','public.lock_event_rosters(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.lock_event_rosters(uuid)','EXECUTE'),
  'Organizer clients can no longer invoke the roster-lock RPC'
);
SELECT extensions.ok(
  has_function_privilege('authenticated','public.get_liveops_match_roster_snapshot(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.get_liveops_match_roster_snapshot(uuid)','EXECUTE'),
  'Only authenticated callers can invoke the operator-scoped snapshot RPC'
);

SELECT extensions.ok(
  position('roster_locked' IN pg_get_functiondef('app_private.create_match(uuid,uuid[],timestamp with time zone,text)'::regprocedure)) = 0
  AND position('roster_locked' IN pg_get_functiondef('app_private.generate_event_groups(uuid,integer,integer)'::regprocedure)) = 0
  AND position('roster_locked' IN pg_get_functiondef('public.publish_event_stage_roadmap(uuid,jsonb)'::regprocedure)) = 0
  AND position('roster_locked' IN pg_get_functiondef('public.set_event_stage_direct_invites(uuid,integer,uuid[])'::regprocedure)) = 0,
  'Manual Match creation, manual group generation, direct-entry roadmap validation and direct-entry selection do not require Organizer roster locks'
);

SELECT * FROM extensions.finish();
ROLLBACK;
