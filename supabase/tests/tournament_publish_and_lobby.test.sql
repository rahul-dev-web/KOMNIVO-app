-- Tournament publishing and Lobby/Match identity contracts.
-- Run with: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(18);

select extensions.has_table('public','event_publications',
  'An audit-safe record is maintained for each published tournament');
select extensions.has_table('public','event_lobbies',
  'A generated Lobby ID has its own entity');
select extensions.has_table('public','event_lobby_matches',
  'A lobby can contain multiple ordered Match IDs');
select extensions.has_column('public','liveops_sessions','lobby_id',
  'LiveOps sessions bind a Lobby ID independently of their current Match ID');

select extensions.ok(
  to_regprocedure('public.publish_tournament_proposal(uuid,uuid)') is not null,
  'An explicit server-only publish RPC exists'
);
select extensions.ok(
  to_regprocedure('public.create_event_lobby(uuid,uuid[],text)') is not null,
  'Organisers can create a Lobby ID for an ordered match set'
);
select extensions.ok(
  to_regprocedure('public.start_liveops_lobby_session(uuid,jsonb)') is not null,
  'LiveOps can start by Lobby ID and bind a Match ID'
);

select extensions.ok(
  not has_function_privilege('authenticated','public.publish_tournament_proposal(uuid,uuid)','EXECUTE'),
  'Authenticated clients cannot bypass the Edge Function and publish as service role'
);
select extensions.ok(
  has_function_privilege('service_role','public.publish_tournament_proposal(uuid,uuid)','EXECUTE'),
  'The authenticated server workflow can execute the publication transaction'
);
select extensions.ok(
  has_function_privilege('authenticated','public.create_event_lobby(uuid,uuid[],text)','EXECUTE'),
  'Signed-in organisers can call the permission-checked lobby creation RPC'
);
select extensions.ok(
  has_function_privilege('authenticated','public.start_liveops_lobby_session(uuid,jsonb)','EXECUTE'),
  'Signed-in operators can start LiveOps through the permission-checked lobby RPC'
);

select extensions.ok(
  (select relrowsecurity from pg_class where oid='public.event_publications'::regclass),
  'Publication records have RLS enabled'
);
select extensions.ok(
  (select relrowsecurity from pg_class where oid='public.event_lobbies'::regclass),
  'Lobby records have RLS enabled'
);
select extensions.ok(
  (select relrowsecurity from pg_class where oid='public.event_lobby_matches'::regclass),
  'Lobby-to-match mapping has RLS enabled'
);
select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='event_lobby_matches' and indexdef ilike '%UNIQUE INDEX%match_id%'),
  'An individual Match ID cannot be assigned to two different lobbies'
);
select extensions.ok(
  exists(select 1 from pg_policies where schemaname='public'
    and tablename='channel_categories' and policyname='channel_categories_read_member'
    and qual ilike '%event.view%'),
  'Published tournament categories are visible through the event view permission'
);
select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='liveops_sessions' and indexname='liveops_sessions_lobby_idx'),
  'Lobby-bound LiveOps sessions have an index'
);
select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='event_publications' and indexname='event_publications_category_idx'),
  'Published category lookup is indexed'
);

select * from extensions.finish();
rollback;
