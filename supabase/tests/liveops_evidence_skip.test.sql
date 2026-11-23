-- Phase 5 evidence-skip contracts: a reasoned skip advances the Lobby but never scores.
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(17);

select extensions.has_column('public','liveops_sessions','evidence_skipped_at',
  'A LiveOps session records whether its evidence step was explicitly skipped');
select extensions.has_column('public','liveops_sessions','evidence_skip_reason',
  'A skipped evidence step must preserve the organiser/operator reason');
select extensions.ok(
  to_regprocedure('public.skip_liveops_match_evidence(uuid,text)') is not null,
  'The authenticated app has a dedicated Match evidence skip RPC'
);
select extensions.ok(
  to_regprocedure('app_private.skip_liveops_match_evidence(uuid,text)') is not null,
  'The skip implementation stays in the private schema'
);
select extensions.ok(
  has_function_privilege('authenticated','public.skip_liveops_match_evidence(uuid,text)','EXECUTE'),
  'Authenticated users can invoke the reasoned skip wrapper'
);
select extensions.ok(
  not has_function_privilege('anon','public.skip_liveops_match_evidence(uuid,text)','EXECUTE'),
  'Anonymous users cannot skip Match evidence'
);
select extensions.ok(
  has_function_privilege('authenticated','app_private.skip_liveops_match_evidence(uuid,text)','EXECUTE'),
  'Authenticated wrapper execution is permitted to call the private implementation'
);
select extensions.ok(
  not has_function_privilege('anon','app_private.skip_liveops_match_evidence(uuid,text)','EXECUTE'),
  'Anonymous users cannot call the private implementation'
);
select extensions.ok(
  (select prosecdef from pg_proc
   where oid='app_private.skip_liveops_match_evidence(uuid,text)'::regprocedure),
  'Skip implementation is a constrained SECURITY DEFINER RPC'
);
select extensions.ok(
  position('resolve_permission' in pg_get_functiondef(
    'app_private.skip_liveops_match_evidence(uuid,text)'::regprocedure
  )) > 0
  and position('v_session.state <> ''paused''' in pg_get_functiondef(
    'app_private.skip_liveops_match_evidence(uuid,text)'::regprocedure
  )) > 0
  and position('liveops_evidence_step_skipped' in pg_get_functiondef(
    'app_private.skip_liveops_match_evidence(uuid,text)'::regprocedure
  )) > 0,
  'Skip checks exact Match permission, requires a paused session and audits the reason'
);
select extensions.ok(
  position('evidence_skipped_at' in pg_get_functiondef(
    'app_private.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure
  )) > 0
  and position('evidence_skip_reason' in pg_get_functiondef(
    'app_private.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure
  )) > 0,
  'Next Match accepts only a reasoned evidence skip as the alternate to full result submission'
);
select extensions.ok(
  position('any_result.match_id=v_previous.match_id' in pg_get_functiondef(
    'app_private.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure
  )) > 0,
  'Skip cannot bypass a Match that already has official result rows'
);
select extensions.ok(
  position('skipped.evidence_skipped_at' in pg_get_functiondef(
    'app_private.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure
  )) > 0
  and position('skipped.evidence_skipped_at' in pg_get_functiondef(
    'app_private.start_liveops_lobby_session(uuid,jsonb)'::regprocedure
  )) > 0,
  'Lobby progression and restart recovery do not select already-skipped Matches'
);
select extensions.ok(
  position('v_session.evidence_skipped_at' in pg_get_functiondef(
    'app_private.register_liveops_evidence_batch(uuid,uuid,uuid,text,text,jsonb)'::regprocedure
  )) > 0,
  'A skipped session cannot upload additional evidence'
);
select extensions.ok(
  position('v_session.evidence_skipped_at' in pg_get_functiondef(
    'app_private.save_liveops_team_candidate(uuid,uuid,integer,integer,uuid[])'::regprocedure
  )) > 0,
  'A skipped session cannot add or change OCR candidates'
);
select extensions.ok(
  position('v_session.evidence_skipped_at' in pg_get_functiondef(
    'app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure
  )) > 0
  AND CASE
    WHEN to_regprocedure('app_private.submit_liveops_match_results(uuid,uuid,text[],jsonb)') IS NULL THEN true
    ELSE position('v_session.evidence_skipped_at' in pg_get_functiondef(
      to_regprocedure('app_private.submit_liveops_match_results(uuid,uuid,text[],jsonb)')
    )) > 0
  END,
  'Reviewed results block skipped sessions; any installed legacy endpoint is also guarded'
);
select extensions.ok(
  position('insert into public.match_results' in lower(pg_get_functiondef(
    'app_private.skip_liveops_match_evidence(uuid,text)'::regprocedure
  ))) = 0,
  'The skip RPC creates no match_results rows or scores'
);

select * from extensions.finish();
rollback;
