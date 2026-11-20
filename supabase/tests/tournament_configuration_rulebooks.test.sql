-- Structured tournament configuration and official rulebook integration contracts.
-- Run with: supabase test db

begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(26);

select extensions.has_column('public','events','registration_opens_at',
  'Events persist the registration opening time separately from the closing time');
select extensions.has_column('public','events','event_config',
  'Events persist stage, roadmap, prize and entry configuration');
select extensions.has_column('public','events','banner_path',
  'Events persist the private tournament banner object path');

select extensions.has_table('public','tournament_rulebooks',
  'Game- and mode-scoped official rulebook catalog exists');
select extensions.has_table('public','tournament_proposals',
  'Structured tournament proposals are persisted separately from LLM runs');
select extensions.has_table('public','tournament_config_versions',
  'Tournament configuration history is append-only by version');

select extensions.ok(
  exists(select 1 from public.games where code='bgmi' and is_active),
  'BGMI is present as an active game record'
);
select extensions.ok(
  exists(
    select 1 from public.tournament_rulebooks rb
    join public.games g on g.id=rb.game_id
    where g.code='bgmi'
      and rb.scope='competition_specific'
      and rb.mode_scope @> ARRAY['squad']::text[]
      and rb.source_url='https://esports.battlegroundsmobileindia.com/bmic_rulebook.pdf'
      and rb.is_active
  ),
  'KRAFTON BMIC 2025 rulebook is scoped to its specific competition and squad mode'
);
select extensions.is(
  (select scoring_config->'placement_points'->>'1'
   from public.tournament_rulebooks rb join public.games g on g.id=rb.game_id
   where g.code='bgmi' and rb.title like 'BATTLEGROUNDS MOBILE INDIA International Cup 2025%'),
  '10',
  'BMIC 2025 scoring source records first-place points'
);
select extensions.is(
  (select scoring_config->>'finish_point'
   from public.tournament_rulebooks rb join public.games g on g.id=rb.game_id
   where g.code='bgmi' and rb.title like 'BATTLEGROUNDS MOBILE INDIA International Cup 2025%'),
  '1',
  'BMIC 2025 scoring source records one point per finish'
);

select extensions.ok(
  to_regprocedure('public.resolve_tournament_proposal(uuid,uuid,text)') is not null,
  'Atomic proposal approval RPC exists'
);
select extensions.ok(
  to_regprocedure('public.update_tournament_draft(uuid,uuid,jsonb)') is not null,
  'Draft edit RPC exists'
);
select extensions.ok(
  not has_function_privilege('authenticated','public.resolve_tournament_proposal(uuid,uuid,text)','EXECUTE'),
  'Authenticated clients cannot call the service-role-only approval RPC directly'
);
select extensions.ok(
  has_function_privilege('service_role','public.resolve_tournament_proposal(uuid,uuid,text)','EXECUTE'),
  'The authenticated server workflow can resolve a proposal through the service-role RPC'
);

select extensions.ok(
  exists(select 1 from storage.buckets where id='tournament-banners' and public=false),
  'Tournament banners use a private storage bucket'
);
select extensions.ok(
  exists(select 1 from storage.buckets where id='tournament-rulebooks' and public=false),
  'Official rulebook copies use a private storage bucket'
);
select extensions.ok(
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects'
    and policyname='tournament_banners_upload_manager' and cmd='INSERT'),
  'Tournament banner uploads are gated by community organiser access'
);
select extensions.ok(
  (select relrowsecurity from pg_class where oid='public.tournament_rulebooks'::regclass),
  'Rulebook metadata has RLS enabled'
);
select extensions.ok(
  (select relrowsecurity from pg_class where oid='public.tournament_proposals'::regclass),
  'Tournament proposals have RLS enabled'
);
select extensions.ok(
  (select relrowsecurity from pg_class where oid='public.tournament_config_versions'::regclass),
  'Tournament configuration history has RLS enabled'
);

select extensions.ok(
  exists(select 1 from public.games where code='free_fire_india' and name='Free Fire India' and is_active),
  'Free Fire India is a distinct active game record, separate from Free Fire MAX'
);
select extensions.ok(
  exists(
    select 1 from public.tournament_rulebooks rb
    join public.games g on g.id=rb.game_id
    where g.code='free_fire_india'
      and rb.title='Free Fire India Rulebook'
      and rb.scope='general'
      and rb.mode_scope @> ARRAY['squad']::text[]
      and not (rb.mode_scope @> ARRAY['duo']::text[])
      and rb.is_active
  ),
  'Cleaned Free Fire India rulebook is available only for Squad baseline'
);
select extensions.is(
  (select scoring_config->>'kill_point'
   from public.tournament_rulebooks rb join public.games g on g.id=rb.game_id
   where g.code='free_fire_india' and rb.title='Free Fire India Rulebook'),
  '1',
  'Free Fire India curated baseline awards one point per kill'
);
select extensions.is(
  (select scoring_config->'placement_points'->>'1'
   from public.tournament_rulebooks rb join public.games g on g.id=rb.game_id
   where g.code='free_fire_india' and rb.title='Free Fire India Rulebook'),
  '12',
  'Free Fire India curated baseline records first-place points as 12'
);
select extensions.ok(
  (select rules_config->>'not_garena_issued' = 'true'
   from public.tournament_rulebooks rb join public.games g on g.id=rb.game_id
   where g.code='free_fire_india' and rb.title='Free Fire India Rulebook'),
  'Free Fire India document is explicitly labelled as a KOMNIVO-curated baseline, not Garena-issued'
);
select extensions.ok(
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects'
    and policyname='tournament_banners_upload_manager'
    and with_check like '%can_access_ai_scope%'),
  'Tournament banner uploads accept the scoped organiser permission check'
);

select * from finish();
rollback;
