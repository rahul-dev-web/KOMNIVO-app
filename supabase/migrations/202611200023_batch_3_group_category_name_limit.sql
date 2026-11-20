-- Keep auto-generated group category labels inside channel_categories.name (2..60 chars).
create or replace function app_private.create_event_match_channel()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_community_id uuid;
  v_event_name text;
  v_stage_name text;
  v_group_label text;
  v_category_id uuid;
  v_channel_id uuid;
begin
  if new.stage_id is null or new.group_id is null then return new; end if;

  select e.community_id,e.name,r.name,g.label
    into v_community_id,v_event_name,v_stage_name,v_group_label
  from public.events e
  join public.event_rounds r on r.id=new.stage_id and r.event_id=e.id
  join public.event_groups g on g.id=new.group_id and g.round_id=r.id
  where e.id=new.event_id;
  if not found then raise exception 'Match stage/group does not belong to the selected event'; end if;
  if v_community_id is null then return new; end if;

  insert into public.channel_categories(
    community_id,name,description,position,created_by,event_id,stage_id,group_id
  ) values (
    v_community_id,
    left(left(v_event_name,18)||' · '||left(v_stage_name,12)||' · '||left(v_group_label,20),60),
    'Automatically managed private group room for '||v_stage_name||' / '||v_group_label,
    new.round_number*1000+coalesce((select eg.sort_order from public.event_groups eg where eg.id=new.group_id),0),
    coalesce(new.host_user_id,(select e.organizer_id from public.events e where e.id=new.event_id)),
    new.event_id,new.stage_id,new.group_id
  )
  on conflict (group_id) where group_id is not null do nothing;

  select cc.id into v_category_id from public.channel_categories cc where cc.group_id=new.group_id;
  insert into public.channels(
    community_id,name,description,kind,is_private,created_by,category_id,
    event_id,stage_id,group_id,match_id,is_temporary
  ) values (
    v_community_id,
    lower(regexp_replace(v_group_label||'-match-room','[^a-zA-Z0-9-]+','-','g')),
    'Private group room for '||v_stage_name||' / '||v_group_label||'. Individual map results are tracked as separate match records.',
    'match',true,
    coalesce(new.host_user_id,(select e.organizer_id from public.events e where e.id=new.event_id)),
    v_category_id,new.event_id,new.stage_id,new.group_id,null,true
  )
  on conflict (group_id) where group_id is not null and match_id is null do nothing;

  select c.id into v_channel_id from public.channels c
  where c.group_id=new.group_id and c.match_id is null;

  insert into public.channel_members(channel_id,user_id)
  select v_channel_id,rp.user_id
  from public.match_participants mp
  join public.registration_players rp on rp.registration_id=mp.registration_id
  where mp.match_id=new.id and v_channel_id is not null
  on conflict do nothing;
  return new;
end;
$function$;
revoke all on function app_private.create_event_match_channel() from public,anon,authenticated;
drop trigger if exists create_event_match_channel on public.matches;
create trigger create_event_match_channel after insert on public.matches
for each row execute function app_private.create_event_match_channel();
