-- Batch 3: approved event communication templates and configurable channel lifecycle.
alter table public.channels
  add column if not exists is_temporary boolean not null default false;

update public.channels
set is_temporary = true
where event_id is not null and is_temporary = false;

create table if not exists public.event_channel_templates (
  template_key text primary key,
  name text not null,
  scope_type text not null check (scope_type in ('event','stage','group','match')),
  description text not null default '',
  channels jsonb not null check (jsonb_typeof(channels)='array'),
  enabled boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.event_channel_templates enable row level security;
revoke all on public.event_channel_templates from public,anon,authenticated;
grant select on public.event_channel_templates to authenticated;
drop policy if exists event_channel_templates_read on public.event_channel_templates;
create policy event_channel_templates_read on public.event_channel_templates
for select to authenticated using (enabled);

insert into public.event_channel_templates(template_key,name,scope_type,description,channels)
values
('match_room','Match room','match','Private chat and voice for one scheduled match.',
 '[{"name":"match-chat","kind":"text","private":true,"description":"Private coordination for this match."},{"name":"match-voice","kind":"voice","private":true,"description":"Voice room for this match."}]'::jsonb),
('stage_briefing','Stage briefing','stage','Announcements and questions for one event stage.',
 '[{"name":"stage-announcements","kind":"announcement","private":false,"description":"Official updates for this stage."},{"name":"stage-questions","kind":"forum","private":false,"description":"Questions and discussion for this stage."}]'::jsonb),
('group_coordination','Group coordination','group','Reuses the private room automatically created for the selected group.',
 '[{"name":"group-room","kind":"reuse_group_room","private":true,"description":"Existing private communication room for this group."}]'::jsonb),
('results_disputes','Results and disputes','event','Event-wide result updates and authorised dispute help.',
 '[{"name":"results-updates","kind":"announcement","private":false,"description":"Event result and schedule updates. Official results stay in event records."},{"name":"dispute-help","kind":"forum","private":true,"description":"Authorised help for result and dispute workflows."}]'::jsonb)
on conflict(template_key) do update set
  name=excluded.name,scope_type=excluded.scope_type,
  description=excluded.description,channels=excluded.channels,enabled=true;

create table if not exists public.event_communication_instances (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  community_id uuid not null references public.communities(id) on delete cascade,
  template_key text not null references public.event_channel_templates(template_key),
  scope_type text not null check (scope_type in ('event','stage','group','match')),
  scope_id uuid,
  scope_key text not null,
  category_id uuid references public.channel_categories(id) on delete set null,
  channel_ids uuid[] not null default array[]::uuid[],
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  unique(event_id,template_key,scope_key)
);
create index if not exists event_communication_instances_event_idx
  on public.event_communication_instances(event_id,created_at desc);
alter table public.event_communication_instances enable row level security;
revoke all on public.event_communication_instances from public,anon;
grant select on public.event_communication_instances to authenticated;
drop policy if exists event_communication_instances_read on public.event_communication_instances;
create policy event_communication_instances_read on public.event_communication_instances
for select to authenticated
using (app_private.resolve_permission('event.view','event',event_id,null,null)
  or app_private.resolve_permission('event.manage','event',event_id,null,null));

create table if not exists public.event_channel_lifecycle_rules (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  community_id uuid not null references public.communities(id) on delete cascade,
  scope_type text not null check (scope_type in ('event','stage','group','match')),
  scope_id uuid,
  lifecycle_trigger text not null check (lifecycle_trigger in ('started','completed','cancelled')),
  action text not null check (action in ('lock','archive')),
  only_temporary boolean not null default true,
  enabled boolean not null default true,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((scope_type='event' and scope_id is null) or (scope_type<>'event' and scope_id is not null)),
  unique(event_id,scope_type,scope_id,lifecycle_trigger)
);
create index if not exists event_channel_lifecycle_event_idx
  on public.event_channel_lifecycle_rules(event_id,scope_type,lifecycle_trigger) where enabled;
alter table public.event_channel_lifecycle_rules enable row level security;
revoke all on public.event_channel_lifecycle_rules from public,anon;
grant select,insert,update,delete on public.event_channel_lifecycle_rules to authenticated;
drop policy if exists event_channel_lifecycle_read on public.event_channel_lifecycle_rules;
create policy event_channel_lifecycle_read on public.event_channel_lifecycle_rules
for select to authenticated
using (app_private.resolve_permission('event.manage','event',event_id,null,null)
  or app_private.resolve_permission('event.matches.operate','event',event_id,null,null));
drop policy if exists event_channel_lifecycle_manage on public.event_channel_lifecycle_rules;
create policy event_channel_lifecycle_manage on public.event_channel_lifecycle_rules
for all to authenticated
using (app_private.resolve_permission('event.manage','event',event_id,null,null)
  or app_private.resolve_permission('event.matches.operate','event',event_id,null,null))
with check (
  created_by=auth.uid()
  and (app_private.resolve_permission('event.manage','event',event_id,null,null)
    or app_private.resolve_permission('event.matches.operate','event',event_id,null,null))
  and exists(select 1 from public.events e where e.id=event_id and e.community_id=community_id)
);

create or replace function public.create_event_communication_channels(
  p_event_id uuid,
  p_template_key text,
  p_stage_id uuid default null,
  p_group_id uuid default null,
  p_match_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_event public.events%rowtype;
  v_template public.event_channel_templates%rowtype;
  v_scope_id uuid;
  v_scope_key text;
  v_instance public.event_communication_instances%rowtype;
  v_instance_id uuid;
  v_category_id uuid;
  v_category_name text;
  v_scope_label text;
  v_channel_ids uuid[] := array[]::uuid[];
  v_channel jsonb;
  v_channel_id uuid;
  v_base_name text;
  v_channel_name text;
  v_kind text;
  v_private boolean;
  v_description text;
  v_suffix text;
  v_match public.matches%rowtype;
  v_round public.event_rounds%rowtype;
  v_group public.event_groups%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_event from public.events where id=p_event_id;
  if not found or v_event.community_id is null then
    raise exception 'This event is not linked to a community';
  end if;
  if not (
    app_private.resolve_permission('event.manage','event',p_event_id,null,null)
    or app_private.resolve_permission('event.matches.operate','event',p_event_id,null,null)
  ) then raise exception 'You cannot create event communication channels'; end if;

  select * into v_template from public.event_channel_templates
  where template_key=p_template_key and enabled;
  if not found then raise exception 'Approved event channel template not found'; end if;

  if v_template.scope_type='event' then
    if p_stage_id is not null or p_group_id is not null or p_match_id is not null
    then raise exception 'Event templates cannot target a stage, group or match'; end if;
    v_scope_id := null;
    v_scope_label := 'event';
    v_scope_key := 'event';
  elsif v_template.scope_type='stage' then
    if p_stage_id is null or p_group_id is not null or p_match_id is not null
    then raise exception 'Select exactly one stage for this template'; end if;
    select * into v_round from public.event_rounds where id=p_stage_id and event_id=p_event_id;
    if not found or v_round.status in ('completed') then raise exception 'Stage is unavailable or completed'; end if;
    v_scope_id := p_stage_id;
    v_scope_label := v_round.name;
    v_scope_key := 'stage:' || p_stage_id::text;
  elsif v_template.scope_type='group' then
    if p_group_id is null or p_match_id is not null
    then raise exception 'Select a group for this template'; end if;
    select g.* into v_group
    from public.event_groups g
    join public.event_rounds r on r.id=g.round_id
    where g.id=p_group_id and r.event_id=p_event_id
      and (p_stage_id is null or r.id=p_stage_id);
    if not found then raise exception 'Group does not belong to this event'; end if;
    v_scope_id := p_group_id;
    v_scope_label := v_group.label;
    v_scope_key := 'group:' || p_group_id::text;
  else
    if p_match_id is null then raise exception 'Select a match for this template'; end if;
    select * into v_match from public.matches
    where id=p_match_id and event_id=p_event_id;
    if not found or v_match.status in ('completed','cancelled') then
      raise exception 'Match is unavailable or already finished';
    end if;
    if p_stage_id is not null and p_stage_id is distinct from v_match.stage_id then
      raise exception 'Selected stage does not match the selected match';
    end if;
    if p_group_id is not null and p_group_id is distinct from v_match.group_id then
      raise exception 'Selected group does not match the selected match';
    end if;
    v_scope_id := p_match_id;
    v_scope_label := coalesce(v_match.match_code,'Match '||v_match.match_number::text);
    v_scope_key := 'match:' || p_match_id::text;
    p_stage_id := v_match.stage_id;
    p_group_id := v_match.group_id;
  end if;

  insert into public.event_communication_instances(
    event_id,community_id,template_key,scope_type,scope_id,scope_key,created_by
  ) values (
    p_event_id,v_event.community_id,p_template_key,v_template.scope_type,v_scope_id,v_scope_key,auth.uid()
  )
  on conflict(event_id,template_key,scope_key) do nothing
  returning id into v_instance_id;

  if v_instance_id is null then
    select * into v_instance from public.event_communication_instances
    where event_id=p_event_id and template_key=p_template_key and scope_key=v_scope_key;
    return jsonb_build_object(
      'created',false,'instance_id',v_instance.id,'category_id',v_instance.category_id,
      'channel_ids',to_jsonb(v_instance.channel_ids),'template_key',p_template_key
    );
  end if;

  if v_template.scope_type='group' then
    select id into v_category_id from public.channel_categories
    where event_id=p_event_id and group_id=p_group_id;
  elsif v_template.scope_type='match' then
    select id into v_category_id from public.channel_categories
    where event_id=p_event_id and group_id=p_group_id;
  else
    v_suffix := right(replace(v_scope_key,':',''),8);
    v_category_name := left(v_event.name,18)||' · '||left(v_template.name,18)||' · '||v_suffix;
    insert into public.channel_categories(
      community_id,name,description,position,created_by,event_id,stage_id,group_id
    ) values (
      v_event.community_id,left(v_category_name,60),
      'Approved communication template: '||v_template.name,
      900000 + (abs(hashtext(v_scope_key)) % 90000),
      auth.uid(),p_event_id,
      case when v_template.scope_type='stage' then p_stage_id else null end,
      null
    )
    returning id into v_category_id;
  end if;

  if v_template.scope_type='group' then
    -- The tournament channel-creation trigger already created the private group room.
    -- Reuse it; do not create a second group room or alter match participation.
    select id into v_channel_id from public.channels
    where event_id=p_event_id and group_id=p_group_id and match_id is null
      and archived_at is null order by created_at limit 1;
    if v_channel_id is null then raise exception 'The selected group has no active communication room'; end if;
    v_channel_ids := array[v_channel_id];
  else
    for v_channel in select value from jsonb_array_elements(v_template.channels)
    loop
      v_base_name := lower(regexp_replace(v_channel->>'name','[^a-zA-Z0-9-]+','-','g'));
      v_suffix := right(replace(v_scope_key,':',''),8);
      v_channel_name := left(v_base_name,35)||'-'||v_suffix;
      v_kind := v_channel->>'kind';
      v_private := coalesce((v_channel->>'private')::boolean,false);
      v_description := coalesce(v_channel->>'description','Event communication only.');
      insert into public.channels(
        community_id,name,description,kind,is_private,created_by,category_id,
        event_id,stage_id,group_id,match_id,is_temporary
      ) values (
        v_event.community_id,v_channel_name,v_description,v_kind,v_private,auth.uid(),
        v_category_id,p_event_id,
        case when v_template.scope_type='stage' then p_stage_id else p_stage_id end,
        case when v_template.scope_type='match' then p_group_id else null end,
        case when v_template.scope_type='match' then p_match_id else null end,
        true
      )
      returning id into v_channel_id;
      v_channel_ids := array_append(v_channel_ids,v_channel_id);

      if v_kind='announcement' then
        insert into public.channel_settings(
          channel_id,community_id,read_only,announcement_publishers_only,
          allow_everyone_mention,allow_role_mentions,allow_user_mentions,updated_by
        ) values (
          v_channel_id,v_event.community_id,true,true,false,false,false,auth.uid()
        );
      end if;
    end loop;
  end if;

  update public.event_communication_instances
    set category_id=v_category_id,channel_ids=v_channel_ids
  where id=v_instance_id;

  return jsonb_build_object(
    'created',true,'instance_id',v_instance_id,'category_id',v_category_id,
    'channel_ids',to_jsonb(v_channel_ids),'template_key',p_template_key
  );
end;
$function$;
revoke all on function public.create_event_communication_channels(uuid,text,uuid,uuid,uuid) from public,anon;
grant execute on function public.create_event_communication_channels(uuid,text,uuid,uuid,uuid) to authenticated;

create or replace function app_private.apply_event_channel_lifecycle(
  p_event_id uuid,p_scope_type text,p_scope_id uuid,p_trigger text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare v_rule public.event_channel_lifecycle_rules%rowtype; v_count integer := 0;
begin
  for v_rule in
    select * from public.event_channel_lifecycle_rules
    where event_id=p_event_id and scope_type=p_scope_type
      and scope_id is not distinct from p_scope_id
      and lifecycle_trigger=p_trigger and enabled
  loop
    if v_rule.only_temporary then
      if v_rule.action='archive' then
        update public.channels set archived_at=coalesce(archived_at,now())
        where event_id=p_event_id and is_temporary
          and (case p_scope_type
            when 'stage' then stage_id=p_scope_id
            when 'group' then group_id=p_scope_id
            when 'match' then match_id=p_scope_id
            else true end);
      else
        insert into public.channel_settings(channel_id,community_id,read_only)
        select c.id,c.community_id,true from public.channels c
        where c.event_id=p_event_id and c.is_temporary
          and (case p_scope_type
            when 'stage' then c.stage_id=p_scope_id
            when 'group' then c.group_id=p_scope_id
            when 'match' then c.match_id=p_scope_id
            else true end)
        on conflict(channel_id) do update set read_only=true,updated_at=now();
      end if;
    else
      if v_rule.action='archive' then
        update public.channels set archived_at=coalesce(archived_at,now())
        where event_id=p_event_id
          and (case p_scope_type
            when 'stage' then stage_id=p_scope_id
            when 'group' then group_id=p_scope_id
            when 'match' then match_id=p_scope_id
            else true end);
      else
        insert into public.channel_settings(channel_id,community_id,read_only)
        select c.id,c.community_id,true from public.channels c
        where c.event_id=p_event_id
          and (case p_scope_type
            when 'stage' then c.stage_id=p_scope_id
            when 'group' then c.group_id=p_scope_id
            when 'match' then c.match_id=p_scope_id
            else true end)
        on conflict(channel_id) do update set read_only=true,updated_at=now();
      end if;
    end if;
    get diagnostics v_count = row_count;
  end loop;
  return v_count;
end;
$function$;
revoke all on function app_private.apply_event_channel_lifecycle(uuid,text,uuid,text) from public,anon,authenticated;

create or replace function app_private.apply_event_status_lifecycle()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_trigger text;
begin
  if new.status is not distinct from old.status then return new; end if;
  v_trigger := case
    when new.status='live' then 'started'
    when new.status='completed' then 'completed'
    when new.status='cancelled' then 'cancelled'
    else null end;
  if v_trigger is not null then
    perform app_private.apply_event_channel_lifecycle(new.id,'event',null,v_trigger);
  end if;
  if old.status in ('completed','cancelled') and new.status not in ('completed','cancelled') then
    update public.channels set archived_at=null where event_id=new.id and is_temporary;
    update public.channel_settings cs set read_only=false,updated_at=now()
    from public.channels c where c.id=cs.channel_id and c.event_id=new.id and c.is_temporary;
  end if;
  return new;
end;
$function$;
revoke all on function app_private.apply_event_status_lifecycle() from public,anon,authenticated;
drop trigger if exists events_batch3_channel_lifecycle on public.events;
create trigger events_batch3_channel_lifecycle after update of status on public.events
for each row execute function app_private.apply_event_status_lifecycle();

create or replace function app_private.apply_stage_status_lifecycle()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_trigger text; v_event_id uuid;
begin
  if new.status is not distinct from old.status then return new; end if;
  v_trigger := case when new.status='live' then 'started' when new.status='completed' then 'completed' else null end;
  select event_id into v_event_id from public.event_rounds where id=new.id;
  if v_trigger is not null then perform app_private.apply_event_channel_lifecycle(v_event_id,'stage',new.id,v_trigger); end if;
  if old.status='completed' and new.status<>'completed' then
    update public.channels set archived_at=null where stage_id=new.id and is_temporary;
    update public.channel_settings cs set read_only=false,updated_at=now()
    from public.channels c where c.id=cs.channel_id and c.stage_id=new.id and c.is_temporary;
  end if;
  return new;
end;
$function$;
revoke all on function app_private.apply_stage_status_lifecycle() from public,anon,authenticated;
drop trigger if exists event_rounds_batch3_channel_lifecycle on public.event_rounds;
create trigger event_rounds_batch3_channel_lifecycle after update of status on public.event_rounds
for each row execute function app_private.apply_stage_status_lifecycle();

create or replace function app_private.archive_event_match_channels()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  if new.status in ('completed','cancelled') and old.status is distinct from new.status then
    if not exists(
      select 1 from public.event_channel_lifecycle_rules r
      where r.event_id=new.event_id and r.scope_type='match'
        and r.scope_id=new.id and r.lifecycle_trigger=case when new.status='completed' then 'completed' else 'cancelled' end
        and r.enabled
    ) then
      -- Preserve the existing safe default for per-match rooms when no rule has been configured.
      update public.channels set archived_at=coalesce(archived_at,now())
      where match_id=new.id and is_temporary;
    else
      perform app_private.apply_event_channel_lifecycle(new.event_id,'match',new.id,
        case when new.status='completed' then 'completed' else 'cancelled' end);
    end if;
  elsif old.status in ('completed','cancelled') and new.status not in ('completed','cancelled') then
    update public.channels set archived_at=null where match_id=new.id and is_temporary;
    update public.channel_settings cs set read_only=false,updated_at=now()
    from public.channels c where c.id=cs.channel_id and c.match_id=new.id and c.is_temporary;
  elsif old.status is distinct from new.status and new.status='live' then
    perform app_private.apply_event_channel_lifecycle(new.event_id,'match',new.id,'started');
  end if;
  return new;
end;
$function$;
