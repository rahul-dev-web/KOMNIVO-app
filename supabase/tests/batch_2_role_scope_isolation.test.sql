-- Batch 2, item 1: explicit Event staff scope regression tests.
-- Verifies that stage/group/match assignments grant only their own scope,
-- never event-wide authority, and cannot point at resources in another event.

begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(17);

insert into auth.users(id,aud,role,email,email_confirmed_at,raw_user_meta_data)
values
 ('51000000-0000-4000-8000-000000000001','authenticated','authenticated','b2-scope-owner@example.test',now(),'{"full_name":"B2 Scope Owner"}'),
 ('51000000-0000-4000-8000-000000000002','authenticated','authenticated','b2-stage-operator@example.test',now(),'{"full_name":"B2 Stage Operator"}'),
 ('51000000-0000-4000-8000-000000000003','authenticated','authenticated','b2-group-operator@example.test',now(),'{"full_name":"B2 Group Operator"}'),
 ('51000000-0000-4000-8000-000000000004','authenticated','authenticated','b2-match-operator@example.test',now(),'{"full_name":"B2 Match Operator"}')
on conflict (id) do nothing;

update public.profiles set username='b2_scope_owner' where id='51000000-0000-4000-8000-000000000001';
update public.profiles set username='b2_stage_operator' where id='51000000-0000-4000-8000-000000000002';
update public.profiles set username='b2_group_operator' where id='51000000-0000-4000-8000-000000000003';
update public.profiles set username='b2_match_operator' where id='51000000-0000-4000-8000-000000000004';

insert into public.games(id,code,name,platform,is_active)
values ('52000000-0000-4000-8000-000000000001','b2-role-scope-test','Batch Two Role Scope Test','mobile',true)
on conflict (id) do nothing;

insert into public.events(
 id,game_id,organizer_id,name,description,format,status,starts_at,capacity,rules_json,scoring_config
) values
 ('53000000-0000-4000-8000-000000000001','52000000-0000-4000-8000-000000000001',
  '51000000-0000-4000-8000-000000000001','B2 Scope Event A','RLS fixture only','squad','draft',now(),8,'{}','{"kill_point":1,"placement_points":{}}'),
 ('53000000-0000-4000-8000-000000000002','52000000-0000-4000-8000-000000000001',
  '51000000-0000-4000-8000-000000000001','B2 Scope Event B','RLS fixture only','squad','draft',now(),8,'{}','{"kill_point":1,"placement_points":{}}');

insert into public.event_rounds(
 id,event_id,round_number,name,status,configuration,stage_type,group_size,matches_per_group,advancement_rules,room_release_minutes_before
) values
 ('54000000-0000-4000-8000-000000000001','53000000-0000-4000-8000-000000000001',1,'B2 Stage A','live','{}','qualifier',2,1,'{"top_n":1}',10),
 ('54000000-0000-4000-8000-000000000002','53000000-0000-4000-8000-000000000002',1,'B2 Stage B','live','{}','qualifier',2,1,'{"top_n":1}',10);

insert into public.event_groups(id,round_id,label,sort_order) values
 ('55000000-0000-4000-8000-000000000001','54000000-0000-4000-8000-000000000001','B2 Group A',1),
 ('55000000-0000-4000-8000-000000000002','54000000-0000-4000-8000-000000000001','B2 Group B',2),
 ('55000000-0000-4000-8000-000000000003','54000000-0000-4000-8000-000000000002','B2 Other Event Group',1);

insert into public.matches(
 id,event_id,round_number,group_label,match_number,status,stage_id,group_id,group_match_number
) values
 ('56000000-0000-4000-8000-000000000001','53000000-0000-4000-8000-000000000001',1,'B2 Group A',1,'scheduled','54000000-0000-4000-8000-000000000001','55000000-0000-4000-8000-000000000001',1),
 ('56000000-0000-4000-8000-000000000002','53000000-0000-4000-8000-000000000001',1,'B2 Group B',2,'scheduled','54000000-0000-4000-8000-000000000001','55000000-0000-4000-8000-000000000002',1),
 ('56000000-0000-4000-8000-000000000003','53000000-0000-4000-8000-000000000002',1,'B2 Other Event Group',1,'scheduled','54000000-0000-4000-8000-000000000002','55000000-0000-4000-8000-000000000003',1);

-- Fixture setup runs without an authenticated actor, just like the existing pgTAP fixtures.
insert into public.event_staff_assignments(
 event_id,user_id,role_key,scope_type,stage_id,group_id,match_id,assigned_by
) values
 ('53000000-0000-4000-8000-000000000001','51000000-0000-4000-8000-000000000002','match_operator','stage',
  '54000000-0000-4000-8000-000000000001',null,null,'51000000-0000-4000-8000-000000000001'),
 ('53000000-0000-4000-8000-000000000001','51000000-0000-4000-8000-000000000003','match_operator','group',
  null,'55000000-0000-4000-8000-000000000001',null,'51000000-0000-4000-8000-000000000001'),
 ('53000000-0000-4000-8000-000000000001','51000000-0000-4000-8000-000000000004','match_operator','match',
  null,null,'56000000-0000-4000-8000-000000000001','51000000-0000-4000-8000-000000000001');

-- Stage assignment is inherited by all groups/matches in that stage, not by other events.
set local role authenticated;
set local request.jwt.claim.sub = '51000000-0000-4000-8000-000000000002';
select extensions.is(public.has_permission('stage.view','stage','54000000-0000-4000-8000-000000000001'),true,'stage operator can view assigned stage');
select extensions.is(public.has_permission('group.view','group','55000000-0000-4000-8000-000000000001'),true,'stage operator can view first child group');
select extensions.is(public.has_permission('group.view','group','55000000-0000-4000-8000-000000000002'),true,'stage operator can view second child group');
select extensions.is(public.has_permission('match.operate','match','56000000-0000-4000-8000-000000000001'),true,'stage operator can operate first stage match');
select extensions.is(public.has_permission('match.operate','match','56000000-0000-4000-8000-000000000002'),true,'stage operator can operate second stage match');
select extensions.is(public.has_permission('event.matches.operate','event','53000000-0000-4000-8000-000000000001'),false,'stage operator does not receive event-wide operations');
select extensions.is(public.has_permission('event.staff.assign','event','53000000-0000-4000-8000-000000000001'),false,'stage operator cannot assign event-wide staff');
select extensions.is(public.has_permission('match.operate','match','56000000-0000-4000-8000-000000000003'),false,'stage operator cannot operate a match in another event');
reset role;

-- Group assignment is limited to matches inside that group.
set local role authenticated;
set local request.jwt.claim.sub = '51000000-0000-4000-8000-000000000003';
select extensions.is(public.has_permission('match.operate','match','56000000-0000-4000-8000-000000000001'),true,'group operator can operate assigned group match');
select extensions.is(public.has_permission('match.operate','match','56000000-0000-4000-8000-000000000002'),false,'group operator cannot operate sibling group match');
select extensions.is(public.has_permission('event.matches.operate','event','53000000-0000-4000-8000-000000000001'),false,'group operator does not receive event-wide operations');
select extensions.is(public.has_permission('event.staff.assign','event','53000000-0000-4000-8000-000000000001'),false,'group operator cannot assign event-wide staff');
reset role;

-- Match assignment is limited to one exact match.
set local role authenticated;
set local request.jwt.claim.sub = '51000000-0000-4000-8000-000000000004';
select extensions.is(public.has_permission('match.operate','match','56000000-0000-4000-8000-000000000001'),true,'match operator can operate exact assigned match');
select extensions.is(public.has_permission('match.operate','match','56000000-0000-4000-8000-000000000002'),false,'match operator cannot operate another match');
select extensions.is(public.has_permission('event.matches.operate','event','53000000-0000-4000-8000-000000000001'),false,'match operator does not receive event-wide operations');
select extensions.is(public.has_permission('event.staff.assign','event','53000000-0000-4000-8000-000000000001'),false,'match operator cannot assign event-wide staff');
reset role;

-- The trigger must reject a scoped assignment whose target resource belongs to another event.
set local role authenticated;
set local request.jwt.claim.sub = '51000000-0000-4000-8000-000000000001';
select extensions.throws_ok(
 $$insert into public.event_staff_assignments(event_id,user_id,role_key,scope_type,match_id,assigned_by)
   values ('53000000-0000-4000-8000-000000000001','51000000-0000-4000-8000-000000000003',
           'match_operator','match','56000000-0000-4000-8000-000000000003',
           '51000000-0000-4000-8000-000000000001')$$,
 'P0001',
 'Event staff scope must reference a resource within the same event',
 'event staff assignment cannot reference a match in another event');
reset role;

select * from extensions.finish();
rollback;
