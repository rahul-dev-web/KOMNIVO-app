-- Batch 3 approved event-template creation, idempotency and scoped lifecycle integration.
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(20);

insert into auth.users(id,aud,role,email,email_confirmed_at,raw_user_meta_data)
values
 ('71000000-0000-4000-8000-000000000001','authenticated','authenticated','b3-event-owner@example.test',now(),'{"full_name":"B3 Event Owner"}'),
 ('71000000-0000-4000-8000-000000000002','authenticated','authenticated','b3-stage-staff@example.test',now(),'{"full_name":"B3 Stage Staff"}')
on conflict (id) do nothing;
update public.profiles set username='b3_event_owner' where id='71000000-0000-4000-8000-000000000001';
update public.profiles set username='b3_stage_staff' where id='71000000-0000-4000-8000-000000000002';

insert into public.games(id,code,name,platform,is_active)
values ('72000000-0000-4000-8000-000000000001','b3-event-lifecycle-test','Batch Three Event Lifecycle Test','mobile',true)
on conflict (id) do nothing;

insert into public.communities(id,name,slug,description,visibility,owner_user_id)
values ('73000000-0000-4000-8000-000000000001','Batch Three Event Community',
        'batch-three-event-communication-test','Runtime event fixture only','private',
        '71000000-0000-4000-8000-000000000001')
on conflict (id) do nothing;

insert into public.community_members(community_id,user_id,role) values
 ('73000000-0000-4000-8000-000000000001','71000000-0000-4000-8000-000000000001','owner'),
 ('73000000-0000-4000-8000-000000000001','71000000-0000-4000-8000-000000000002','member')
on conflict (community_id,user_id) do nothing;

insert into public.events(
 id,community_id,game_id,organizer_id,name,description,format,status,starts_at,capacity,rules_json,scoring_config
) values (
 '74000000-0000-4000-8000-000000000001',
 '73000000-0000-4000-8000-000000000001',
 '72000000-0000-4000-8000-000000000001',
 '71000000-0000-4000-8000-000000000001',
 'Batch Three Lifecycle Event','Runtime fixture only','squad','published',now(),8,'{}','{"kill_point":1,"placement_points":{}}'
);

insert into public.event_rounds(
 id,event_id,round_number,name,status,configuration,stage_type,group_size,
 matches_per_group,advancement_rules,room_release_minutes_before
) values (
 '75000000-0000-4000-8000-000000000001',
 '74000000-0000-4000-8000-000000000001',
 1,'Batch Three Stage','live','{}','qualifier',2,1,'{"top_n":1}',10
);

insert into public.event_groups(id,round_id,label,sort_order)
values ('76000000-0000-4000-8000-000000000001',
        '75000000-0000-4000-8000-000000000001','Batch Three Group',1);

insert into public.event_staff_assignments(
 event_id,user_id,role_key,scope_type,stage_id,assigned_by
) values (
 '74000000-0000-4000-8000-000000000001',
 '71000000-0000-4000-8000-000000000002',
 'match_operator','stage','75000000-0000-4000-8000-000000000001',
 '71000000-0000-4000-8000-000000000001'
);

-- Stage-scoped staff must not gain event-wide template or lifecycle authority.
set local role authenticated;
set local request.jwt.claim.sub = '71000000-0000-4000-8000-000000000002';
select extensions.throws_ok(
 $$select public.create_event_communication_channels(
   '74000000-0000-4000-8000-000000000001','results_disputes',null,null,null
 )$$,
 'P0001',
 'You cannot create event communication channels',
 'stage-scoped staff cannot create event-wide communication templates'
);
select extensions.throws_ok(
 $$select public.save_event_channel_lifecycle_rule(
   '74000000-0000-4000-8000-000000000001','event',null,'completed','archive',true,true,false
 )$$,
 'P0001',
 'You cannot manage this event lifecycle',
 'stage-scoped staff cannot change event-wide channel lifecycle rules'
);
reset role;

insert into public.matches(
 id,event_id,round_number,group_label,match_number,status,stage_id,group_id,group_match_number,match_code
) values (
 '77000000-0000-4000-8000-000000000001',
 '74000000-0000-4000-8000-000000000001',
 1,'Batch Three Group',1,'scheduled',
 '75000000-0000-4000-8000-000000000001',
 '76000000-0000-4000-8000-000000000001',1,'B3-M1'
);

-- Attach a real team, participant, official result and evidence to the match.
insert into public.teams(id,name,tag,game_id,owner_user_id,is_public)
values (
 '78000000-0000-4000-8000-000000000001',
 'Batch Three Fixture Team','B3F',
 '72000000-0000-4000-8000-000000000001',
 '71000000-0000-4000-8000-000000000001',false
);
-- Team creation automatically creates the owner's captain membership.
insert into public.event_group_teams(group_id,team_id,seeded_by)
values (
 '76000000-0000-4000-8000-000000000001',
 '78000000-0000-4000-8000-000000000001',
 '71000000-0000-4000-8000-000000000001'
);
insert into public.match_participants(match_id,team_id,check_in_status,slot_number)
values (
 '77000000-0000-4000-8000-000000000001',
 '78000000-0000-4000-8000-000000000001','ready',1
);
insert into public.match_results(
 id,match_id,team_id,submitted_by,placement,kills,points,status,result_json
) values (
 '79000000-0000-4000-8000-000000000001',
 '77000000-0000-4000-8000-000000000001',
 '78000000-0000-4000-8000-000000000001',
 '71000000-0000-4000-8000-000000000001',
 1,4,14,'submitted','{"fixture":true}'
);
insert into public.result_evidence(
 id,result_id,uploaded_by,storage_path,content_type,file_size
) values (
 '7a000000-0000-4000-8000-000000000001',
 '79000000-0000-4000-8000-000000000001',
 '71000000-0000-4000-8000-000000000001',
 'batch3-runtime/evidence/match-1.png','image/png',256
);

-- Group-room automation creates one shared private channel; templates must reuse it.
set local role authenticated;
set local request.jwt.claim.sub = '71000000-0000-4000-8000-000000000001';

select set_config(
 'b3.event_template',
 public.create_event_communication_channels(
   '74000000-0000-4000-8000-000000000001','results_disputes',null,null,null
 )::text,
 true
);
select extensions.is(
 current_setting('b3.event_template')::jsonb->>'created','true',
 'approved event-wide communication template creates its channels'
);
select set_config(
 'b3.event_template_duplicate',
 public.create_event_communication_channels(
   '74000000-0000-4000-8000-000000000001','results_disputes',null,null,null
 )::text,
 true
);
select extensions.is(
 current_setting('b3.event_template_duplicate')::jsonb->>'created','false',
 'repeating an event-wide template is idempotent'
);
select extensions.is(
 (select cardinality(channel_ids) from public.event_communication_instances
  where event_id='74000000-0000-4000-8000-000000000001' and template_key='results_disputes'),
 2,
 'event template instance stores both of its channels'
);

select set_config(
 'b3.group_template',
 public.create_event_communication_channels(
   '74000000-0000-4000-8000-000000000001','group_coordination',
   '75000000-0000-4000-8000-000000000001',
   '76000000-0000-4000-8000-000000000001',null
 )::text,
 true
);
select extensions.is(
 current_setting('b3.group_template')::jsonb->>'created','true',
 'group template reuses the pre-created private group room'
);
select extensions.is(
 (select count(*) from public.channels
  where event_id='74000000-0000-4000-8000-000000000001'
    and group_id='76000000-0000-4000-8000-000000000001'
    and match_id is null),
 1::bigint,
 'group template does not create a duplicate private group room'
);
select extensions.is(
 (select count(*) from public.channel_categories
  where group_id='76000000-0000-4000-8000-000000000001'
    and char_length(name) between 2 and 60),
 1::bigint,
 'automatically generated group category names satisfy the 60-character schema limit'
);
select set_config(
 'b3.group_template_duplicate',
 public.create_event_communication_channels(
   '74000000-0000-4000-8000-000000000001','group_coordination',
   '75000000-0000-4000-8000-000000000001',
   '76000000-0000-4000-8000-000000000001',null
 )::text,
 true
);
select extensions.is(
 current_setting('b3.group_template_duplicate')::jsonb->>'created','false',
 'repeated group template requests are idempotent'
);

select set_config(
 'b3.stage_template',
 public.create_event_communication_channels(
   '74000000-0000-4000-8000-000000000001','stage_briefing',
   '75000000-0000-4000-8000-000000000001',null,null
 )::text,
 true
);
select extensions.is(
 current_setting('b3.stage_template')::jsonb->>'created','true',
 'approved stage briefing template creates stage-scoped channels'
);

select public.save_event_channel_lifecycle_rule(
 '74000000-0000-4000-8000-000000000001','stage',
 '75000000-0000-4000-8000-000000000001','completed','archive',true,true,true
);
reset role;

-- Completing a stage archives only its temporary communication channels and
-- notifies the member assigned to that stage.
set local role authenticated;
set local request.jwt.claim.sub = '71000000-0000-4000-8000-000000000001';
update public.event_rounds set status='completed'
where id='75000000-0000-4000-8000-000000000001';
select extensions.is(
 (select count(*) from public.channels c
  join public.event_communication_instances i on c.id=any(i.channel_ids)
  where i.event_id='74000000-0000-4000-8000-000000000001'
    and i.template_key='stage_briefing' and c.archived_at is not null),
 2::bigint,
 'stage completion archives the temporary stage template channels'
);
select extensions.is(
 (select count(*) from public.notifications
  where user_id='71000000-0000-4000-8000-000000000002'
    and entity_id='74000000-0000-4000-8000-000000000001'
    and title='Event communication access updated'),
 1::bigint,
 'stage-scoped staff receive the lifecycle access notification'
);
reset role;

-- Match rooms are separately scoped; completing a match archives only the
-- match template channels, retaining the shared group room and official match.
set local role authenticated;
set local request.jwt.claim.sub = '71000000-0000-4000-8000-000000000001';
select set_config(
 'b3.match_template',
 public.create_event_communication_channels(
   '74000000-0000-4000-8000-000000000001','match_room',
   '75000000-0000-4000-8000-000000000001',
   '76000000-0000-4000-8000-000000000001',
   '77000000-0000-4000-8000-000000000001'
 )::text,
 true
);
select extensions.is(
 current_setting('b3.match_template')::jsonb->>'created','true',
 'approved match-room template creates match-scoped communication channels'
);
select set_config(
 'b3.match_template_duplicate',
 public.create_event_communication_channels(
   '74000000-0000-4000-8000-000000000001','match_room',
   '75000000-0000-4000-8000-000000000001',
   '76000000-0000-4000-8000-000000000001',
   '77000000-0000-4000-8000-000000000001'
 )::text,
 true
);
select extensions.is(
 current_setting('b3.match_template_duplicate')::jsonb->>'created','false',
 'repeated match template creation does not duplicate channels'
);

select public.save_event_channel_lifecycle_rule(
 '74000000-0000-4000-8000-000000000001','match',
 '77000000-0000-4000-8000-000000000001','completed','archive',true,true,false
);
update public.matches set status='completed'
where id='77000000-0000-4000-8000-000000000001';
select extensions.is(
 (select count(*) from public.channels c
  join public.event_communication_instances i on c.id=any(i.channel_ids)
  where i.event_id='74000000-0000-4000-8000-000000000001'
    and i.template_key='match_room' and c.archived_at is not null),
 2::bigint,
 'match completion archives the match-only chat and voice channels'
);
select extensions.is(
 (select count(*) from public.channels
  where event_id='74000000-0000-4000-8000-000000000001'
    and group_id='76000000-0000-4000-8000-000000000001'
    and match_id is null),
 1::bigint,
 'match completion retains the shared group communication room'
);

-- Event completion archives event-wide temporary communication channels while
-- retaining the official match row and all channel/history records.
select public.save_event_channel_lifecycle_rule(
 '74000000-0000-4000-8000-000000000001','event',null,'completed','archive',true,true,false
);
update public.events set status='completed'
where id='74000000-0000-4000-8000-000000000001';
select extensions.is(
 (select count(*) from public.channels c
  join public.event_communication_instances i on c.id=any(i.channel_ids)
  where i.event_id='74000000-0000-4000-8000-000000000001'
    and i.template_key='results_disputes' and c.archived_at is not null),
 2::bigint,
 'event completion archives temporary event-wide communication channels'
);
select extensions.is(
 (select count(*) from public.matches
  where id='77000000-0000-4000-8000-000000000001'),
 1::bigint,
 'channel lifecycle actions preserve the structured official match record'
);
select extensions.is(
 (select count(*) from public.match_results
  where id='79000000-0000-4000-8000-000000000001'
    and match_id='77000000-0000-4000-8000-000000000001'),
 1::bigint,
 'channel archive/lock transitions preserve the official submitted result'
);
select extensions.is(
 (select count(*) from public.result_evidence
  where id='7a000000-0000-4000-8000-000000000001'
    and result_id='79000000-0000-4000-8000-000000000001'),
 1::bigint,
 'channel archive/lock transitions preserve match evidence records'
);

reset role;
select * from extensions.finish();
rollback;
