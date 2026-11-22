BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT extensions.plan(9);

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
  'Snapshot creation is serialised and later reads reuse the stored session snapshot'
);
SELECT extensions.ok(
  position('INSERT INTO public.liveops_match_roster_snapshots' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('ON CONFLICT (match_id) DO NOTHING' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'The first complete locked roster is stored once per Match ID'
);
SELECT extensions.ok(
  position('r.roster_locked IS TRUE AND r.roster_locked_at IS NOT NULL' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('gps.captured_at <= r.roster_locked_at' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'Only explicitly locked rosters and profile snapshots no later than the lock time are captured'
);
SELECT extensions.ok(
  position('snapshot_fingerprint' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0
  AND position('snapshot_reused' IN pg_get_functiondef('public.get_liveops_match_roster_snapshot(uuid)'::regprocedure)) > 0,
  'The RPC returns a stable fingerprint and indicates stored snapshot reuse'
);
SELECT extensions.ok(
  has_function_privilege('authenticated','public.get_liveops_match_roster_snapshot(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.get_liveops_match_roster_snapshot(uuid)','EXECUTE'),
  'Only authenticated callers can invoke the operator-scoped snapshot RPC'
);

SELECT * FROM extensions.finish();
ROLLBACK;
