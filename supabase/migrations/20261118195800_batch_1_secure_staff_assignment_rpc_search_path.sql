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
