-- Batch 4 Checklist 1–2 database contract and privacy regression tests.
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
    'community_onboarding_responses'
  ] loop
    if not exists (
      select 1
      from pg_class c
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public'
        and c.relname=v_table
        and c.relrowsecurity
    ) then
      raise exception 'Batch 4: RLS is not enabled on public.%',v_table;
    end if;
  end loop;

  if has_table_privilege('authenticated','public.community_onboarding_questions','INSERT')
    or has_table_privilege('authenticated','public.community_onboarding_questions','UPDATE')
    or has_table_privilege('authenticated','public.community_onboarding_questions','DELETE')
    or has_table_privilege('authenticated','public.community_onboarding_responses','INSERT')
    or has_table_privilege('authenticated','public.community_onboarding_responses','UPDATE')
    or has_table_privilege('authenticated','public.community_onboarding_responses','DELETE')
  then
    raise exception 'Batch 4: onboarding tables permit direct client writes instead of validated RPCs';
  end if;

  if not has_table_privilege('authenticated','public.community_onboarding_questions','SELECT')
    or not has_table_privilege('authenticated','public.community_onboarding_responses','SELECT')
  then
    raise exception 'Batch 4: authenticated read grants are missing';
  end if;

  if not has_function_privilege('authenticated','public.get_community_member_directory(uuid)','EXECUTE')
    or has_function_privilege('anon','public.get_community_member_directory(uuid)','EXECUTE')
    or not has_function_privilege('authenticated','public.get_community_onboarding_data(uuid)','EXECUTE')
    or has_function_privilege('anon','public.get_community_onboarding_data(uuid)','EXECUTE')
    or not has_function_privilege('authenticated','public.save_community_onboarding_configuration(uuid,jsonb)','EXECUTE')
    or has_function_privilege('anon','public.save_community_onboarding_configuration(uuid,jsonb)','EXECUTE')
    or not has_function_privilege('authenticated','public.submit_community_onboarding_answers(uuid,jsonb)','EXECUTE')
    or has_function_privilege('anon','public.submit_community_onboarding_answers(uuid,jsonb)','EXECUTE')
    or not has_function_privilege('authenticated','public.save_community_channel_onboarding_tags(uuid,uuid,text[],text[])','EXECUTE')
    or has_function_privilege('anon','public.save_community_channel_onboarding_tags(uuid,uuid,text[],text[])','EXECUTE')
    or not has_function_privilege('authenticated','public.get_community_channel_recommendations(uuid)','EXECUTE')
    or has_function_privilege('anon','public.get_community_channel_recommendations(uuid)','EXECUTE')
  then
    raise exception 'Batch 4: public onboarding RPC grants are not restricted to authenticated users';
  end if;

  select p.prosecdef into v_security_definer
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='get_community_member_directory';
  if v_security_definer is distinct from false then
    raise exception 'Batch 4: public directory wrapper must be SECURITY INVOKER';
  end if;

  select p.prosecdef into v_security_definer
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app_private' and p.proname='get_community_member_directory';
  if v_security_definer is distinct from true then
    raise exception 'Batch 4: private directory implementation must be SECURITY DEFINER';
  end if;

  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app_private' and p.proname='get_community_member_directory';
  if v_definition is null
    or position('ownership_status' in v_definition)=0
    or position('ga.uid' in v_definition)>0
    or position('Private member' in v_definition)=0
    or position('community.view' in v_definition)=0
  then
    raise exception 'Batch 4: directory privacy projection or community permission guard is incomplete';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname='public'
      and tablename='community_onboarding_questions'
      and policyname='community_onboarding_questions_read_member'
      and position('is_enabled' in coalesce(qual,''))>0
      and position('is_community_member' in coalesce(qual,''))>0
  ) then
    raise exception 'Batch 4: onboarding question reads are not scoped to community membership and enabled state';
  end if;

  select coalesce(qual,'') into v_policy
  from pg_policies
  where schemaname='public'
    and tablename='community_onboarding_responses'
    and policyname='community_onboarding_responses_read_self';
  if v_policy is null
    or position('auth.uid' in v_policy)=0
    or position('is_community_member' in v_policy)=0
    or position('manage_members' in v_policy)>0
  then
    raise exception 'Batch 4: onboarding answers are not restricted to their owner and community';
  end if;

  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app_private' and p.proname='save_community_onboarding_configuration';
  if v_definition is null
    or position('community.manage_members' in v_definition)=0
    or position('All four supported onboarding question keys' in v_definition)=0
    or position('onboarding.configuration.updated' in v_definition)=0
  then
    raise exception 'Batch 4: onboarding configuration validation, manager permission or audit record is missing';
  end if;

  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app_private' and p.proname='submit_community_onboarding_answers';
  if v_definition is null
    or position('is_community_member' in v_definition)=0
    or position('unsupported choice' in v_definition)=0
    or position('is_required' in v_definition)=0
  then
    raise exception 'Batch 4: onboarding answer validation or membership enforcement is incomplete';
  end if;

  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app_private' and p.proname='save_community_channel_onboarding_tags';
  if v_definition is null
    or position('community.manage_structure' in v_definition)=0
    or position('onboarding_tags.updated' in v_definition)=0
  then
    raise exception 'Batch 4: channel tag write does not enforce structure permission and audit logging';
  end if;

  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app_private' and p.proname='get_community_channel_recommendations';
  if v_definition is null
    or position('channel.view' in v_definition)=0
    or position('community_onboarding_responses' in v_definition)=0
    or position('onboarding_topics' in v_definition)=0
    or position('onboarding_game_modes' in v_definition)=0
  then
    raise exception 'Batch 4: recommendations are not driven by saved answers, channel tags and channel visibility';
  end if;

  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='communities'
      and t.tgname='communities_seed_onboarding_questions'
      and not t.tgisinternal
  ) then
    raise exception 'Batch 4: new communities do not receive their four default onboarding questions';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema='public'
      and table_name='channels'
      and column_name='onboarding_topics'
      and data_type='ARRAY'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema='public'
      and table_name='channels'
      and column_name='onboarding_game_modes'
      and data_type='ARRAY'
  ) then
    raise exception 'Batch 4: channel onboarding tag columns are missing';
  end if;

  foreach v_table in array array[
    'community_onboarding_questions_created_by_idx',
    'community_onboarding_questions_updated_by_idx',
    'community_onboarding_responses_user_id_idx',
    'onboarding_questions_community_order_idx',
    'onboarding_responses_user_community_idx',
    'channels_onboarding_topics_gin',
    'channels_onboarding_game_modes_gin'
  ] loop
    if not exists (
      select 1 from pg_indexes
      where schemaname='public' and indexname=v_table
    ) then
      raise exception 'Batch 4: expected onboarding query index % is missing',v_table;
    end if;
  end loop;
end;
$test$;

select extensions.ok(
  true,
  'Batch 4 Checklist 1–2 directory, onboarding, RLS, RPC and recommendation contracts hold'
);
select * from extensions.finish();
rollback;
