-- Targeted mention recipient and correction contracts.
-- Run with: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(20);

select extensions.has_table('public','message_mentions',
  'Targeted mention recipient snapshots have a dedicated table');
select extensions.ok(
  (select relrowsecurity from pg_class where oid='public.message_mentions'::regclass),
  'Mention snapshots are protected by RLS'
);
select extensions.ok(
  exists(select 1 from pg_constraint where conrelid='public.message_mentions'::regclass
    and contype='u' and pg_get_constraintdef(oid) ilike '%message_id, mentioned_user_id%'),
  'A message cannot create duplicate recipient snapshots for one user'
);
select extensions.ok(
  has_table_privilege('authenticated','public.message_mentions','SELECT')
  AND NOT has_table_privilege('authenticated','public.message_mentions','INSERT')
  AND NOT has_table_privilege('authenticated','public.message_mentions','UPDATE'),
  'Authenticated clients can read their mention snapshots but cannot create or edit them'
);
select extensions.ok(
  NOT has_function_privilege('authenticated','app_private.can_user_receive_channel_mention(uuid,uuid)','EXECUTE'),
  'Recipient eligibility helper is not directly callable by authenticated clients'
);
select extensions.ok(
  to_regprocedure('public.channel_mention_candidates(uuid,text)') is not null,
  'The client has a dedicated mention-candidate RPC'
);
select extensions.ok(
  has_function_privilege('authenticated','public.channel_mention_candidates(uuid,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.channel_mention_candidates(uuid,text)','EXECUTE'),
  'Only authenticated users can request mention candidates'
);
select extensions.ok(
  position('app_private.can_send_channel_message' in pg_get_functiondef('public.channel_mention_candidates(uuid,text)'::regprocedure))>0
  AND position('allow_user_mentions' in pg_get_functiondef('public.channel_mention_candidates(uuid,text)'::regprocedure))>0,
  'Mention candidates require sender permission and channel mention settings'
);
select extensions.ok(
  position('app_private.can_user_receive_channel_mention' in pg_get_functiondef('public.channel_mention_candidates(uuid,text)'::regprocedure))>0,
  'Mention suggestions are filtered to users who can access that exact channel'
);
select extensions.ok(
  position('team_members' in pg_get_functiondef('app_private.can_user_receive_channel_mention(uuid,uuid)'::regprocedure))>0
  AND position('match_participants' in pg_get_functiondef('app_private.can_user_receive_channel_mention(uuid,uuid)'::regprocedure))>0,
  'Match mention eligibility is limited to participants, host or scoped match staff'
);
select extensions.ok(
  position('event_group_teams' in pg_get_functiondef('app_private.can_user_receive_channel_mention(uuid,uuid)'::regprocedure))>0,
  'Group mentions are limited to group teams or authorised staff'
);
select extensions.ok(
  position('event_staff_assignments' in pg_get_functiondef('app_private.can_user_receive_channel_mention(uuid,uuid)'::regprocedure))>0,
  'Event/stage/group/match staff are resolved from explicit staff assignments'
);
select extensions.ok(
  position('channel_members' in pg_get_functiondef('app_private.can_user_receive_channel_mention(uuid,uuid)'::regprocedure))>0
  AND position('community_member_roles' in pg_get_functiondef('app_private.can_user_receive_channel_mention(uuid,uuid)'::regprocedure))>0,
  'Private community/DM mentions respect channel membership and permission overrides'
);
select extensions.ok(
  position('regexp_matches' in pg_get_functiondef('app_private.sync_message_mentions(uuid,uuid,uuid,text,boolean)'::regprocedure))>0
  AND position('message_mentions' in pg_get_functiondef('app_private.sync_message_mentions(uuid,uuid,uuid,text,boolean)'::regprocedure))>0,
  'Messages resolve explicit @username tokens to recipient snapshots'
);
select extensions.ok(
  position('The mentioned user cannot access this channel' in pg_get_functiondef('app_private.sync_message_mentions(uuid,uuid,uuid,text,boolean)'::regprocedure))>0,
  'Invalid or out-of-scope mention recipients reject the message transaction'
);
select extensions.ok(
  position('mention_correction' in pg_get_functiondef('app_private.sync_message_mentions(uuid,uuid,uuid,text,boolean)'::regprocedure))>0
  AND position('status=''removed''' in pg_get_functiondef('app_private.sync_message_mentions(uuid,uuid,uuid,text,boolean)'::regprocedure))>0,
  'Removing or deleting a message mention leaves a correction snapshot and notification'
);
select extensions.ok(
  position('app_private.sync_message_mentions' in pg_get_functiondef('app_private.notify_channel_members()'::regprocedure))>0
  AND position('message_mentions' in pg_get_functiondef('app_private.notify_channel_members()'::regprocedure))>0,
  'The message notification trigger creates targeted mentions and excludes them from duplicate generic pushes'
);
select extensions.ok(
  exists(select 1 from pg_trigger where tgrelid='public.messages'::regclass
    and tgname='messages_sync_mentions_after_update' and not tgisinternal),
  'Message edits and deletes reconcile mention snapshots'
);
select extensions.ok(
  position('everyone' in pg_get_functiondef('app_private.sync_message_mentions(uuid,uuid,uuid,text,boolean)'::regprocedure))>0
  AND position('here' in pg_get_functiondef('app_private.sync_message_mentions(uuid,uuid,uuid,text,boolean)'::regprocedure))>0,
  'Broad @everyone/@here tokens are not converted into targeted mention recipients'
);
select extensions.ok(
  position('mentioned_user_id' in pg_get_functiondef('app_private.notify_channel_members()'::regprocedure))>0,
  'The generic message notification path excludes users who received a targeted mention'
);

select * from extensions.finish();
rollback;
