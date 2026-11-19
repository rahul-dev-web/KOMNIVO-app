-- Batch 3: lifecycle notifications are stored and delivered to affected channel members.
alter table public.event_channel_lifecycle_rules
  add column if not exists notify_affected boolean not null default true;

drop function if exists public.save_event_channel_lifecycle_rule(uuid,text,uuid,text,text,boolean,boolean);

create or replace function public.save_event_channel_lifecycle_rule(
  p_event_id uuid,
  p_scope_type text,
  p_scope_id uuid,
  p_trigger text,
  p_action text,
  p_only_temporary boolean default true,
  p_enabled boolean default true,
  p_notify_affected boolean default true
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
      only_temporary,enabled,notify_affected,created_by
    ) values (
      p_event_id,v_event.community_id,p_scope_type,p_scope_id,p_trigger,p_action,
      p_only_temporary,p_enabled,p_notify_affected,auth.uid()
    ) returning id into v_rule_id;
  else
    update public.event_channel_lifecycle_rules set
      action=p_action,only_temporary=p_only_temporary,enabled=p_enabled,
      notify_affected=p_notify_affected,updated_at=now()
    where id=v_rule_id;
  end if;
  return v_rule_id;
end;
$function$;
revoke all on function public.save_event_channel_lifecycle_rule(uuid,text,uuid,text,text,boolean,boolean,boolean) from public,anon;
grant execute on function public.save_event_channel_lifecycle_rule(uuid,text,uuid,text,text,boolean,boolean,boolean) to authenticated;

create or replace function app_private.apply_event_channel_lifecycle(
  p_event_id uuid,p_scope_type text,p_scope_id uuid,p_trigger text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_rule public.event_channel_lifecycle_rules%rowtype;
  v_rows integer;
  v_affected integer := 0;
begin
  for v_rule in
    select * from public.event_channel_lifecycle_rules
    where event_id=p_event_id and scope_type=p_scope_type
      and scope_id is not distinct from p_scope_id
      and lifecycle_trigger=p_trigger and enabled
  loop
    if v_rule.action='archive' then
      update public.channels set archived_at=coalesce(archived_at,now())
      where event_id=p_event_id
        and (not v_rule.only_temporary or is_temporary)
        and (case p_scope_type
          when 'stage' then stage_id=p_scope_id
          when 'group' then group_id=p_scope_id
          when 'match' then match_id=p_scope_id
          else true end);
    else
      insert into public.channel_settings(channel_id,community_id,read_only)
      select c.id,c.community_id,true from public.channels c
      where c.event_id=p_event_id
        and (not v_rule.only_temporary or c.is_temporary)
        and (case p_scope_type
          when 'stage' then c.stage_id=p_scope_id
          when 'group' then c.group_id=p_scope_id
          when 'match' then c.match_id=p_scope_id
          else true end)
      on conflict(channel_id) do update set read_only=true,updated_at=now();
    end if;
    get diagnostics v_rows = row_count;
    v_affected := v_affected + v_rows;

    if v_rule.notify_affected then
      insert into public.notifications(user_id,title,body,kind,entity_type,entity_id)
      select distinct
        cm.user_id,
        'Event communication access updated',
        'A '||p_scope_type||' communication channel was '||
          case when v_rule.action='archive' then 'archived' else 'locked for new messages' end||
          ' after the configured '||p_trigger||' lifecycle step. Official event records were preserved.',
        'event',
        'event',
        p_event_id
      from public.channels c
      join public.channel_members cm on cm.channel_id=c.id
      where c.event_id=p_event_id
        and (not v_rule.only_temporary or c.is_temporary)
        and (case p_scope_type
          when 'stage' then c.stage_id=p_scope_id
          when 'group' then c.group_id=p_scope_id
          when 'match' then c.match_id=p_scope_id
          else true end);
    end if;
  end loop;
  return v_affected;
end;
$function$;
revoke all on function app_private.apply_event_channel_lifecycle(uuid,text,uuid,text) from public,anon,authenticated;
