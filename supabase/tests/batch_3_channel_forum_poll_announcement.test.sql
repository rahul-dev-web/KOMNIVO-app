-- Batch 3 database contract tests. Run with: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(1);
do $test$
declare v_table text; v_def text; v_policy text;
begin
  foreach v_table in array array[
    'channel_settings','channel_category_preferences','forum_posts','forum_post_replies',
    'channel_polls','channel_poll_options','channel_poll_votes','scheduled_channel_announcements'
  ] loop
    if not exists (
      select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname=v_table and c.relrowsecurity
    ) then raise exception 'Batch 3: RLS missing on public.%',v_table; end if;
  end loop;

  if not exists(select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='messages' and t.tgname='messages_batch3_channel_guard' and not t.tgisinternal)
  then raise exception 'Batch 3: message behaviour enforcement trigger missing'; end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='app_private' and p.proname='guard_batch3_channel_message';
  if v_def is null or position('slow_mode_seconds' in v_def)=0
    or position('read_only' in v_def)=0
    or position('announcement_publishers_only' in v_def)=0
    or position('service_role' in v_def)=0
  then raise exception 'Batch 3: channel behaviour guard is incomplete'; end if;

  if has_function_privilege('authenticated','public.publish_due_channel_announcements(integer)','EXECUTE')
    or has_function_privilege('anon','public.publish_due_channel_announcements(integer)','EXECUTE')
  then raise exception 'Batch 3: scheduled publisher is exposed to client roles'; end if;
  if not has_function_privilege('service_role','public.publish_due_channel_announcements(integer)','EXECUTE')
  then raise exception 'Batch 3: service role cannot run scheduled publisher'; end if;

  if not has_function_privilege('authenticated','public.vote_channel_poll(uuid,uuid[])','EXECUTE')
    or not has_function_privilege('authenticated','public.create_channel_poll(uuid,uuid,text,text[],boolean,timestamp with time zone)','EXECUTE')
  then raise exception 'Batch 3: poll RPC grants are missing'; end if;

  select coalesce(qual,'') into v_policy from pg_policies
    where schemaname='public' and tablename='forum_posts' and policyname='forum_posts_read';
  if v_policy is null or position('can_view_channel_resource' in v_policy)=0
  then raise exception 'Batch 3: forum reads are not channel scoped'; end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='set_forum_post_status';
  if v_def is null or position('channel.manage_messages' in v_def)=0
  then raise exception 'Batch 3: forum moderation bypasses canonical permission resolver'; end if;

  if not exists(select 1 from pg_indexes where schemaname='public' and tablename='scheduled_channel_announcements' and indexname='scheduled_announcements_due_idx')
  then raise exception 'Batch 3: due announcement index missing'; end if;

  foreach v_table in array array[
    'event_channel_templates','event_communication_instances','event_channel_lifecycle_rules'
  ] loop
    if not exists (
      select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname=v_table and c.relrowsecurity
    ) then raise exception 'Batch 3: event communication RLS missing on public.%',v_table; end if;
  end loop;

  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='channels'
      and column_name='is_temporary' and data_type='boolean'
  ) then raise exception 'Batch 3: channels.is_temporary lifecycle marker is missing'; end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='channel_settings'
      and column_name='allow_threads'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='channel_settings'
      and column_name='allow_pins'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='channel_settings'
      and column_name='keep_history'
  ) then raise exception 'Batch 3: channel behaviour settings are incomplete'; end if;

  if not has_function_privilege('authenticated','public.channel_poll_feed(uuid)','EXECUTE')
    or has_function_privilege('anon','public.channel_poll_feed(uuid)','EXECUTE')
  then raise exception 'Batch 3: privacy-safe channel poll feed grants are incorrect'; end if;
  select pg_get_function_result(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='channel_poll_feed';
  if v_def is null or position('selected_by_me' in v_def)=0
    or position('user_id' in v_def)>0
  then raise exception 'Batch 3: poll feed exposes voter identity or omits selected_by_me'; end if;

  if not has_function_privilege('authenticated','public.create_event_communication_channels(uuid,text,uuid,uuid,uuid)','EXECUTE')
    or has_function_privilege('anon','public.create_event_communication_channels(uuid,text,uuid,uuid,uuid)','EXECUTE')
  then raise exception 'Batch 3: approved event template RPC grants are incorrect'; end if;
  if not has_function_privilege('authenticated','public.save_event_channel_lifecycle_rule(uuid,text,uuid,text,text,boolean,boolean,boolean)','EXECUTE')
    or has_function_privilege('anon','public.save_event_channel_lifecycle_rule(uuid,text,uuid,text,text,boolean,boolean,boolean)','EXECUTE')
  then raise exception 'Batch 3: lifecycle rule RPC grants are incorrect'; end if;

  if not has_function_privilege('authenticated','public.can_manage_channel_messages(uuid)','EXECUTE')
    or has_function_privilege('anon','public.can_manage_channel_messages(uuid)','EXECUTE')
  then raise exception 'Batch 3: canonical channel moderation permission RPC grants are incorrect'; end if;

  if (
    select count(*) from public.event_channel_templates
    where template_key in ('match_room','stage_briefing','group_coordination','results_disputes')
      and enabled
  ) <> 4 then raise exception 'Batch 3: approved event communication templates are incomplete'; end if;

  if not exists (
    select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='events'
      and t.tgname='events_batch3_channel_lifecycle' and not t.tgisinternal
  ) or not exists (
    select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='event_rounds'
      and t.tgname='event_rounds_batch3_channel_lifecycle' and not t.tgisinternal
  ) or not exists (
    select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='matches'
      and t.tgname ilike '%archive%channel%' and not t.tgisinternal
  ) then raise exception 'Batch 3: event/stage/match channel lifecycle triggers are incomplete'; end if;

  select coalesce(with_check,'') into v_policy from pg_policies
    where schemaname='public' and tablename='scheduled_channel_announcements'
      and policyname='scheduled_announcements_create';
  if v_policy is null or position('can_manage_channel_messages' in v_policy)=0
  then raise exception 'Batch 3: scheduled announcement creation does not use canonical channel moderation'; end if;

  select coalesce(qual,'') into v_policy from pg_policies
    where schemaname='storage' and tablename='objects'
      and policyname='community_media_read_member';
  if v_policy is null or position('can_view_channel_resource' in v_policy)=0
  then raise exception 'Batch 3: community media storage reads are not event/channel scoped'; end if;

  if to_regclass('cron.job') is not null and not exists (
    select 1 from cron.job where jobname='komnivo-batch3-announcements' and active
  ) then raise exception 'Batch 3: scheduled announcement cron job is not active'; end if;
end;
$test$;
select extensions.ok(true,'Batch 3 channel, forum, poll and scheduling database contracts hold');
select * from extensions.finish();
rollback;
