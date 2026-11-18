-- Batch 1 cross-scope RLS regression test.
-- Run with: supabase test db
-- All fixtures are transaction-scoped and rolled back at the end.

begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(28);

insert into auth.users(id,aud,role,email,email_confirmed_at,raw_user_meta_data)
values
 ('10000000-0000-4000-8000-000000000001','authenticated','authenticated','b1-owner@example.test',now(),'{"full_name":"B1 Owner"}'),
 ('10000000-0000-4000-8000-000000000002','authenticated','authenticated','b1-team-a@example.test',now(),'{"full_name":"B1 Team A"}'),
 ('10000000-0000-4000-8000-000000000003','authenticated','authenticated','b1-team-b@example.test',now(),'{"full_name":"B1 Team B"}'),
 ('10000000-0000-4000-8000-000000000004','authenticated','authenticated','b1-match-operator@example.test',now(),'{"full_name":"B1 Match Operator"}'),
 ('10000000-0000-4000-8000-000000000005','authenticated','authenticated','b1-public-viewer@example.test',now(),'{"full_name":"B1 Public Viewer"}')
on conflict (id) do nothing;

update public.profiles set username='b1_owner' where id='10000000-0000-4000-8000-000000000001';
update public.profiles set username='b1_team_a' where id='10000000-0000-4000-8000-000000000002';
update public.profiles set username='b1_team_b' where id='10000000-0000-4000-8000-000000000003';
update public.profiles set username='b1_match_operator' where id='10000000-0000-4000-8000-000000000004';
update public.profiles set username='b1_public_viewer' where id='10000000-0000-4000-8000-000000000005';

insert into public.games(id,code,name,platform,is_active)
values ('30000000-0000-4000-8000-000000000001','b1-isolation-test','Batch One Isolation Test','mobile',true)
on conflict (id) do nothing;

insert into public.events(
 id,game_id,organizer_id,name,description,format,status,starts_at,capacity,rules_json,scoring_config
) values (
 '20000000-0000-4000-8000-000000000001',
 '30000000-0000-4000-8000-000000000001',
 '10000000-0000-4000-8000-000000000001',
 'Batch One Scope Test','RLS fixture only','squad','published',now(),2,'{}','{"kill_point":1,"placement_points":{}}'
);

insert into public.event_rounds(
 id,event_id,round_number,name,status,configuration,stage_type,group_size,matches_per_group,advancement_rules,room_release_minutes_before
) values (
 '20000000-0000-4000-8000-000000000002',
 '20000000-0000-4000-8000-000000000001',
 1,'Fixture Stage','live','{}','qualifier',2,1,'{"top_n":1}',10
);

insert into public.event_groups(id,round_id,label,sort_order) values
 ('20000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000002','Fixture Group A',1),
 ('20000000-0000-4000-8000-000000000004','20000000-0000-4000-8000-000000000002','Fixture Group B',2);

insert into public.teams(id,name,tag,game_id,owner_user_id,is_public) values
 ('20000000-0000-4000-8000-000000000005','Fixture Team A','B1A','30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002',false),
 ('20000000-0000-4000-8000-000000000006','Fixture Team B','B1B','30000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000003',false);

insert into public.team_members(team_id,user_id,role) values
 ('20000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000002','captain'),
 ('20000000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000003','captain')
on conflict (team_id,user_id) do nothing;

insert into public.event_group_teams(group_id,team_id,seeded_by) values
 ('20000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001'),
 ('20000000-0000-4000-8000-000000000004','20000000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000001');

insert into public.matches(
 id,event_id,round_number,group_label,match_number,status,stage_id,group_id,group_match_number
) values
 ('20000000-0000-4000-8000-000000000007','20000000-0000-4000-8000-000000000001',1,'Fixture Group A',1,'scheduled','20000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000003',1),
 ('20000000-0000-4000-8000-000000000008','20000000-0000-4000-8000-000000000001',1,'Fixture Group B',2,'scheduled','20000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000004',1);

insert into public.match_participants(match_id,team_id,check_in_status,slot_number) values
 ('20000000-0000-4000-8000-000000000007','20000000-0000-4000-8000-000000000005','ready',1),
 ('20000000-0000-4000-8000-000000000008','20000000-0000-4000-8000-000000000006','ready',1);

insert into public.channels(id,name,kind,is_private,event_id,stage_id,group_id,match_id,created_by) values
 ('20000000-0000-4000-8000-000000000201','Fixture Public Event','text',false,'20000000-0000-4000-8000-000000000001',null,null,null,'10000000-0000-4000-8000-000000000001'),
 ('20000000-0000-4000-8000-000000000202','Fixture Private Staff','text',true,'20000000-0000-4000-8000-000000000001',null,null,null,'10000000-0000-4000-8000-000000000001'),
 ('20000000-0000-4000-8000-000000000203','Fixture Group A','text',false,'20000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000003',null,'10000000-0000-4000-8000-000000000001'),
 ('20000000-0000-4000-8000-000000000204','Fixture Group B','text',false,'20000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000004',null,'10000000-0000-4000-8000-000000000001'),
 ('20000000-0000-4000-8000-000000000205','Fixture Match A','match',true,'20000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000007','10000000-0000-4000-8000-000000000001'),
 ('20000000-0000-4000-8000-000000000206','Fixture Match B','match',true,'20000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000004','20000000-0000-4000-8000-000000000008','10000000-0000-4000-8000-000000000001');

insert into public.room_credentials(id,match_id,room_code,room_password,release_at,created_by)
values ('20000000-0000-4000-8000-000000000301','20000000-0000-4000-8000-000000000007','B1-ROOM','B1-SECRET',now()+interval '1 day','10000000-0000-4000-8000-000000000001');

-- A normal community member receives a base role grant, then category/channel
-- overrides prove inheritance and explicit Deny behaviour independently.
insert into public.communities(id,name,slug,description,visibility,owner_user_id)
values ('40000000-0000-4000-8000-000000000001','Batch One Permissions','batch-one-permissions-test','RLS fixture only','private','10000000-0000-4000-8000-000000000001');

insert into public.community_members(community_id,user_id,role) values
 ('40000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','owner'),
 ('40000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','member')
on conflict (community_id,user_id) do nothing;

insert into public.community_roles(id,community_id,name,description,colour,position,is_system,created_by)
values ('40000000-0000-4000-8000-000000000004','40000000-0000-4000-8000-000000000001',
        'B1 Permission Role','Test fixture role',null,10,false,'10000000-0000-4000-8000-000000000001');

insert into public.community_member_roles(community_id,user_id,role_id,assigned_by)
values ('40000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002',
        '40000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000001');

insert into public.role_permissions(role_id,permission_key,allowed)
values ('40000000-0000-4000-8000-000000000004','channel.manage_messages',true);

insert into public.channel_categories(id,community_id,name,description,position,created_by)
values ('40000000-0000-4000-8000-000000000002','40000000-0000-4000-8000-000000000001',
        'B1 Category','RLS fixture only',1,'10000000-0000-4000-8000-000000000001');

insert into public.channels(id,community_id,category_id,name,description,kind,is_private,created_by)
values ('40000000-0000-4000-8000-000000000003','40000000-0000-4000-8000-000000000001',
        '40000000-0000-4000-8000-000000000002','B1 Channel','RLS fixture only','text',false,
        '10000000-0000-4000-8000-000000000001');

insert into public.category_permission_overrides(community_id,category_id,role_id,permission_key,effect,updated_by)
values ('40000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000002',
        '40000000-0000-4000-8000-000000000004','channel.manage_messages','deny',
        '10000000-0000-4000-8000-000000000001');

-- Cross-scope records for check-in, result, evidence and dispute isolation.
insert into public.match_checkins(match_id,user_id,status)
values ('20000000-0000-4000-8000-000000000008','10000000-0000-4000-8000-000000000003','ready');

insert into public.match_results(id,match_id,team_id,submitted_by,placement,kills,points,status,result_json)
values ('20000000-0000-4000-8000-000000000009','20000000-0000-4000-8000-000000000008',
        '20000000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000003',
        1,3,10,'submitted','{}');

insert into public.result_evidence(id,result_id,uploaded_by,storage_path,content_type,file_size)
values ('20000000-0000-4000-8000-000000000302','20000000-0000-4000-8000-000000000009',
        '10000000-0000-4000-8000-000000000003','fixture/team-b/evidence.png','image/png',123);

insert into public.result_disputes(id,result_id,opened_by,reason,status)
values ('20000000-0000-4000-8000-000000000303','20000000-0000-4000-8000-000000000009',
        '10000000-0000-4000-8000-000000000003','Fixture dispute','open');


-- The event owner uses the authenticated RPC; the operator is deliberately scoped to one match.
set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-4000-8000-000000000001';
select public.assign_scoped_event_staff_by_username(
 '20000000-0000-4000-8000-000000000001','b1_match_operator','match_operator','match',
 null,null,'20000000-0000-4000-8000-000000000007'
);
reset role;

-- Team A can see only its own group's and match's communication and participants.
set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-4000-8000-000000000002';
select extensions.is((select count(*) from public.channels where id='20000000-0000-4000-8000-000000000203'),1::bigint,'team A sees its group channel');
select extensions.is((select count(*) from public.channels where id='20000000-0000-4000-8000-000000000205'),1::bigint,'team A sees its match channel');
select extensions.is((select count(*) from public.channels where id='20000000-0000-4000-8000-000000000204'),0::bigint,'team A cannot see group B channel');
select extensions.is((select count(*) from public.channels where id='20000000-0000-4000-8000-000000000206'),0::bigint,'team A cannot see match B channel');
select extensions.is((select count(*) from public.match_participants where match_id='20000000-0000-4000-8000-000000000008'),0::bigint,'team A cannot read match B roster');
select extensions.is((select count(*) from public.room_credentials where match_id='20000000-0000-4000-8000-000000000007'),0::bigint,'room credentials stay hidden before release');

select extensions.is(
  public.has_permission('channel.manage_messages','community','40000000-0000-4000-8000-000000000001',null,'40000000-0000-4000-8000-000000000003'),
  false,'category Deny blocks an ordinary role grant');

-- Use service-context fixture changes; the permission checks themselves execute as the member.
reset role;
set local request.jwt.claim.sub = '';
insert into public.channel_permission_overrides(community_id,channel_id,role_id,permission_key,effect,updated_by)
values ('40000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000003',
        '40000000-0000-4000-8000-000000000004','channel.manage_messages','allow',
        '10000000-0000-4000-8000-000000000001');
set local request.jwt.claim.sub = '10000000-0000-4000-8000-000000000002';
set local role authenticated;
select extensions.is(
  public.has_permission('channel.manage_messages','community','40000000-0000-4000-8000-000000000001',null,'40000000-0000-4000-8000-000000000003'),
  true,'channel Allow overrides inherited category Deny');

reset role;
set local request.jwt.claim.sub = '';
update public.category_permission_overrides
set effect='allow',updated_at=now()
where community_id='40000000-0000-4000-8000-000000000001'
  and category_id='40000000-0000-4000-8000-000000000002'
  and role_id='40000000-0000-4000-8000-000000000004'
  and permission_key='channel.manage_messages';
update public.channel_permission_overrides
set effect='deny',updated_at=now()
where community_id='40000000-0000-4000-8000-000000000001'
  and channel_id='40000000-0000-4000-8000-000000000003'
  and role_id='40000000-0000-4000-8000-000000000004'
  and permission_key='channel.manage_messages';
set local request.jwt.claim.sub = '10000000-0000-4000-8000-000000000002';
set local role authenticated;
select extensions.is(
  public.has_permission('channel.manage_messages','community','40000000-0000-4000-8000-000000000001',null,'40000000-0000-4000-8000-000000000003'),
  false,'channel Deny overrides inherited category Allow');

reset role;
set local request.jwt.claim.sub = '';
delete from public.channel_permission_overrides
where community_id='40000000-0000-4000-8000-000000000001'
  and channel_id='40000000-0000-4000-8000-000000000003'
  and role_id='40000000-0000-4000-8000-000000000004'
  and permission_key='channel.manage_messages';
set local request.jwt.claim.sub = '10000000-0000-4000-8000-000000000002';
set local role authenticated;
select extensions.is(
  public.has_permission('channel.manage_messages','community','40000000-0000-4000-8000-000000000001',null,'40000000-0000-4000-8000-000000000003'),
  true,'removing channel override restores category inheritance');

with attempted as (
  update public.match_checkins set status='absent'
  where match_id='20000000-0000-4000-8000-000000000008'
    and user_id='10000000-0000-4000-8000-000000000003'
  returning 1
)
select extensions.is((select count(*) from attempted),0::bigint,'team A cannot mutate another match check-in');
select extensions.is((select count(*) from public.match_results where id='20000000-0000-4000-8000-000000000009'),
  0::bigint,'team A cannot read another match result');
select extensions.is((select count(*) from public.result_evidence where id='20000000-0000-4000-8000-000000000302'),
  0::bigint,'team A cannot read another team evidence');
select extensions.is((select count(*) from public.result_disputes where id='20000000-0000-4000-8000-000000000303'),
  0::bigint,'team A cannot read another team dispute');
select extensions.is(
  has_table_privilege('authenticated','public.match_results','UPDATE'),
  false,'authenticated users cannot directly update official match results');
reset role;

-- Team B has the inverse match/group visibility.
set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-4000-8000-000000000003';
select extensions.is((select count(*) from public.channels where id='20000000-0000-4000-8000-000000000206'),1::bigint,'team B sees its match channel');
select extensions.is((select count(*) from public.channels where id='20000000-0000-4000-8000-000000000205'),0::bigint,'team B cannot see match A channel');
reset role;

-- A match operator receives only the exact match scope, not the event-wide staff area.
set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-4000-8000-000000000004';
select extensions.is(public.has_permission('match.operate','match','20000000-0000-4000-8000-000000000007'),true,'operator can operate assigned match');
select extensions.is(public.has_permission('match.operate','match','20000000-0000-4000-8000-000000000008'),false,'operator cannot operate another match');
select extensions.is((select count(*) from public.channels where id='20000000-0000-4000-8000-000000000205'),1::bigint,'operator sees assigned match channel');
select extensions.is((select count(*) from public.channels where id='20000000-0000-4000-8000-000000000206'),0::bigint,'operator cannot see another match channel');
select extensions.is((select count(*) from public.channels where id='20000000-0000-4000-8000-000000000202'),0::bigint,'match operator cannot see event-wide private staff channel');
reset role;

-- A public event viewer can discover the event channel but not private or match surfaces.
set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-4000-8000-000000000005';
select extensions.is((select count(*) from public.channels where id='20000000-0000-4000-8000-000000000201'),1::bigint,'public viewer sees public event channel');
select extensions.is((select count(*) from public.channels where id='20000000-0000-4000-8000-000000000202'),0::bigint,'public viewer cannot see private event channel');
select extensions.is((select count(*) from public.channels where id='20000000-0000-4000-8000-000000000205'),0::bigint,'public viewer cannot see match channel');
reset role;

-- The event owner remains able to administer all scopes.
set local role authenticated;
set local request.jwt.claim.sub = '10000000-0000-4000-8000-000000000001';
select extensions.is((select count(*) from public.channels where id='20000000-0000-4000-8000-000000000202'),1::bigint,'event owner sees private staff channel');
select extensions.is(
  (select count(*) from public.audit_logs
   where event_id='20000000-0000-4000-8000-000000000001'
     and entity_type='room_credential'
     and metadata::text like '%B1-SECRET%'),
  0::bigint,'audit log never stores room password plaintext');
select extensions.is(
  (select count(*) from public.audit_logs
   where event_id='20000000-0000-4000-8000-000000000001'
     and entity_type='room_credential'
     and metadata #>> '{after,room_password_present}'='true'),
  1::bigint,'audit log records credential presence without secret value');
select * from extensions.finish();
rollback;
