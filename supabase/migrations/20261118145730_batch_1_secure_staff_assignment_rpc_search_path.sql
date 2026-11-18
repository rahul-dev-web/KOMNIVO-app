-- Restore the event-staff RPCs that were present in the connected project but
-- missing from the tracked migration history. Keep these definitions before the
-- hardening statements below so a fresh database can replay this migration chain.
create or replace function public.assign_scoped_event_staff_by_username(
  p_event_id uuid,
  p_username text,
  p_role_key text,
  p_scope_type text,
  p_stage_id uuid default null,
  p_group_id uuid default null,
  p_match_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user public.profiles%rowtype;
  v_assignment public.event_staff_assignments%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if not app_private.resolve_permission('event.staff.assign','event',p_event_id,null,null) then
    raise exception 'Only an authorised event manager can assign event staff';
  end if;
  if p_role_key is null or p_role_key not in (
    'competition_manager','tournament_director','match_operator',
    'referee','result_reviewer','dispute_reviewer','support_staff','caster','streamer'
  ) then
    raise exception 'Unsupported event staff role';
  end if;
  if char_length(trim(coalesce(p_username,''))) < 2 then
    raise exception 'Enter the KOMNIVO username';
  end if;
  select * into v_user
  from public.profiles
  where lower(username)=lower(trim(p_username))
  limit 1;
  if not found then
    raise exception 'No KOMNIVO account matched that username';
  end if;
  if v_user.id=auth.uid() then
    raise exception 'The event owner already has manager access';
  end if;

  insert into public.event_staff_assignments(
    event_id,user_id,role_key,assigned_by,scope_type,stage_id,group_id,match_id
  ) values (
    p_event_id,v_user.id,p_role_key,auth.uid(),p_scope_type,p_stage_id,p_group_id,p_match_id
  )
  on conflict(event_id,user_id,role_key,scope_type,stage_id,group_id,match_id)
  do update set assigned_by=excluded.assigned_by
  returning * into v_assignment;

  insert into public.audit_logs(actor_id,event_id,entity_type,entity_id,action,metadata)
  values (
    auth.uid(),p_event_id,'event_staff_assignment',v_assignment.id,'event_staff_assigned',
    jsonb_build_object(
      'user_id',v_user.id,'username',v_user.username,'role_key',p_role_key,
      'scope_type',p_scope_type,'stage_id',p_stage_id,'group_id',p_group_id,'match_id',p_match_id
    )
  );
  return jsonb_build_object(
    'assignment_id',v_assignment.id,'user_id',v_user.id,
    'display_name',v_user.display_name,'username',v_user.username,
    'role_key',p_role_key,'scope_type',p_scope_type,
    'stage_id',p_stage_id,'group_id',p_group_id,'match_id',p_match_id
  );
end;
$function$;

create or replace function public.assign_event_staff_by_username(
  p_event_id uuid,
  p_username text,
  p_role_key text
) returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select public.assign_scoped_event_staff_by_username(
    p_event_id,p_username,p_role_key,'event',null,null,null
  );
$function$;

create or replace function public.remove_event_staff_assignment(
  p_assignment_id uuid
) returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_assignment public.event_staff_assignments%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  select * into v_assignment
  from public.event_staff_assignments
  where id=p_assignment_id
  for update;
  if not found then
    return false;
  end if;
  if not app_private.is_event_staff(v_assignment.event_id) then
    raise exception 'Only the event owner or community managers can remove event staff';
  end if;

  delete from public.event_staff_assignments where id=p_assignment_id;
  insert into public.audit_logs(actor_id,event_id,entity_type,entity_id,action,metadata)
  values (
    auth.uid(),v_assignment.event_id,'event_staff_assignment',v_assignment.id,'event_staff_removed',
    jsonb_build_object('user_id',v_assignment.user_id,'role_key',v_assignment.role_key)
  );
  return true;
end;
$function$;

-- Keep intentionally callable event-staff RPCs out of caller-controlled search paths.
-- Their bodies schema-qualify relations/helpers and independently validate auth.uid()
-- plus event.staff.assign / authority-rank rules.
alter function public.assign_event_staff_by_username(uuid,text,text) set search_path = '';
alter function public.assign_scoped_event_staff_by_username(uuid,text,text,text,uuid,uuid,uuid) set search_path = '';
alter function public.remove_event_staff_assignment(uuid) set search_path = '';

revoke all on function public.assign_event_staff_by_username(uuid,text,text) from public,anon;
revoke all on function public.assign_scoped_event_staff_by_username(uuid,text,text,text,uuid,uuid,uuid) from public,anon;
revoke all on function public.remove_event_staff_assignment(uuid) from public,anon;

grant execute on function public.assign_event_staff_by_username(uuid,text,text) to authenticated;
grant execute on function public.assign_scoped_event_staff_by_username(uuid,text,text,text,uuid,uuid,uuid) to authenticated;
grant execute on function public.remove_event_staff_assignment(uuid) to authenticated;
