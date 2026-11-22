BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT extensions.plan(7);

SELECT extensions.ok(
  to_regprocedure('public.record_liveops_roster_alert_decision(uuid,text,text)') IS NOT NULL,
  'The host roster-alert decision RPC exists'
);
SELECT extensions.ok(
  has_function_privilege('authenticated','public.record_liveops_roster_alert_decision(uuid,text,text)','EXECUTE'),
  'Authenticated users may submit decisions subject to RPC authorization'
);
SELECT extensions.ok(
  NOT has_function_privilege('anon','public.record_liveops_roster_alert_decision(uuid,text,text)','EXECUTE'),
  'Anonymous callers cannot submit host decisions'
);
SELECT extensions.ok(
  (SELECT prosecdef FROM pg_proc WHERE oid='public.record_liveops_roster_alert_decision(uuid,text,text)'::regprocedure),
  'Decision logging uses a controlled security-definer boundary'
);
SELECT extensions.ok(
  position('s.operator_id = v_uid' IN
    pg_get_functiondef('public.record_liveops_roster_alert_decision(uuid,text,text)'::regprocedure)) > 0
  AND position('event.matches.operate' IN
    pg_get_functiondef('public.record_liveops_roster_alert_decision(uuid,text,text)'::regprocedure)) > 0,
  'Only the authorised LiveOps operator with Match-operation permission can log a decision'
);
SELECT extensions.ok(
  position('liveops_roster_alert_adjusted_in_game' IN
    pg_get_functiondef('public.record_liveops_roster_alert_decision(uuid,text,text)'::regprocedure)) > 0
  AND position('liveops_roster_alert_kept_as_is' IN
    pg_get_functiondef('public.record_liveops_roster_alert_decision(uuid,text,text)'::regprocedure)) > 0,
  'Both adjusted-in-game and kept-as-is decisions are auditable'
);
SELECT extensions.ok(
  position('roster_changed' IN
    pg_get_functiondef('public.record_liveops_roster_alert_decision(uuid,text,text)'::regprocedure)) > 0
  AND position('game_action_performed_by_komnivo' IN
    pg_get_functiondef('public.record_liveops_roster_alert_decision(uuid,text,text)'::regprocedure)) > 0,
  'The audit record explicitly confirms no roster mutation or automated game action'
);

SELECT * FROM extensions.finish();
ROLLBACK;
