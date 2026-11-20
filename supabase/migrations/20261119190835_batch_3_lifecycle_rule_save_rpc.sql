-- Batch 3: validated upsert API for event channel lifecycle rules.
create unique index if not exists event_channel_lifecycle_event_trigger_uidx
  on public.event_channel_lifecycle_rules(event_id,lifecycle_trigger)
  where scope_type='event' and scope_id is null;

create or replace function public.save_event_channel_lifecycle_rule(
  p_event_id uuid,
  p_scope_type text,
  p_scope_id uuid,
  p_trigger text,
  p_action text,
  p_only_temporary boolean default true,
  p_enabled boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_event public.events%rowtype;
  v_rule_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_scope_type not in ('event','stage','match') then raise exception 'Unsupported lifecycle scope'; end if;
  if p_trigger not in ('started','completed','cancelled') then raise exception 'Invalid lifecycle trigger'; end if;
  if p_action not in ('lock','archive') then raise exception 'Invalid lifecycle action'; end if;
  if (p_scope_type='event') <> (p_scope_id is null) then
    raise exception 'Lifecycle scope ID does not match its scope type';
  end if;
  select * into v_event from public.events where id=p_event_id;
  if not found or v_event.community_id is null then raise exception 'Event not found or not linked to a community'; end if;
  if not (app_private.resolve_permission('event.manage','event',p_event_id,null,null)
    or app_private.resolve_permission('event.matches.operate','event',p_event_id,null,null))
  then raise exception 'You cannot manage this event lifecycle'; end if;

  if p_scope_type='stage' and not exists(
    select 1 from public.event_rounds where id=p_scope_id and event_id=p_event_id
  ) then raise exception 'Stage does not belong to this event'; end if;
  if p_scope_type='match' and not exists(
    select 1 from public.matches where id=p_scope_id and event_id=p_event_id
  ) then raise exception 'Match does not belong to this event'; end if;
  if p_scope_type='stage' and p_trigger='cancelled' then
    raise exception 'Stages do not support a cancelled lifecycle state';
  end if;

  select id into v_rule_id from public.event_channel_lifecycle_rules
  where event_id=p_event_id and scope_type=p_scope_type
    and scope_id is not distinct from p_scope_id
    and lifecycle_trigger=p_trigger
  for update;

  if v_rule_id is null then
    insert into public.event_channel_lifecycle_rules(
      event_id,community_id,scope_type,scope_id,lifecycle_trigger,action,
      only_temporary,enabled,created_by
    ) values (
      p_event_id,v_event.community_id,p_scope_type,p_scope_id,p_trigger,p_action,
      p_only_temporary,p_enabled,auth.uid()
    ) returning id into v_rule_id;
  else
    update public.event_channel_lifecycle_rules set
      action=p_action,only_temporary=p_only_temporary,enabled=p_enabled,updated_at=now()
    where id=v_rule_id;
  end if;
  return v_rule_id;
end;
$function$;
revoke all on function public.save_event_channel_lifecycle_rule(uuid,text,uuid,text,text,boolean,boolean) from public,anon;
grant execute on function public.save_event_channel_lifecycle_rule(uuid,text,uuid,text,text,boolean,boolean) to authenticated;

-- Apply the selected lifecycle action immediately to the exact scope, while the
-- triggers above apply it again when future status transitions occur.
