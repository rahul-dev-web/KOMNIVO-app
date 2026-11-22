-- Phase 4 security guard: the lower-level stage advancement RPC must use
-- the published source and target roadmap even when called directly.
CREATE OR REPLACE FUNCTION app_private.advance_event_stage(p_source_stage_id uuid, p_target_stage_name text, p_target_stage_type text, p_target_group_size integer, p_qualify_per_group integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_source public.event_rounds%rowtype;
  v_source_plan jsonb;
  v_target_plan jsonb;
  v_direct_entry_count integer := 0;
  v_target_id uuid;
  v_target_round integer;
  v_team_count integer;
  v_group_count integer;
  v_group record;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_source from public.event_rounds where id = p_source_stage_id for update;
  if not found then raise exception 'Source stage not found'; end if;
  if not app_private.is_event_staff(v_source.event_id) then
    raise exception 'Only event staff can advance a stage';
  end if;

  v_target_round := v_source.round_number + 1;
  select configuration into v_source_plan
  from public.event_stage_roadmaps
  where event_id=v_source.event_id and round_number=v_source.round_number and published_at is not null;
  select configuration into v_target_plan
  from public.event_stage_roadmaps
  where event_id=v_source.event_id and round_number=v_target_round and published_at is not null;
  if v_source_plan is null or v_target_plan is null
     or (select roadmap_published_at from public.events where id=v_source.event_id) is null then
    raise exception 'The complete target-stage roadmap must be published before qualification';
  end if;

  p_qualify_per_group := (v_source_plan->>'qualifiers_per_group')::integer;
  p_target_group_size := (v_target_plan->>'group_size')::integer;
  p_target_stage_name := v_target_plan->>'stage_name';
  p_target_stage_type := v_target_plan->>'stage_type';
  select count(*)::integer into v_direct_entry_count
  from public.event_stage_direct_invites
  where event_id=v_source.event_id and target_round_number=v_target_round;
  if p_target_stage_name is null or char_length(trim(p_target_stage_name)) < 2
     or char_length(trim(p_target_stage_name)) > 80 then
    raise exception 'Target stage name must be between 2 and 80 characters';
  end if;
  if p_target_stage_type not in ('qualifier','quarter_final','semi_final','final','grand_final','custom') then
    raise exception 'Invalid target stage type';
  end if;
  if p_target_group_size < 2 or p_target_group_size > 24 then
    raise exception 'Target group size must be between 2 and 24';
  end if;
  if p_qualify_per_group < 1 or p_qualify_per_group > 24 then
    raise exception 'Qualifying teams per group must be between 1 and 24';
  end if;
  if not exists (select 1 from public.matches where stage_id = p_source_stage_id) then
    raise exception 'The source stage has no generated matches';
  end if;

  if exists (
    select 1
    from public.matches m
    join public.match_participants mp on mp.match_id = m.id
    left join public.match_results mr
      on mr.match_id = m.id
     and mr.team_id = mp.team_id
     and mr.status = 'approved'
    where m.stage_id = p_source_stage_id
      and m.status <> 'cancelled'
      and mr.id is null
  ) then
    raise exception 'Every participating team needs an organiser-approved result before stage advancement';
  end if;

  -- Refresh before qualification so the ranking reflects the latest approvals.
  perform app_private.refresh_event_stage_standings(p_source_stage_id);

  with ranked as (
    select
      s.team_id,
      s.group_id,
      s.group_rank
    from public.event_stage_standings s
    where s.stage_id = p_source_stage_id
      and s.group_rank <= p_qualify_per_group
  )
  select count(*) into v_team_count from ranked;

  if coalesce(v_team_count, 0) + coalesce(v_direct_entry_count,0) < 2 then
    raise exception 'Fewer than two teams are available from approved qualifiers plus direct-entry teams.';
  end if;
  select id into v_target_id
  from public.event_rounds
  where event_id = v_source.event_id
    and round_number = v_target_round
  for update;

  if v_target_id is not null and exists (
    select 1 from public.matches where stage_id = v_target_id
  ) then
    raise exception 'The next stage already has matches; it cannot be regenerated';
  end if;

  if v_target_id is null then
    insert into public.event_rounds (
      event_id, round_number, name, status, stage_type,
      group_size, matches_per_group, advancement_rules,
      room_release_minutes_before
    ) values (
      v_source.event_id, v_target_round, trim(p_target_stage_name), 'draft',
      p_target_stage_type, p_target_group_size, 6,
      jsonb_build_object('mode','top_per_group','qualify_count',p_qualify_per_group),
      v_source.room_release_minutes_before
    )
    returning id into v_target_id;
  else
    delete from public.event_groups where round_id = v_target_id;
    update public.event_rounds
    set name = trim(p_target_stage_name),
        stage_type = p_target_stage_type,
        group_size = p_target_group_size,
        matches_per_group = 6,
        advancement_rules = jsonb_build_object('mode','top_per_group','qualify_count',p_qualify_per_group),
        status = 'draft'
    where id = v_target_id;
  end if;

  v_group_count := ceil(v_team_count::numeric / p_target_group_size)::integer;

  insert into public.event_groups(round_id,label,sort_order)
  select v_target_id, 'Group ' || n, n
  from generate_series(1,v_group_count) n;

  with selected as (
    select
      s.team_id,
      s.group_rank,
      g.sort_order as source_group_order,
      row_number() over (
        order by g.sort_order, s.group_rank, s.points desc, s.kills desc, s.first_places desc
      )::integer as seed_index
    from public.event_stage_standings s
    join public.event_groups g on g.id = s.group_id
    where s.stage_id = p_source_stage_id
      and s.group_rank <= p_qualify_per_group
  ),
  balanced as (
    select
      team_id,
      case
        when (floor((seed_index - 1)::numeric / v_group_count)::integer % 2) = 0
          then mod(seed_index - 1, v_group_count) + 1
        else v_group_count - mod(seed_index - 1, v_group_count)
      end as target_group_order
    from selected
  )
  insert into public.event_group_teams(group_id,team_id,seeded_by)
  select target_group.id, balanced.team_id, auth.uid()
  from balanced
  join public.event_groups target_group
    on target_group.round_id = v_target_id
   and target_group.sort_order = balanced.target_group_order;

  update public.event_stage_standings s
  set qualified = (s.group_rank <= p_qualify_per_group),
      qualified_at = case when s.group_rank <= p_qualify_per_group then now() else null end,
      updated_at = now()
  where s.stage_id = p_source_stage_id;

  update public.event_rounds set status = 'completed' where id = p_source_stage_id;

  insert into public.audit_logs(actor_id,event_id,entity_type,entity_id,action,metadata)
  values (
    auth.uid(), v_source.event_id, 'event_stage', v_target_id, 'stage_advanced',
    jsonb_build_object(
      'source_stage_id', p_source_stage_id,
      'source_round_number', v_source.round_number,
      'target_round_number', v_target_round,
      'target_stage_name', trim(p_target_stage_name),
      'qualified_team_count', v_team_count,
      'target_group_count', v_group_count,
      'qualify_per_group', p_qualify_per_group,
      'target_group_size', p_target_group_size
    )
  );

  return jsonb_build_object(
    'source_stage_id', p_source_stage_id,
    'target_stage_id', v_target_id,
    'target_round_number', v_target_round,
    'qualified_team_count', v_team_count,
    'group_count', v_group_count,
    'stage_name', trim(p_target_stage_name)
  );
end;
$function$
;