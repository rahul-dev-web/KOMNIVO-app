-- Batch 3 authenticated runtime communication flows.
-- Exercises the actual RLS policies and BEFORE triggers with SET ROLE authenticated.
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(23);

insert into auth.users(id,aud,role,email,email_confirmed_at,raw_user_meta_data)
values
 ('61000000-0000-4000-8000-000000000001','authenticated','authenticated','b3-runtime-owner@example.test',now(),'{"full_name":"B3 Runtime Owner"}'),
 ('61000000-0000-4000-8000-000000000002','authenticated','authenticated','b3-runtime-member@example.test',now(),'{"full_name":"B3 Runtime Member"}'),
 ('61000000-0000-4000-8000-000000000003','authenticated','authenticated','b3-runtime-outsider@example.test',now(),'{"full_name":"B3 Runtime Outsider"}')
on conflict (id) do nothing;

update public.profiles set username='b3_runtime_owner' where id='61000000-0000-4000-8000-000000000001';
update public.profiles set username='b3_runtime_member' where id='61000000-0000-4000-8000-000000000002';
update public.profiles set username='b3_runtime_outsider' where id='61000000-0000-4000-8000-000000000003';

insert into public.communities(id,name,slug,description,visibility,owner_user_id)
values ('62000000-0000-4000-8000-000000000001','Batch Three Runtime Community',
        'batch-three-runtime-communication','Runtime fixture only','private',
        '61000000-0000-4000-8000-000000000001');

insert into public.community_members(community_id,user_id,role) values
 ('62000000-0000-4000-8000-000000000001','61000000-0000-4000-8000-000000000001','owner'),
 ('62000000-0000-4000-8000-000000000001','61000000-0000-4000-8000-000000000002','member')
on conflict (community_id,user_id) do nothing;

insert into public.channel_categories(id,community_id,name,description,position,created_by)
values ('63000000-0000-4000-8000-000000000001',
        '62000000-0000-4000-8000-000000000001',
        'Runtime Category','Batch 3 database test category',1,
        '61000000-0000-4000-8000-000000000001');

insert into public.channels(
 id,community_id,category_id,name,description,kind,is_private,created_by
) values
 ('64000000-0000-4000-8000-000000000001','62000000-0000-4000-8000-000000000001','63000000-0000-4000-8000-000000000001','runtime-text','Text test','text',false,'61000000-0000-4000-8000-000000000001'),
 ('64000000-0000-4000-8000-000000000002','62000000-0000-4000-8000-000000000001','63000000-0000-4000-8000-000000000001','runtime-slow','Slow-mode test','text',false,'61000000-0000-4000-8000-000000000001'),
 ('64000000-0000-4000-8000-000000000003','62000000-0000-4000-8000-000000000001','63000000-0000-4000-8000-000000000001','runtime-readonly','Read-only test','text',false,'61000000-0000-4000-8000-000000000001'),
 ('64000000-0000-4000-8000-000000000004','62000000-0000-4000-8000-000000000001','63000000-0000-4000-8000-000000000001','runtime-forum','Forum test','forum',false,'61000000-0000-4000-8000-000000000001'),
 ('64000000-0000-4000-8000-000000000005','62000000-0000-4000-8000-000000000001','63000000-0000-4000-8000-000000000001','runtime-polls','Poll test','text',false,'61000000-0000-4000-8000-000000000001'),
 ('64000000-0000-4000-8000-000000000006','62000000-0000-4000-8000-000000000001','63000000-0000-4000-8000-000000000001','runtime-announcements','Announcement test','announcement',false,'61000000-0000-4000-8000-000000000001'),
 ('64000000-0000-4000-8000-000000000007','62000000-0000-4000-8000-000000000001','63000000-0000-4000-8000-000000000001','runtime-attachments-off','Attachments disabled test','text',false,'61000000-0000-4000-8000-000000000001'),
 ('64000000-0000-4000-8000-000000000008','62000000-0000-4000-8000-000000000001','63000000-0000-4000-8000-000000000001','runtime-restricted-text','Links and broad mentions disabled test','text',false,'61000000-0000-4000-8000-000000000001');

insert into public.channel_settings(
 channel_id,community_id,read_only,slow_mode_seconds,
 allow_attachments,allow_links,allow_everyone_mention,
 announcement_publishers_only,updated_by
) values
 ('64000000-0000-4000-8000-000000000002','62000000-0000-4000-8000-000000000001',false,60,true,true,false,false,'61000000-0000-4000-8000-000000000001'),
 ('64000000-0000-4000-8000-000000000003','62000000-0000-4000-8000-000000000001',true,0,true,true,false,false,'61000000-0000-4000-8000-000000000001'),
 ('64000000-0000-4000-8000-000000000006','62000000-0000-4000-8000-000000000001',true,0,true,false,false,true,'61000000-0000-4000-8000-000000000001'),
 ('64000000-0000-4000-8000-000000000007','62000000-0000-4000-8000-000000000001',false,0,false,true,false,false,'61000000-0000-4000-8000-000000000001'),
 ('64000000-0000-4000-8000-000000000008','62000000-0000-4000-8000-000000000001',false,0,true,false,false,false,'61000000-0000-4000-8000-000000000001');

-- A member's category collapse choice is isolated to their own account.
set local role authenticated;
set local request.jwt.claim.sub = '61000000-0000-4000-8000-000000000002';
insert into public.channel_category_preferences(category_id,user_id,is_collapsed)
values ('63000000-0000-4000-8000-000000000001','61000000-0000-4000-8000-000000000002',true);
select extensions.is(
 (select count(*) from public.channel_category_preferences
  where category_id='63000000-0000-4000-8000-000000000001' and user_id=auth.uid()),
 1::bigint,
 'a member can persist their own category collapse preference'
);

-- Ordinary text messages work.
insert into public.messages(id,channel_id,sender_id,body)
values ('65000000-0000-4000-8000-000000000001','64000000-0000-4000-8000-000000000001',
        '61000000-0000-4000-8000-000000000002','A normal channel message');
select extensions.is(
 (select count(*) from public.messages where id='65000000-0000-4000-8000-000000000001'),
 1::bigint,
 'a community member can send a message in an ordinary text channel'
);

-- Attachment and content restrictions are enforced by the database write triggers.
insert into public.messages(id,channel_id,sender_id,body)
values ('65000000-0000-4000-8000-000000000003','64000000-0000-4000-8000-000000000007',
        '61000000-0000-4000-8000-000000000002','Attachment policy fixture message');
select extensions.is(
 (select count(*) from public.messages where id='65000000-0000-4000-8000-000000000003'),
 1::bigint,
 'a member can send text in a channel where attachments are disabled'
);
select extensions.throws_ok(
 $insert into public.message_attachments(message_id,uploaded_by,storage_path,content_type,file_size)
   values ('65000000-0000-4000-8000-000000000003',
           '61000000-0000-4000-8000-000000000002',
           'batch3-runtime/blocked.png','image/png',128)$,
 'P0001',
 'Attachments are disabled in this channel',
 'the database rejects attachments when channel settings disable them'
);

insert into public.messages(id,channel_id,sender_id,body)
values ('65000000-0000-4000-8000-000000000004','64000000-0000-4000-8000-000000000008',
        '61000000-0000-4000-8000-000000000002','A safe message without links or broad mentions');
select extensions.is(
 (select count(*) from public.messages where id='65000000-0000-4000-8000-000000000004'),
 1::bigint,
 'a plain text message is accepted when link and broad-mention controls are enabled'
);
select extensions.throws_ok(
 $insert into public.messages(channel_id,sender_id,body)
   values ('64000000-0000-4000-8000-000000000008',
           '61000000-0000-4000-8000-000000000002','Please visit https://example.test')$,
 'P0001',
 'Links are disabled in this channel',
 'the database rejects links in a channel with links disabled'
);
select extensions.throws_ok(
 $insert into public.messages(channel_id,sender_id,body)
   values ('64000000-0000-4000-8000-000000000008',
           '61000000-0000-4000-8000-000000000002','@everyone please join')$,
 'P0001',
 'Broad mentions are disabled in this channel',
 'the database rejects broad mentions when they are disabled'
);

-- Slow mode allows the first message and rejects a second message from the same sender.
insert into public.messages(id,channel_id,sender_id,body)
values ('65000000-0000-4000-8000-000000000002','64000000-0000-4000-8000-000000000002',
        '61000000-0000-4000-8000-000000000002','First slow-mode message');
select extensions.is(
 (select count(*) from public.messages where id='65000000-0000-4000-8000-000000000002'),
 1::bigint,
 'the first message in a slow-mode channel is accepted'
);
select extensions.throws_ok(
 $$insert into public.messages(channel_id,sender_id,body)
   values ('64000000-0000-4000-8000-000000000002',
           '61000000-0000-4000-8000-000000000002','Second slow-mode message')$$,
 'P0001',
 'Slow mode is active. Please wait before sending again',
 'slow mode is enforced by the database for authenticated members'
);

-- Read-only is enforced in the database, not only by disabling the composer.
select extensions.throws_ok(
 $$insert into public.messages(channel_id,sender_id,body)
   values ('64000000-0000-4000-8000-000000000003',
           '61000000-0000-4000-8000-000000000002','This must be rejected')$$,
 'P0001',
 'This channel is read-only',
 'read-only channels reject member message writes'
);

-- Forum channel creation, reply creation and poll voting all use the real RLS paths.
insert into public.forum_posts(id,channel_id,community_id,author_id,title,body,tag)
values ('66000000-0000-4000-8000-000000000001',
        '64000000-0000-4000-8000-000000000004',
        '62000000-0000-4000-8000-000000000001',
        '61000000-0000-4000-8000-000000000002',
        'Looking for a squad','Need two players for the weekend.','Recruitment');
select extensions.is(
 (select count(*) from public.forum_posts where id='66000000-0000-4000-8000-000000000001'),
 1::bigint,
 'a member can publish a tagged Forum post in a forum channel'
);

insert into public.forum_post_replies(post_id,author_id,body)
values ('66000000-0000-4000-8000-000000000001',
        '61000000-0000-4000-8000-000000000002','I can join the squad.');
select extensions.is(
 (select count(*) from public.forum_post_replies where post_id='66000000-0000-4000-8000-000000000001'),
 1::bigint,
 'a member can reply to an open Forum post'
);

select set_config(
 'b3.runtime_poll_id',
 public.create_channel_poll(
   '64000000-0000-4000-8000-000000000005',
   '62000000-0000-4000-8000-000000000001',
   'Which practice window works?',
   array['Morning','Evening']::text[],
   false,
   null
 )::text,
 true
);
select set_config(
 'b3.runtime_option_one',
 (select id::text from public.channel_poll_options
  where poll_id=current_setting('b3.runtime_poll_id')::uuid and position=0),
 true
);
select set_config(
 'b3.runtime_option_two',
 (select id::text from public.channel_poll_options
  where poll_id=current_setting('b3.runtime_poll_id')::uuid and position=1),
 true
);
select set_config(
 'b3.runtime_vote_count',
 public.vote_channel_poll(
   current_setting('b3.runtime_poll_id')::uuid,
   array[current_setting('b3.runtime_option_one')::uuid]
 )::text,
 true
);
select extensions.is(
 current_setting('b3.runtime_vote_count')::integer,
 1,
 'an ordinary channel member can cast a poll vote without poll-moderation rights'
);
select extensions.is(
 (select count(*) from public.channel_poll_feed('64000000-0000-4000-8000-000000000005')
  where selected_by_me),
 1::bigint,
 'the poll feed returns the caller-specific selected option without exposing voter identity'
);
select set_config(
 'b3.runtime_vote_count',
 public.vote_channel_poll(
   current_setting('b3.runtime_poll_id')::uuid,
   array[current_setting('b3.runtime_option_two')::uuid]
 )::text,
 true
);
select extensions.is(
 (select count(*) from public.channel_poll_votes
  where poll_id=current_setting('b3.runtime_poll_id')::uuid
    and user_id=auth.uid()),
 1::bigint,
 'a single-choice poll replaces the current member vote instead of accumulating votes'
);

-- The outsider has no community membership and sees neither Forum nor poll data.
reset role;
set local role authenticated;
set local request.jwt.claim.sub = '61000000-0000-4000-8000-000000000003';
select extensions.is(
 (select count(*) from public.forum_posts
  where id='66000000-0000-4000-8000-000000000001'),
 0::bigint,
 'a non-member cannot read private-community Forum posts'
);
select extensions.is(
 (select count(*) from public.channel_poll_feed('64000000-0000-4000-8000-000000000005')),
 0::bigint,
 'a non-member cannot read poll results from a private community channel'
);

-- Community members cannot manage pins; channel moderators/owners can.
reset role;
set local role authenticated;
set local request.jwt.claim.sub = '61000000-0000-4000-8000-000000000002';
select extensions.throws_ok(
 $$insert into public.message_pins(channel_id,message_id,pinned_by)
   values ('64000000-0000-4000-8000-000000000001',
           '65000000-0000-4000-8000-000000000001',
           '61000000-0000-4000-8000-000000000002')$$,
 'P0001',
 'You cannot manage pinned messages in this channel',
 'ordinary members cannot pin messages without moderation authority'
);

-- Owner moderation and announcement scheduling use the authenticated API path.
reset role;
set local role authenticated;
set local request.jwt.claim.sub = '61000000-0000-4000-8000-000000000001';
select extensions.is(
 (public.set_forum_post_status(
   '66000000-0000-4000-8000-000000000001','Closed',true,true
 )).status,
 'Closed'::text,
 'the community owner can close and moderate a Forum topic'
);

insert into public.message_pins(channel_id,message_id,pinned_by)
values ('64000000-0000-4000-8000-000000000001',
        '65000000-0000-4000-8000-000000000001',
        '61000000-0000-4000-8000-000000000001');
select extensions.is(
 (select count(*) from public.message_pins
  where channel_id='64000000-0000-4000-8000-000000000001'
    and message_id='65000000-0000-4000-8000-000000000001'),
 1::bigint,
 'the authorised community owner can persist a channel pin'
);

insert into public.scheduled_channel_announcements(
 id,channel_id,community_id,created_by,body,publish_at
) values (
 '67000000-0000-4000-8000-000000000001',
 '64000000-0000-4000-8000-000000000006',
 '62000000-0000-4000-8000-000000000001',
 '61000000-0000-4000-8000-000000000001',
 'Scheduled event briefing',now()-interval '1 minute'
);
reset role;

select public.publish_due_channel_announcements(25);
select extensions.is(
 (select status from public.scheduled_channel_announcements
  where id='67000000-0000-4000-8000-000000000001'),
 'published'::text,
 'the scheduled publisher changes a due announcement to published'
);
select extensions.is(
 (select count(*) from public.messages
  where channel_id='64000000-0000-4000-8000-000000000006'
    and body='Scheduled event briefing'),
 1::bigint,
 'the scheduled publisher creates exactly one announcement message'
);

set local role authenticated;
set local request.jwt.claim.sub = '61000000-0000-4000-8000-000000000001';
insert into public.scheduled_channel_announcements(
 id,channel_id,community_id,created_by,body,publish_at
) values (
 '67000000-0000-4000-8000-000000000002',
 '64000000-0000-4000-8000-000000000006',
 '62000000-0000-4000-8000-000000000001',
 '61000000-0000-4000-8000-000000000001',
 'Announcement that will be cancelled',now()+interval '1 day'
);
select public.cancel_channel_announcement('67000000-0000-4000-8000-000000000002');
reset role;
select extensions.is(
 (select status from public.scheduled_channel_announcements
  where id='67000000-0000-4000-8000-000000000002'),
 'cancelled'::text,
 'the announcement creator can cancel their pending scheduled announcement'
);

select * from extensions.finish();
rollback;
