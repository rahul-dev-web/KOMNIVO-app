-- Tournament publishing and Lobby/Match identity contracts.
-- Run with: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(27);

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
  position('event.manage' in pg_get_functiondef('app_private.guard_batch3_channel_message()'::regprocedure)) > 0,
  'Root tournament notice-board publishing is enforced by the server event.manage permission'
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


select extensions.ok(
  position('resolve_permission(''community.view'',''community'',v_event_community_id' in
    pg_get_functiondef('app_private.resolve_permission(text,text,uuid,uuid,uuid)'::regprocedure)) > 0,
  'Published event view requires the parent community visibility policy'
);
select extensions.ok(
  position('elsif p_scope_type = ''liveops_session'' then' in
    pg_get_functiondef('app_private.resolve_permission(text,text,uuid,uuid,uuid)'::regprocedure)) > 0
  and position('elsif p_scope_type = ''match'' then' in
    pg_get_functiondef('app_private.resolve_permission(text,text,uuid,uuid,uuid)'::regprocedure)) > 0
  and position('elsif p_scope_type = ''group'' then' in
    pg_get_functiondef('app_private.resolve_permission(text,text,uuid,uuid,uuid)'::regprocedure)) > 0,
  'The full match, group and LiveOps permission resolver remains intact'
);
select extensions.ok(
  position('(1,''info''' in pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0
  and position('(2,''updates''' in pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0
  and position('(3,''roadmap''' in pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0
  and position('(4,''schedule''' in pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0
  and position('(5,''registration''' in pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0
  and position('(6,''registration-confirmation''' in pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0
  and position('(7,''test-registration''' in pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0
  and position('(8,''help-desk''' in pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0
  and position('(9,''help-desk-voice''' in pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0
  and position('(10,''results''' in pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0
  and position('(11,''staff''' in pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0,
  'Publication provisions all eleven required tournament channels in their specified order'
);
select extensions.ok(
  position('''tags''' in lower(pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure))) = 0,
  'No Tags channel is provisioned'
);
select extensions.ok(
  position('(11,''staff'',''Private tournament staff coordination.'',''text'',true,false)' in
    pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0
  and position('a.scope_type = ''event''' in
    pg_get_functiondef('app_private.can_access_event_channel_scope(uuid,uuid,uuid,uuid,uuid)'::regprocedure)) > 0,
  'Staff channel is private and visibility is restricted to event-scoped staff authority'
);
select extensions.ok(
  position('registration_opened'',false' in
    pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0
  and position('UPDATE public.events SET status=''published''' in
    pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0,
  'Publishing does not open registration'
);
select extensions.ok(
  position('app_private.resolve_permission(''event.manage'',''event''' in
    pg_get_functiondef('app_private.guard_batch3_channel_message()'::regprocedure)) > 0,
  'Root event announcement channels remain restricted to event organisers for publishing'
);

select * from extensions.finish();
rollback;
