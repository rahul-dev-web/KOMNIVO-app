-- Batch 4 Checklist 1–2 security and persistence contracts.
-- Run with: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(1);

do $test$
declare
  v_table text;
  v_definition text;
  v_policy text;
  v_security_definer boolean;
begin
  foreach v_table in array array[
    'community_onboarding_questions',
    'community_onboarding_responses',
    'community_join_requests',
    'community_moderation_actions',
    'community_member_restrictions',
    'community_moderation_appeals',
    'community_safety_settings'
  ] loop
    if not exists (
      select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname=v_table and c.relrowsecurity
    ) then
      raise exception 'Batch 4: RLS is not enabled on public.%',v_table;
    end if;
  end loop;

  if has_table_privilege('authenticated','public.community_join_requests','INSERT')
    or has_table_privilege('authenticated','public.community_join_requests','UPDATE')
    or has_table_privilege('authenticated','public.community_join_requests','DELETE')
    or has_table_privilege('authenticated','public.community_moderation_actions','INSERT')
    or has_table_privilege('authenticated','public.community_moderation_actions','UPDATE')
    or has_table_privilege('authenticated','public.community_moderation_actions','DELETE')
    or has_table_privilege('authenticated','public.community_member_restrictions','SELECT')
    or has_table_privilege('authenticated','public.community_member_restrictions','INSERT')
    or has_table_privilege('authenticated','public.community_member_restrictions','UPDATE')
    or has_table_privilege('authenticated','public.community_member_restrictions','DELETE')
    or has_table_privilege('authenticated','public.community_moderation_appeals','INSERT')
    or has_table_privilege('authenticated','public.community_moderation_appeals','UPDATE')
    or has_table_privilege('authenticated','public.community_moderation_appeals','DELETE')
    or has_table_privilege('authenticated','public.community_safety_settings','INSERT')
    or has_table_privilege('authenticated','public.community_safety_settings','UPDATE')
    or has_table_privilege('authenticated','public.community_safety_settings','DELETE')
  then
    raise exception 'Batch 4: client roles can directly mutate protected workflow state';
  end if;

  if has_table_privilege('anon','public.community_join_requests','SELECT')
    or has_table_privilege('anon','public.community_moderation_actions','SELECT')
    or has_table_privilege('anon','public.community_moderation_appeals','SELECT')
    or has_table_privilege('anon','public.community_safety_settings','SELECT')
  then
    raise exception 'Batch 4: anonymous users can read restricted workflow data';
  end if;

  if not has_function_privilege('authenticated','public.get_community_member_directory(uuid)','EXECUTE')
    or has_function_privilege('anon','public.get_community_member_directory(uuid)','EXECUTE')
    or not has_function_privilege('authenticated','public.join_community_with_invite(uuid,text,text)','EXECUTE')
    or has_function_privilege('anon','public.join_community_with_invite(uuid,text,text)','EXECUTE')
    or not has_function_privilege('authenticated','public.review_community_join_request(uuid,text,text)','EXECUTE')
    or has_function_privilege('anon','public.review_community_join_request(uuid,text,text)','EXECUTE')
    or not has_function_privilege('authenticated','public.apply_community_moderation_action(uuid,text,uuid,text,integer,uuid,uuid)','EXECUTE')
    or has_function_privilege('anon','public.apply_community_moderation_action(uuid,text,uuid,text,integer,uuid,uuid)','EXECUTE')
    or not has_function_privilege('authenticated','public.submit_community_moderation_appeal(uuid,text,text,text)','EXECUTE')
    or has_function_privilege('anon','public.submit_community_moderation_appeal(uuid,text,text,text)','EXECUTE')
    or not has_function_privilege('authenticated','public.review_community_moderation_appeal(uuid,text,text,integer)','EXECUTE')
    or has_function_privilege('anon','public.review_community_moderation_appeal(uuid,text,text,integer)','EXECUTE')
    or not has_function_privilege('authenticated','public.review_community_moderation_report(uuid,text,text)','EXECUTE')
    or has_function_privilege('anon','public.review_community_moderation_report(uuid,text,text)','EXECUTE')
    or not has_function_privilege('authenticated','public.save_community_safety_settings(uuid,integer,integer,integer,integer,boolean,integer,boolean,integer,integer,integer,text)','EXECUTE')
    or has_function_privilege('anon','public.save_community_safety_settings(uuid,integer,integer,integer,integer,boolean,integer,boolean,integer,integer,integer,text)','EXECUTE')
  then
    raise exception 'Batch 4: one or more workflow RPC grants are missing or over-broad';
  end if;

  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app_private' and p.proname='resolve_permission';
  if v_definition is null
    or position('community_member_restrictions' in v_definition)=0
    or position('restriction_type' in v_definition)=0
  then
    raise exception 'Batch 4: active bans do not deny canonical community permissions';
  end if;

  select coalesce(with_check,'') into v_policy
  from pg_policies where schemaname='public' and tablename='community_members'
    and policyname='community_members_join_self';
  if v_policy is null
    or position('join_approval_required' in v_policy)=0
    or position('community_member_restrictions' in v_policy)=0
  then
    raise exception 'Batch 4: direct public self-join does not enforce approval and ban policy';
  end if;

  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app_private' and p.proname='join_community_with_invite';
  if v_definition is null
    or position('revoked_at' in v_definition)=0
    or position('expires_at' in v_definition)=0
    or position('max_uses' in v_definition)=0
    or position('pending_approval' in v_definition)=0
  then
    raise exception 'Batch 4: join flow does not enforce invite lifecycle and approval routing';
  end if;

  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='apply_community_moderation_action';
  if v_definition is null
    or position('community.manage_members' in v_definition)=0
    or position('duration_minutes' in v_definition)=0
    or position('community_member_restrictions' in v_definition)=0
    or position('moderation.' in v_definition)=0
  then
    raise exception 'Batch 4: moderation actions are missing scoped permission, restrictions or audit';
  end if;

  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app_private' and p.proname='guard_batch4_member_restrictions';
  if v_definition is null
    or position('message_window_seconds' in v_definition)=0
    or position('mention_window_seconds' in v_definition)=0
    or position('restrict_links_for_new_members' in v_definition)=0
    or position('lockdown_until' in v_definition)=0
  then
    raise exception 'Batch 4: message/mention rate, link and lockdown enforcement trigger is incomplete';
  end if;

  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='messages'
      and t.tgname='messages_batch4_member_restrictions' and not t.tgisinternal
  ) or not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='community_members'
      and t.tgname='community_members_batch4_raid_detection' and not t.tgisinternal
  ) then
    raise exception 'Batch 4: enforcement and raid detection triggers are missing';
  end if;

  foreach v_table in array array[
    'community_join_requests_one_pending_idx',
    'community_join_requests_review_queue_idx',
    'community_moderation_actions_target_idx',
    'community_member_restrictions_active_idx',
    'community_moderation_appeals_queue_idx',
    'community_safety_settings_updated_by_idx'
  ] loop
    if not exists(select 1 from pg_indexes where schemaname='public' and indexname=v_table)
    then raise exception 'Batch 4: expected workflow index % is missing',v_table; end if;
  end loop;

  if has_table_privilege('authenticated','public.community_onboarding_responses','INSERT')
    or has_table_privilege('authenticated','public.community_onboarding_responses','UPDATE')
    or has_table_privilege('authenticated','public.community_onboarding_responses','DELETE')
  then raise exception 'Batch 4: onboarding answers can be written outside the validated RPC'; end if;

  select p.prosecdef into v_security_definer
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='get_community_member_directory';
  if v_security_definer is distinct from false then
    raise exception 'Batch 4: public directory wrapper is not SECURITY INVOKER';
  end if;
end;
$test$;

select extensions.ok(
  true,
  'Batch 4 Checklist 1–2 directory, onboarding, invites, moderation and safety contracts hold'
);
select * from extensions.finish();
rollback;
