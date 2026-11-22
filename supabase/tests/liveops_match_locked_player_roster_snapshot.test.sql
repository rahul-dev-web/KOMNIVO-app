BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT extensions.plan(8);

SELECT extensions.ok(
  to_regprocedure('public.get_liveops_match_roster_snapshot(uuid)') IS NOT NULL,
  'The LiveOps Match roster snapshot RPC exists'
);

SELECT extensions.ok(
  has_function_privilege('authenticated','public.get_liveops_match_roster_snapshot(uuid)','EXECUTE'),
  'Authenticated users can call the RPC subject to server-side ownership and permission checks'
);

SELECT extensions.ok(
  NOT has_function_privilege('anon','public.get_liveops_match_roster_snapshot(uuid)','EXECUTE'),
  'Anonymous callers cannot execute the roster snapshot RPC'
);

SELECT extensions.ok(
  (SELECT prosecdef FROM pg_proc WHERE oid='public.get_liveops_match_roster_snapshot(uuid)'::regprocedure),
  'The RPC uses a controlled security-definer boundary for cross-player identity reads'
);

SELECT extensions.ok(
  position('s.operator_id = v_uid' IN
    pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('event.matches.operate' IN
    pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'The RPC is restricted to the authenticated session operator with Match-operations permission'
);

SELECT extensions.ok(
  position('public.match_participants' IN
    pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('public.registration_players' IN
    pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'Expected players are derived from the exact Match slot and registration roster'
);

SELECT extensions.ok(
  position('gps.captured_at <= COALESCE(r.roster_locked_at,r.registered_at)' IN
    pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'Profile identity is read as-of roster lock and ignores later profile refreshes'
);

SELECT extensions.ok(
  position('ga.ownership_status = ''verified''' IN
    pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('THEN ga.uid ELSE NULL END' IN
    pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'Only verified game-account identities and UIDs are exposed'
);

SELECT * FROM extensions.finish();
ROLLBACK;
