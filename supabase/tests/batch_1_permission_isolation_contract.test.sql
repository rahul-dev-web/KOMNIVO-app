-- Batch 1 permission/data-isolation contract checks.
-- Run with: supabase test db
-- These catalog checks complement (but do not replace) authenticated multi-user RLS tests.

begin;

do $test$
declare
  v_table text;
  v_policy text;
  v_definition text;
begin
  foreach v_table in array array[
    'matches','match_participants','match_checkins','room_credentials',
    'match_results','result_evidence','result_disputes',
    'liveops_sessions','liveops_captures','channels','channel_categories',
    'channel_permission_overrides','category_permission_overrides',
    'event_staff_assignments','audit_logs'
  ] loop
    if not exists (
      select 1
      from pg_class c
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname=v_table and c.relrowsecurity
    ) then
      raise exception 'Batch 1 failed: RLS is not enabled on public.%', v_table;
    end if;
  end loop;

  if not has_function_privilege('authenticated','public.has_permission(text,text,uuid,uuid,uuid)','EXECUTE') then
    raise exception 'Batch 1 failed: authenticated users cannot call the permission preview RPC';
  end if;
  if has_function_privilege('anon','public.has_permission(text,text,uuid,uuid,uuid)','EXECUTE') then
    raise exception 'Batch 1 failed: anon can call the permission preview RPC';
  end if;
  if has_function_privilege('anon','app_private.resolve_permission(text,text,uuid,uuid,uuid)','EXECUTE') then
    raise exception 'Batch 1 failed: anon can execute the private permission resolver';
  end if;

  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='app_private'
      and p.proname='resolve_permission'
      and p.prosecdef
  ) then
    raise exception 'Batch 1 failed: canonical resolver must be SECURITY DEFINER';
  end if;

  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app_private' and p.proname='resolve_permission';
  if v_definition is null
     or position('category_permission_overrides' in v_definition)=0
     or position('channel_permission_overrides' in v_definition)=0 then
    raise exception 'Batch 1 failed: resolver does not enforce channel > category permission inheritance';
  end if;

  if not exists (
    select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='category_permission_overrides'
      and t.tgname='category_permission_overrides_authority_guard' and not t.tgisinternal
  ) then
    raise exception 'Batch 1 failed: category override delegation guard is missing';
  end if;

  if (
    select count(*) from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and not t.tgisinternal
      and t.tgname in (
        'audit_matches_change','audit_match_participants_change','audit_match_checkins_change',
        'audit_room_credentials_change','audit_match_results_change','audit_result_evidence_change',
        'audit_result_disputes_change','audit_liveops_captures_change'
      )
  ) <> 8 then
    raise exception 'Batch 1 failed: sensitive match/LiveOps audit trigger coverage is incomplete';
  end if;

  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app_private' and p.proname='audit_sensitive_change';
  if v_definition is null
     or position('room_password_present' in v_definition)=0
     or position('storage_object_present' in v_definition)=0
     or position('v_old->''room_password''' in v_definition)>0 then
    raise exception 'Batch 1 failed: secret-safe audit snapshot rules are missing';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='audit_logs'
      and cmd in ('UPDATE','DELETE','ALL')
  ) then
    raise exception 'Batch 1 failed: audit_logs has a mutating RLS policy';
  end if;
  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='audit_logs'
      and t.tgname='audit_logs_no_update_delete' and not t.tgisinternal
  ) then
    raise exception 'Batch 1 failed: append-only audit mutation guard is missing';
  end if;

  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='app_private' and p.proname='can_access_event_channel_scope';
  if v_definition is null or position('is_private' in v_definition)=0
     or position('can_access_event_group' in v_definition)=0 then
    raise exception 'Batch 1 failed: event-channel scope helper does not enforce private/group boundaries';
  end if;

  select coalesce(qual,'') into v_policy
  from pg_policies
  where schemaname='public' and tablename='channels'
    and policyname='channels_read_member' and cmd='SELECT';
  if v_policy is null or position('can_access_event_channel_scope' in v_policy)=0 then
    raise exception 'Batch 1 failed: channels SELECT policy bypasses canonical event-channel scope';
  end if;

  select coalesce(qual,'') into v_policy
  from pg_policies
  where schemaname='public' and tablename='match_participants'
    and policyname='participants_read_team_or_staff' and cmd='SELECT';
  if v_policy is null or position('participant.view' in v_policy)=0 then
    raise exception 'Batch 1 failed: match participants are not guarded by participant scope';
  end if;

  select coalesce(qual,'') into v_policy
  from pg_policies
  where schemaname='public' and tablename='room_credentials'
    and cmd='SELECT';
  if v_policy is null or position('match.credentials.read' in v_policy)=0
     or position('release_at' in v_policy)=0 then
    raise exception 'Batch 1 failed: room credential reads do not enforce release time and match scope';
  end if;

  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='liveops_captures'
      and t.tgname='liveops_captures_scope_guard' and not t.tgisinternal
  ) then
    raise exception 'Batch 1 failed: LiveOps capture identity/scope guard is missing';
  end if;

  if app_private.resolve_permission(
    'match.operate','match','00000000-0000-0000-0000-000000000001'::uuid,null,null
  ) then
    raise exception 'Batch 1 failed: resolver must fail closed for an unknown match ID';
  end if;
end;
$test$;

rollback;
