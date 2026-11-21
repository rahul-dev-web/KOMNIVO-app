-- LiveOps screenshot evidence batch and Match-scope contracts.
-- Run with: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(21);

select extensions.has_table('public','liveops_evidence_batches',
  'Evidence is grouped in a persisted batch');
select extensions.has_column('public.liveops_captures','evidence_batch_id',
  'Every uploaded screenshot can reference its batch');
select extensions.has_column('public.liveops_captures','sequence_no',
  'Screenshot order is preserved');
select extensions.has_column('public.liveops_captures','content_sha256',
  'Exact screenshot duplicates can be detected');
select extensions.has_column('public.screen_observations','liveops_capture_id',
  'OCR observation points to its source screenshot');
select extensions.has_column('public.screen_observations','evidence_batch_id',
  'OCR observation remains attached to its evidence batch');

select extensions.ok(
  (select relrowsecurity from pg_class where oid='public.liveops_evidence_batches'::regclass),
  'Evidence batch access is protected by RLS'
);
select extensions.ok(
  to_regprocedure('public.register_liveops_evidence_batch(uuid,uuid,uuid,text,text,jsonb)') is not null,
  'A single registration RPC persists a complete screenshot batch'
);
select extensions.ok(
  to_regprocedure('app_private.register_liveops_evidence_batch(uuid,uuid,uuid,text,text,jsonb)') is not null,
  'The validated batch transaction lives in the private schema'
);
select extensions.ok(
  has_function_privilege('authenticated','public.register_liveops_evidence_batch(uuid,uuid,uuid,text,text,jsonb)','EXECUTE'),
  'Signed-in operators can register their evidence batch'
);
select extensions.ok(
  not has_function_privilege('anon','public.register_liveops_evidence_batch(uuid,uuid,uuid,text,text,jsonb)','EXECUTE'),
  'Anonymous users cannot register evidence'
);
select extensions.ok(
  exists(select 1 from pg_constraint where conrelid='public.liveops_evidence_batches'::regclass
    and conname='liveops_evidence_batches_session_id_match_id_idempotency_key_key'),
  'Batch retries are idempotent per session and Match ID'
);
select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='liveops_captures' and indexname='liveops_captures_batch_sequence_uidx'),
  'Screenshot order is unique within a batch'
);
select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='liveops_captures' and indexname='liveops_captures_match_content_hash_uidx' and indexdef ilike '%(match_id, content_sha256)%'),
  'Exact duplicate screenshot hashes are unique per Match ID, including across resumed sessions'
);
select extensions.ok(
  position('NEW.lobby_id IS DISTINCT FROM OLD.lobby_id'
    in pg_get_functiondef('app_private.guard_liveops_session_scope()'::regprocedure)) > 0,
  'A LiveOps session Lobby ID cannot be reassigned'
);
select extensions.ok(
  position('evidence_batch_id' in
    pg_get_functiondef('app_private.guard_liveops_capture_scope()'::regprocedure)) > 0,
  'A capture cannot be moved to another evidence batch or Match ID'
);
select extensions.ok(
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects'
    and policyname='match_evidence_delete_unregistered_own'
    and qual ilike '%NOT%liveops_captures%'),
  'Uploader can clean only unregistered evidence objects'
);
select extensions.ok(
  (select public=false from storage.buckets where id='match-evidence'),
  'Match Evidence bucket remains private'
);
select extensions.ok(
  (select file_size_limit=10485760 from storage.buckets where id='match-evidence'),
  'Screenshot upload is capped at the existing 10 MiB bucket limit'
);
select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='liveops_evidence_batches' and indexname='liveops_evidence_batches_match_idx'),
  'Evidence batch Match ID lookup is indexed'
);
select extensions.ok(
  exists(select 1 from pg_policies where schemaname='public'
    and tablename='liveops_evidence_batches'
    and policyname='liveops_evidence_batches_read_operator_or_reviewer'
    and cmd='SELECT'),
  'Only the operator or authorised event managers/reviewers can read batch metadata'
);

select * from extensions.finish();
rollback;
