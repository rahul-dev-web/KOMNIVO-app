BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT extensions.plan(11);

SELECT extensions.ok(
  to_regprocedure('public.get_liveops_match_roster_snapshot(uuid)') IS NOT NULL,
  'The operator-scoped LiveOps Match roster snapshot RPC exists'
);
SELECT extensions.ok(
  has_function_privilege('authenticated','public.get_liveops_match_roster_snapshot(uuid)','EXECUTE'),
  'Authenticated users may call the RPC subject to server-side permission checks'
);
SELECT extensions.ok(
  NOT has_function_privilege('anon','public.get_liveops_match_roster_snapshot(uuid)','EXECUTE'),
  'Anonymous callers cannot execute the roster snapshot RPC'
);
SELECT extensions.ok(
  (SELECT prosecdef FROM pg_proc WHERE oid='public.get_liveops_match_roster_snapshot(uuid)'::regprocedure),
  'The RPC uses a controlled security-definer boundary'
);
SELECT extensions.ok(
  position('s.operator_id = v_uid' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('event.matches.operate' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'The RPC is limited to the authenticated session operator with Match-operation permission'
);
SELECT extensions.ok(
  position('public.match_participants' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('public.registration_players' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'Expected players derive from the exact Match slot and registration roster'
);
SELECT extensions.ok(
  position('r.roster_locked IS TRUE AND r.roster_locked_at IS NOT NULL' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'The snapshot reports locked only when every participant registration has an explicit lock timestamp'
);
SELECT extensions.ok(
  position('gps.captured_at <= r.roster_locked_at' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('ga.last_synced_at <= r.roster_locked_at' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'Profile identity is selected strictly as-of the explicit roster-lock timestamp'
);
SELECT extensions.ok(
  position('roster_snapshot_fingerprint' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('md5(v_match.id::text ||' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'The response includes a deterministic Match roster snapshot fingerprint'
);
SELECT extensions.ok(
  position('v_roster_locked AND ga.ownership_status = ''verified''' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('THEN ga.uid ELSE NULL END' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'UID and account IDs are withheld until the roster is locked and ownership is verified'
);
SELECT extensions.ok(
  position('registered_at' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) = 0,
  'Registration time is never substituted for an explicit roster lock'
);

SELECT * FROM extensions.finish();
ROLLBACK;
