-- Batch 2 behaviour tests: built-in presets, custom roles, assignments, hierarchy and history.
-- Run with: supabase test db

begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(33);

insert into auth.users(id,aud,role,email,email_confirmed_at,raw_user_meta_data)
values
 ('61000000-0000-4000-8000-000000000001','authenticated','authenticated','b2-role-owner@example.test',now(),'{"full_name":"B2 Role Owner"}'),
 ('61000000-0000-4000-8000-000000000002','authenticated','authenticated','b2-role-admin@example.test',now(),'{"full_name":"B2 Role Admin"}'),
 ('61000000-0000-4000-8000-000000000003','authenticated','authenticated','b2-role-member@example.test',now(),'{"full_name":"B2 Role Member"}')
on conflict (id) do nothing;

update public.profiles set username='b2_role_owner' where id='61000000-0000-4000-8000-000000000001';
update public.profiles set username='b2_role_admin' where id='61000000-0000-4000-8000-000000000002';
update public.profiles set username='b2_role_member' where id='61000000-0000-4000-8000-000000000003';

insert into public.communities(id,name,slug,owner_user_id,visibility)
values ('62000000-0000-4000-8000-000000000001','Batch Two Role Behaviour','b2-role-behaviour-test',
        '61000000-0000-4000-8000-000000000001','private');

insert into public.community_members(community_id,user_id,role)
values
 ('62000000-0000-4000-8000-000000000001','61000000-0000-4000-8000-000000000002','admin'),
 ('62000000-0000-4000-8000-000000000001','61000000-0000-4000-8000-000000000003','member')
on conflict (community_id,user_id) do update set role=excluded.role;

insert into public.channels(id,community_id,name,description,kind,is_private,created_by)
values ('62000000-0000-4000-8000-000000000002','62000000-0000-4000-8000-000000000001',
        'b2-private-role-preview','Private role preview fixture','text',true,
        '61000000-0000-4000-8000-000000000001');

insert into public.games(id,code,name,platform,is_active)
values ('63000000-0000-4000-8000-000000000001','b2-role-trust-test','Batch 2 Trust State Test','mobile',true)
on conflict (id) do nothing;

-- A fresh community must receive every built-in preset through the insert trigger.
select extensions.is(
  (select count(distinct preset_key)::int from public.community_roles
   where community_id='62000000-0000-4000-8000-000000000001'
     and archived_at is null
     and preset_key in ('owner','admin','moderator','organiser')),
  4,
  'New community is provisioned with all four built-in presets'
);
select extensions.is(
  (select assignable from public.community_role_presets where preset_key='owner'),
  false,
  'Owner preset is non-delegable'
);

set local role authenticated;
set local request.jwt.claim.sub = '61000000-0000-4000-8000-000000000001';

select extensions.is(
  (select allowed from public.preview_community_role_permissions(
    '62000000-0000-4000-8000-000000000001',
    (select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and preset_key='owner'),
    null,null
  ) where permission_key='community.manage_settings'),
  true,
  'Owner preset preview includes owner-only settings'
);
select extensions.is(
  (select allowed from public.preview_community_role_permissions(
    '62000000-0000-4000-8000-000000000001',
    (select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and preset_key='admin'),
    null,null
  ) where permission_key='community.manage_roles'),
  true,
  'Admin preset preview includes role management'
);
select extensions.is(
  (select allowed from public.preview_community_role_permissions(
    '62000000-0000-4000-8000-000000000001',
    (select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and preset_key='admin'),
    null,null
  ) where permission_key='community.manage_settings'),
  false,
  'Admin preset preview excludes owner-only settings'
);
select extensions.is(
  (select allowed from public.preview_community_role_permissions(
    '62000000-0000-4000-8000-000000000001',
    (select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and preset_key='moderator'),
    null,null
  ) where permission_key='community.manage_members'),
  true,
  'Moderator preset preview includes member moderation'
);
select extensions.is(
  (select allowed from public.preview_community_role_permissions(
    '62000000-0000-4000-8000-000000000001',
    (select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and preset_key='organiser'),
    null,null
  ) where permission_key='community.manage_structure'),
  true,
  'Organiser preset preview includes community structure management'
);
select extensions.is(
  (select allowed from public.preview_community_role_permissions(
    '62000000-0000-4000-8000-000000000001',
    (select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and preset_key='admin'),
    null,'62000000-0000-4000-8000-000000000002'
  ) where permission_key='channel.view'),
  true,
  'Admin preset preview includes private-channel visibility'
);

-- Create roles through the same atomic RPC used by Flutter.
select public.save_community_role(
 '62000000-0000-4000-8000-000000000001',null,
 'QA Allow','Allows invite management','#4A90E2',120,
 '{"community.manage_invites":true}'::jsonb
);
select public.save_community_role(
 '62000000-0000-4000-8000-000000000001',null,
 'QA Deny','Explicitly denies invite management','#D94F70',110,
 '{"community.manage_invites":false}'::jsonb
);
select public.save_community_role(
 '62000000-0000-4000-8000-000000000001',null,
 'QA Higher','Above delegated Admin hierarchy','#8A6BE8',250,
 '{}'::jsonb
);
select public.save_community_role(
 '62000000-0000-4000-8000-000000000001',null,
 'QA Delegation','Editable by delegated Admin','#33A7A0',80,
 '{"community.manage_invites":true}'::jsonb
);

select extensions.ok(
  exists(select 1 from public.community_roles
         where community_id='62000000-0000-4000-8000-000000000001'
           and name='QA Allow' and description='Allows invite management' and colour='#4A90E2'),
  'Custom role create persists name, description and colour'
);

select public.replace_community_member_roles(
 '62000000-0000-4000-8000-000000000001',
 '61000000-0000-4000-8000-000000000003',
 ARRAY[
  (select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and name='QA Allow'),
  (select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and name='QA Deny')
 ]::uuid[]
);
select extensions.is(
  (select count(*)::int from public.community_member_roles cmr
   join public.community_roles cr on cr.id=cmr.role_id
   where cmr.community_id='62000000-0000-4000-8000-000000000001'
     and cmr.user_id='61000000-0000-4000-8000-000000000003'
     and cr.name in ('QA Allow','QA Deny')),
  2,
  'One member can hold multiple Community roles'
);
select extensions.is(
  (select allowed from public.preview_community_role_permissions(
    '62000000-0000-4000-8000-000000000001',null,
    '61000000-0000-4000-8000-000000000003',null
  ) where permission_key='community.manage_invites'),
  false,
  'Explicit Deny wins over an Allow granted by another assigned role'
);
select extensions.is(
  (select source from public.preview_community_role_permissions(
    '62000000-0000-4000-8000-000000000001',null,
    '61000000-0000-4000-8000-000000000003',null
  ) where permission_key='community.manage_invites'),
  'explicit_deny',
  'Permission preview identifies the explicit Deny source'
);
select extensions.throws_ok(
 $$select public.replace_community_member_roles(
   '62000000-0000-4000-8000-000000000001',
   '61000000-0000-4000-8000-000000000003',
   ARRAY[(select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and preset_key='owner')]::uuid[]
 )$$,
 'P0001',
 'Every selected role must be active, assignable and belong to this community',
 'Owner preset cannot be assigned to a member'
);

select extensions.ok(
  exists(select 1 from public.community_role_history
         where community_id='62000000-0000-4000-8000-000000000001'
           and subject_user_id='61000000-0000-4000-8000-000000000003'
           and actor_user_id='61000000-0000-4000-8000-000000000001'
           and action='community_member_roles_insert'),
  'Role assignment history captures actor and target member'
);
select public.save_community_role(
 '62000000-0000-4000-8000-000000000001',
 (select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and name='QA Delegation'),
 'QA Delegation','Updated description','#33A7A0',80,
 '{"community.manage_invites":true}'::jsonb
);
select extensions.ok(
  exists(select 1 from public.community_role_history
         where community_id='62000000-0000-4000-8000-000000000001'
           and role_id=(select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and name='QA Delegation')
           and action='community_roles_update'
           and before_state is not null and after_state is not null),
  'Role edit history stores before and after values'
);
reset role;

-- The delegated Admin can manage only roles below position 200 and cannot grant owner-only actions.
set local role authenticated;
set local request.jwt.claim.sub = '61000000-0000-4000-8000-000000000002';

select extensions.throws_ok(
 $$select public.replace_community_member_roles(
   '62000000-0000-4000-8000-000000000001',
   '61000000-0000-4000-8000-000000000003',
   ARRAY[(select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and name='QA Higher')]::uuid[]
 )$$,
 'P0001',
 'You cannot assign a role at or above your hierarchy level',
 'Admin cannot assign a higher-authority custom role'
);
select extensions.throws_ok(
 $$select public.save_community_role(
   '62000000-0000-4000-8000-000000000001',
   (select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and name='QA Higher'),
   'QA Higher','At Admin rank','#8A6BE8',200,'{}'::jsonb
 )$$,
 'P0001',
 'You cannot create or move a role at or above your own hierarchy level',
 'Admin cannot move a role to equal authority'
);
select extensions.throws_ok(
 $$select public.save_community_role(
   '62000000-0000-4000-8000-000000000001',
   (select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and name='QA Delegation'),
   'QA Delegation','Invalid escalation','#33A7A0',80,
   '{"community.manage_settings":true}'::jsonb
 )$$,
 'P0001',
 'You cannot grant a permission you do not hold: community.manage_settings',
 'Admin cannot grant owner-only settings permission'
);
select public.save_community_role(
 '62000000-0000-4000-8000-000000000001',
 (select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and name='QA Delegation'),
 'QA Delegation','Edited by delegated Admin','#33A7A0',80,
 '{"community.manage_invites":true}'::jsonb
);
select extensions.ok(
  exists(select 1 from public.community_roles
         where community_id='62000000-0000-4000-8000-000000000001'
           and name='QA Delegation' and description='Edited by delegated Admin'),
  'Admin can edit a lower role and retain only permissions they hold'
);
reset role;

set local role authenticated;
set local request.jwt.claim.sub = '61000000-0000-4000-8000-000000000001';
select public.archive_community_role(
 (select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and name='QA Deny')
);
select extensions.ok(
  (select archived_at is not null from public.community_roles
   where community_id='62000000-0000-4000-8000-000000000001' and name='QA Deny'),
  'Archived custom role is marked inactive'
);
select extensions.is(
  (select count(*)::int from public.community_member_roles cmr
   join public.community_roles cr on cr.id=cmr.role_id
   where cmr.community_id='62000000-0000-4000-8000-000000000001'
     and cmr.user_id='61000000-0000-4000-8000-000000000003'
     and cr.name='QA Deny'),
  0,
  'Archiving a role removes its active member assignments'
);
select extensions.ok(
  exists(select 1 from public.community_role_history
         where community_id='62000000-0000-4000-8000-000000000001'
           and role_id=(select id from public.community_roles where community_id='62000000-0000-4000-8000-000000000001' and name='QA Deny')
           and action='community_roles_update'
           and before_state is not null and after_state is not null),
  'Role archival is recorded in the append-only history'
);
reset role;

select extensions.ok(
  exists(select 1 from pg_trigger
         where tgname='community_role_history_no_mutation' and not tgisinternal),
  'Role history table is protected against UPDATE and DELETE'
);

select extensions.ok(
  exists(select 1 from pg_constraint
         where conrelid='public.community_members'::regclass
           and conname='community_members_role_check'
           and position('spectator' in lower(pg_get_constraintdef(oid)))=0),
  'Spectator is not a Community membership role'
);


-- Client-created game account links cannot claim trust or verification state.
set local role authenticated;
set local request.jwt.claim.sub = '61000000-0000-4000-8000-000000000003';
insert into public.game_accounts(
 id,user_id,game_id,uid,provider,ownership_status,verification_attempts,
 verification_locked_at,verification_last_attempt_at
) values (
 '64000000-0000-4000-8000-000000000001',
 '61000000-0000-4000-8000-000000000003',
 '63000000-0000-4000-8000-000000000001',
 'B2-TRUST-UID','manual','verified',2,now(),now()
);
select extensions.is(
 (select ownership_status from public.game_accounts where id='64000000-0000-4000-8000-000000000001'),
 'linked_unverified',
 'Client-created game account always begins linked and unverified'
);
select extensions.is(
 (select verification_attempts from public.game_accounts where id='64000000-0000-4000-8000-000000000001'),
 0,
 'Client cannot seed verification attempts when linking a game account'
);
select extensions.ok(
 (select verification_locked_at is null and verification_last_attempt_at is null
  from public.game_accounts where id='64000000-0000-4000-8000-000000000001'),
 'Client cannot seed verification lock timestamps'
);
select extensions.throws_ok(
 $update public.game_accounts set ownership_status='verified'
   where id='64000000-0000-4000-8000-000000000001'$,
 'P0001',
 'Game account ownership and verification state can only be changed by the verification workflow',
 'Client cannot promote its linked game account to Verified Player'
);
select extensions.is(
 (select is_verified_player from public.my_competition_trust_states
  where game_account_id='64000000-0000-4000-8000-000000000001'),
 false,
 'Verified Player is derived as false for a client-linked unverified account'
);
reset role;

-- The other trust states are derived from approved registration and an actual ready check-in.
insert into public.events(
 id,game_id,organizer_id,name,description,format,status,starts_at,capacity,rules_json,scoring_config
) values (
 '65000000-0000-4000-8000-000000000001',
 '63000000-0000-4000-8000-000000000001',
 '61000000-0000-4000-8000-000000000001',
 'Batch 2 Trust Event','Trust-state fixture','squad','published',now(),8,'{}'::jsonb,
 '{"kill_point":1,"placement_points":{}}'::jsonb
);
insert into public.event_registrations(event_id,captain_user_id,status)
values ('65000000-0000-4000-8000-000000000001','61000000-0000-4000-8000-000000000003','approved');
insert into public.registration_players(registration_id,user_id,game_account_id)
select er.id,'61000000-0000-4000-8000-000000000003','64000000-0000-4000-8000-000000000001'
from public.event_registrations er where er.event_id='65000000-0000-4000-8000-000000000001';
insert into public.matches(id,event_id,round_number,match_number,status)
values ('66000000-0000-4000-8000-000000000001','65000000-0000-4000-8000-000000000001',1,1,'scheduled');
insert into public.match_checkins(match_id,user_id,status)
values ('66000000-0000-4000-8000-000000000001','61000000-0000-4000-8000-000000000003','ready');

set local role authenticated;
set local request.jwt.claim.sub = '61000000-0000-4000-8000-000000000003';
select extensions.is(
 (select is_registered_player from public.my_competition_trust_states
  where game_account_id='64000000-0000-4000-8000-000000000001'
    and event_id='65000000-0000-4000-8000-000000000001'),
 true,
 'Registered Player is derived from an approved event registration'
);
select extensions.is(
 (select is_checked_in_player from public.my_competition_trust_states
  where game_account_id='64000000-0000-4000-8000-000000000001'
    and event_id='65000000-0000-4000-8000-000000000001'
    and match_id='66000000-0000-4000-8000-000000000001'),
 true,
 'Checked-in Player is derived from a ready check-in for that registered event'
);
reset role;

-- Table SELECT grant does not expose role history to Admin: the RLS policy remains authoritative.
set local role authenticated;
set local request.jwt.claim.sub = '61000000-0000-4000-8000-000000000002';
select extensions.is(
 (select count(*)::int from public.community_role_history
  where community_id='62000000-0000-4000-8000-000000000001'),
 0,
 'Admin cannot read Owner-only role history despite authenticated table SELECT grant'
);
reset role;

select * from extensions.finish();
rollback;
