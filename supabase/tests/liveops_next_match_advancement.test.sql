-- Ordered, idempotent advancement from one submitted Lobby Match to the next.
-- Run with: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(17);

select extensions.has_column('public','liveops_sessions','previous_session_id',
  'A successor LiveOps session records its predecessor');
select extensions.ok(
  exists(select 1 from pg_constraint
    where conrelid='public.liveops_sessions'::regclass
      and conname='liveops_sessions_previous_session_id_fkey'
      and pg_get_constraintdef(oid) ilike '%ON DELETE RESTRICT%'),
  'A predecessor cannot be deleted out from under its successor'
);
select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='liveops_sessions'
    and indexname='liveops_sessions_one_successor_per_session_uidx'),
  'Each LiveOps session has at most one successor'
);
select extensions.ok(
  to_regprocedure('public.start_next_liveops_lobby_session(uuid,jsonb)') is not null,
  'A public RPC advances the Lobby to the next Match'
);
select extensions.ok(
  to_regprocedure('app_private.start_next_liveops_lobby_session(uuid,jsonb)') is not null,
  'The advancement transaction lives in the private schema'
);
select extensions.ok(
  has_function_privilege('authenticated','public.start_next_liveops_lobby_session(uuid,jsonb)','EXECUTE'),
  'Authenticated operators can invoke advancement subject to Match permission'
);
select extensions.ok(
  not has_function_privilege('anon','public.start_next_liveops_lobby_session(uuid,jsonb)','EXECUTE'),
  'Anonymous users cannot advance Lobby sessions'
);
select extensions.ok(
  (select prosecdef from pg_proc
   where oid='app_private.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure),
  'The internal advancement RPC is SECURITY DEFINER and validates the operator'
);
select extensions.ok(
  not (select prosecdef from pg_proc
   where oid='public.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure),
  'The exposed advancement wrapper remains SECURITY INVOKER'
);
select extensions.ok(
  position('v_previous.state <> ''paused''' in pg_get_functiondef('app_private.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure))>0,
  'The current LiveOps session must be paused before advancing'
);
select extensions.ok(
  position('liveops_reviewed_candidates' in pg_get_functiondef('app_private.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure))>0,
  'All official result rows for the current Match must be submitted before advancing'
);
select extensions.ok(
  position('lm.sequence_no > v_previous_sequence' in pg_get_functiondef('app_private.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure))>0,
  'The successor must be later in the same Lobby sequence'
);
select extensions.ok(
  position('previous_session_id=v_previous.id' in pg_get_functiondef('app_private.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure))>0
  AND position('already_advanced' in pg_get_functiondef('app_private.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure))>0,
  'A repeated Next Match request returns the same successor session'
);
select extensions.ok(
  position('state=''stopped''' in pg_get_functiondef('app_private.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure))>0,
  'Advancement closes the previous paused session'
);
select extensions.ok(
  position('NEW.previous_session_id IS DISTINCT FROM OLD.previous_session_id'
    in pg_get_functiondef('app_private.guard_liveops_session_scope()'::regprocedure))>0,
  'A session predecessor link is immutable'
);
select extensions.ok(
  position('lm.lobby_id=v_lobby.id AND lm.match_id=v_session.match_id'
    in pg_get_functiondef('app_private.start_liveops_lobby_session(uuid,jsonb)'::regprocedure))>0,
  'Resuming an active Lobby session returns its actual Match sequence, not sequence one'
);
select extensions.ok(
  position('NOT EXISTS (' in pg_get_functiondef('app_private.start_liveops_lobby_session(uuid,jsonb)'::regprocedure))>0
  AND position('public.match_results' in pg_get_functiondef('app_private.start_liveops_lobby_session(uuid,jsonb)'::regprocedure))>0,
  'Lobby recovery skips Matches that already have official result rows'
);

select * from extensions.finish();
rollback;
