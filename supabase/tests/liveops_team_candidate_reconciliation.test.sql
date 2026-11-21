-- Canonical Match ID + Team ID OCR candidate and screenshot provenance contracts.
-- Run with: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(20);

select extensions.has_table('public','result_candidate_evidence',
  'A candidate can retain multiple screenshot evidence sources');
select extensions.has_column('public','result_candidates','updated_at',
  'Candidate updates are timestamped');
select extensions.has_column('public','result_candidates','reviewed_by',
  'Reviewer identity is tracked separately from the operator');
select extensions.has_column('public','result_candidates','review_note',
  'Human review notes are persisted');
select extensions.has_column('public','result_candidate_evidence','source_observation_id',
  'Every evidence link points to its OCR observation');
select extensions.has_column('public','result_candidate_evidence','capture_id',
  'Every evidence link points to its original screenshot capture');
select extensions.has_column('public','result_candidate_evidence','evidence_batch_id',
  'Every evidence link preserves its upload batch');

select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='result_candidates' and indexname='result_candidates_match_team_uidx'
    and indexdef ilike '%(match_id, team_id)%' and indexdef ilike '%WHERE (team_id IS NOT NULL)%'),
  'One canonical row is enforced per Match ID and Team ID'
);
select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='result_candidate_evidence'
    and indexdef ilike '%(candidate_id, source_observation_id)%'),
  'The same observation cannot be linked twice to one canonical candidate'
);
select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='result_candidate_evidence'
    and indexdef ilike '%(match_id, team_id, source_observation_id)%'),
  'The same source observation cannot be linked twice for one Match and Team'
);
select extensions.ok(
  (select relrowsecurity from pg_class where oid='public.result_candidate_evidence'::regclass),
  'Candidate evidence is protected by RLS'
);
select extensions.ok(
  to_regprocedure('public.save_liveops_team_candidate(uuid,uuid,integer,integer,uuid[])') is not null,
  'An authenticated RPC saves a candidate from selected screenshot observations'
);
select extensions.ok(
  to_regprocedure('app_private.save_liveops_team_candidate(uuid,uuid,integer,integer,uuid[])') is not null,
  'Candidate reconciliation logic is contained in the private schema'
);
select extensions.ok(
  has_function_privilege('authenticated','public.save_liveops_team_candidate(uuid,uuid,integer,integer,uuid[])','EXECUTE'),
  'Signed-in authorised operators can call the candidate RPC'
);
select extensions.ok(
  not has_function_privilege('anon','public.save_liveops_team_candidate(uuid,uuid,integer,integer,uuid[])','EXECUTE'),
  'Anonymous users cannot save OCR candidates'
);
select extensions.ok(
  (select prosecdef from pg_proc
   where oid='app_private.save_liveops_team_candidate(uuid,uuid,integer,integer,uuid[])'::regprocedure),
  'Candidate write transaction is SECURITY DEFINER and validates all sources'
);
select extensions.ok(
  exists(select 1 from pg_policies where schemaname='public'
    and tablename='result_candidates' and policyname='result_candidates_read_team_or_staff'
    and qual ilike '%liveops.capture.submit%'),
  'The operator can read candidates only in a Match they are authorised to operate'
);
select extensions.ok(
  exists(select 1 from pg_policies where schemaname='public'
    and tablename='result_candidate_evidence'
    and policyname='result_candidate_evidence_read_operator_or_reviewer'
    and qual ilike '%match.results.review%'),
  'Evidence provenance is readable by the operator or authorised result reviewer'
);
select extensions.ok(
  exists(select 1 from pg_policies where schemaname='public'
    and tablename='match_participants' and policyname='participants_read_team_or_staff'
    and qual ilike '%liveops.capture.submit%'),
  'An operator can read only the roster of a Match they can operate'
);
select extensions.ok(
  exists(select 1 from pg_policies where schemaname='public'
    and tablename='teams' and policyname='teams_read_visible'
    and qual ilike '%liveops.capture.submit%'),
  'Team name/tag lookup is scoped to teams participating in an authorised Match'
);
select extensions.ok(
  exists(select 1 from pg_constraint where conrelid='public.result_candidates'::regclass
    and conname='result_candidates_review_status_check'
    and pg_get_constraintdef(oid) ilike '%accepted%'
    and pg_get_constraintdef(oid) ilike '%needs_review%'),
  'Accepted candidates can be explicitly returned to needs_review after a conflict'
);

select * from extensions.finish();
rollback;
