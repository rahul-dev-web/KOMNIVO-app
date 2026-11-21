-- Materialisation of reviewed LiveOps candidates into the official match-result pipeline.
-- Run with: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(19);

select extensions.ok(
  to_regprocedure('public.submit_reviewed_liveops_match_results(uuid,uuid)') is not null,
  'A public RPC submits accepted LiveOps candidates for official review'
);
select extensions.ok(
  to_regprocedure('app_private.submit_reviewed_liveops_match_results(uuid,uuid)') is not null,
  'The submission transaction is implemented in the private schema'
);
select extensions.ok(
  has_function_privilege('authenticated','public.submit_reviewed_liveops_match_results(uuid,uuid)','EXECUTE'),
  'Authenticated users can invoke the RPC subject to server-side Match permission'
);
select extensions.ok(
  not has_function_privilege('anon','public.submit_reviewed_liveops_match_results(uuid,uuid)','EXECUTE'),
  'Anonymous users cannot submit reviewed LiveOps results'
);
select extensions.ok(
  (select prosecdef from pg_proc
   where oid='app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure),
  'The internal transaction runs with SECURITY DEFINER and validates auth.uid'
);
select extensions.ok(
  not (select prosecdef from pg_proc
   where oid='public.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure),
  'The exposed RPC wrapper remains SECURITY INVOKER'
);
select extensions.ok(
  position('s.operator_id=v_uid' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0,
  'Submission is restricted to the authenticated operator who owns the LiveOps session'
);
select extensions.ok(
  position('v_session.state <> ''paused''' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0,
  'LiveOps observation must be paused before official result submission'
);
select extensions.ok(
  position('event_lobby_matches' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0,
  'The exact Lobby ID and Match ID relationship is verified server-side'
);
select extensions.ok(
  position('rc.review_status=''accepted''' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0
  AND position('rc.reviewed_placement' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0
  AND position('rc.reviewed_kills' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0,
  'Only accepted candidates with reviewer-confirmed placement and kills are submitted'
);
select extensions.ok(
  position('count(DISTINCT rc.reviewed_placement)' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0,
  'Reviewer-confirmed placement is unique across the Match roster'
);
select extensions.ok(
  position('result_candidate_evidence' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0
  AND position('result_evidence' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0,
  'Each official team result receives its own candidate-specific screenshot evidence'
);
select extensions.ok(
  position('storage.objects' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0,
  'Missing or deleted screenshot objects block submission'
);
select extensions.ok(
  position('already_submitted' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0
  AND position('liveops_session_id' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0,
  'Retries for the same Match and LiveOps session return existing result IDs'
);
select extensions.ok(
  position('status=''review''' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0
  AND position('''submitted''' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0,
  'New official result rows are submitted for review without being approved'
);
select extensions.ok(
  position('official_results_approved'',false' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0,
  'The submission response explicitly reports that official results are not approved'
);
select extensions.ok(
  exists(select 1 from pg_trigger
    where tgrelid='public.result_candidates'::regclass
      and tgname='result_candidates_lock_after_official_submission'
      and not tgisinternal),
  'Candidate values cannot change after official results have been created'
);
select extensions.ok(
  position('Official result submission already exists' in
    pg_get_functiondef('app_private.guard_liveops_candidate_lock_after_submission()'::regprocedure))>0,
  'The candidate guard requires an audited correction/dispute workflow after submission'
);
select extensions.ok(
  position('FOR UPDATE' in pg_get_functiondef('app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure))>0,
  'Match-row locking serialises candidate edits and result submission'
);

select * from extensions.finish();
rollback;
