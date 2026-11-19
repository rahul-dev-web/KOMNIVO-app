begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(40);
select extensions.is((select count(*)::int from public.community_role_presets),4,'four built-in community presets exist');
select extensions.is((select assignable from public.community_role_presets where preset_key='owner'),false,'Owner preset is non-delegable');
select extensions.is((select assignable from public.community_role_presets where preset_key='admin'),true,'Admin preset is assignable under hierarchy guard');
select extensions.ok(not ((select permissions from public.community_role_presets where preset_key='admin') ? 'community.manage_settings'),'Admin preset cannot change owner-only community settings');
select extensions.ok(not ((select permissions from public.community_role_presets where preset_key='admin') ? 'community.manage_permissions'),'Admin preset cannot delegate permission grants');
select extensions.ok(exists(select 1 from pg_trigger where tgname='community_role_preset_assignment_guard' and not tgisinternal),'Owner preset assignment is guarded in the database');
select extensions.is((select count(*)::int from public.community_role_presets where preset_key in ('admin','moderator','organiser')),3,'Admin Moderator Organiser are separate presets');
select extensions.ok(exists(select 1 from information_schema.columns where table_schema='public' and table_name='community_roles' and column_name='archived_at'),'custom roles support archival');
select extensions.ok(to_regclass('public.community_role_history') is not null,'role assignment history table exists');
select extensions.ok(to_regclass('public.event_staff_role_permissions') is not null,'specialist event staff permission catalog exists');
select extensions.ok(to_regclass('public.my_competition_trust_states') is not null,'trusted player state view exists');
select extensions.ok(to_regprocedure('public.preview_community_role_permissions(uuid,uuid,uuid,uuid)') is not null,'permission preview RPC exists');
select extensions.ok(to_regprocedure('public.archive_community_role(uuid)') is not null,'role archive RPC exists');
select extensions.ok(to_regprocedure('public.event_staff_effective_permissions(uuid,uuid)') is not null,'event staff effective permission RPC exists');
select extensions.ok(exists(select 1 from public.event_staff_role_permissions where role_key='caster' and permission_key='match.view'),'Caster can view assigned match context');
select extensions.ok(not exists(select 1 from public.event_staff_role_permissions where role_key='caster' and permission_key in ('match.results.review','match.disputes.review','match.credentials.read','event.staff.assign')),'Caster cannot approve results, review disputes, read credentials or assign staff');
select extensions.ok(not exists(select 1 from public.event_staff_role_permissions where role_key='match_operator' and permission_key in ('event.staff.assign','event.manage','event.results.review','community.manage_roles','team.manage')),'Match Operator has no event-wide, community or team admin grant');

select extensions.ok(exists(select 1 from pg_trigger where tgname='community_roles_preset_seed' and not tgisinternal),'New communities automatically receive the four role presets');
select extensions.is((select count(*)::int from public.communities c where (select count(distinct cr.preset_key)::int from public.community_roles cr where cr.community_id=c.id and cr.archived_at is null and cr.preset_key in ('owner','admin','moderator','organiser')) <> 4),0,'Every existing community has all four active presets');
select extensions.ok(exists(select 1 from pg_trigger where tgname='role_permissions_authority_guard' and not tgisinternal),'Role permission writes are guarded by the database');
select extensions.ok(to_regprocedure('app_private.guard_role_permission_change()') is not null,'Role permission authority guard function exists');
select extensions.ok(position('allow_system_role_seed' in lower(pg_get_functiondef('app_private.guard_custom_role_change()'::regprocedure))) > 0,'System roles can only be provisioned by the trusted seeding path');
select extensions.ok(position('when ''community.manage_settings'' then v_is_owner or v_member_role = ''admin''' in lower(pg_get_functiondef('app_private.resolve_permission(text,text,uuid,uuid,uuid)'::regprocedure))) = 0,'Admin cannot edit owner-only community settings');
select extensions.ok(position('when ''community.manage_permissions'' then v_is_owner or v_member_role = ''admin''' in lower(pg_get_functiondef('app_private.resolve_permission(text,text,uuid,uuid,uuid)'::regprocedure))) = 0,'Admin cannot delegate permission grants');
select extensions.ok(position('when ''community.audit.read'' then v_is_owner or v_member_role = ''admin''' in lower(pg_get_functiondef('app_private.resolve_permission(text,text,uuid,uuid,uuid)'::regprocedure))) = 0,'Admin cannot read owner-only audit history');
select extensions.ok(position('when ''admin'' then 200' in lower(pg_get_functiondef('app_private.community_authority_rank(uuid)'::regprocedure))) > 0 and position('when ''moderator'' then 100' in lower(pg_get_functiondef('app_private.community_authority_rank(uuid)'::regprocedure))) > 0 and position('when ''organiser'' then 90' in lower(pg_get_functiondef('app_private.community_authority_rank(uuid)'::regprocedure))) > 0,'Built-in roles use a strict and ordered authority hierarchy');
select extensions.ok(exists(select 1 from pg_trigger where tgname='game_accounts_trust_state_insert_guard' and not tgisinternal),'Game account trust fields are guarded on insert');
select extensions.ok(position('linked_unverified' in lower(pg_get_functiondef('app_private.guard_game_account_trust_state_insert()'::regprocedure))) > 0,'New client-linked game accounts are forced to begin unverified');
select extensions.ok(position('m.event_id = er.event_id' in lower(pg_get_viewdef('public.my_competition_trust_states'::regclass,true))) > 0,'Checked-in trust status is joined to the registration event, not only the user');
select extensions.ok((select reloptions @> array['security_invoker=true'] from pg_class where oid='public.my_competition_trust_states'::regclass),'Player trust-state view respects caller RLS');
select extensions.ok(position('p_role_id is null' in lower(pg_get_functiondef('public.preview_community_role_permissions(uuid,uuid,uuid,uuid)'::regprocedure))) > 0,'Permission preview supports effective member permissions without selecting a role');
select extensions.ok(has_table_privilege('authenticated','public.event_staff_role_permissions','select') and (select relrowsecurity from pg_class where oid='public.event_staff_role_permissions'::regclass),'Authenticated users can read the RLS-protected event staff permission catalogue');
select extensions.is((select count(distinct role_key)::int from public.event_staff_role_permissions where role_key in ('competition_manager','tournament_director','match_operator','referee','result_reviewer','dispute_reviewer','caster','support_staff')),8,'All required esports staff roles have explicit permission catalog entries');
select extensions.ok(exists(select 1 from pg_constraint where conrelid='public.team_members'::regclass and conname='team_members_role_check' and position('spectator' in lower(pg_get_constraintdef(oid))) = 0 and position('substitute' in lower(pg_get_constraintdef(oid))) > 0),'Team membership states stay separate from event Spectator participation');
select extensions.ok(exists(select 1 from information_schema.columns where table_schema='public' and table_name='my_competition_trust_states' and column_name='is_verified_player') and exists(select 1 from information_schema.columns where table_schema='public' and table_name='my_competition_trust_states' and column_name='is_registered_player') and exists(select 1 from information_schema.columns where table_schema='public' and table_name='my_competition_trust_states' and column_name='is_checked_in_player'),'Verified, Registered and Checked-in states are distinct backend-derived fields');


select extensions.ok(position('''caster'',' in lower(pg_get_functiondef('app_private.resolve_permission(text,text,uuid,uuid,uuid)'::regprocedure))) > 0 and position('''streamer''' in lower(pg_get_functiondef('app_private.resolve_permission(text,text,uuid,uuid,uuid)'::regprocedure))) > 0,'Caster and Streamer can view their assigned group context');
select extensions.ok(exists(select 1 from public.event_staff_role_permissions where role_key='referee' and permission_key='event.results.review') and exists(select 1 from public.event_staff_role_permissions where role_key='referee' and permission_key='match.results.review'),'Referee catalogue documents both event-level and match-level review scopes');
select extensions.ok(exists(select 1 from public.event_staff_role_permissions where role_key='result_reviewer' and permission_key='event.results.review') and exists(select 1 from public.event_staff_role_permissions where role_key='result_reviewer' and permission_key='match.results.review'),'Result Reviewer catalogue matches both event and match review actions');
select extensions.ok(exists(select 1 from public.event_staff_role_permissions where role_key='dispute_reviewer' and permission_key='event.disputes.review') and exists(select 1 from public.event_staff_role_permissions where role_key='dispute_reviewer' and permission_key='match.disputes.review'),'Dispute Reviewer catalogue matches event and match dispute review');

select extensions.ok(position('community.manage_roles' in lower(pg_get_functiondef('public.preview_community_role_permissions(uuid,uuid,uuid,uuid)'::regprocedure))) > 0,'Delegated role managers can preview another member without receiving permission-delegation authority');

select * from extensions.finish();
rollback;