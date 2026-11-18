-- Batch 1 security correction: event communication must respect its real scope.
-- Public event discovery must never grant access to private event/stage channels,
-- and stage/group scoped staff must see only the communication surface they were assigned.

create or replace function app_private.can_access_event_group(
  p_event_id uuid,
  p_group_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.event_groups g
    join public.event_rounds r on r.id = g.round_id
    where g.id = p_group_id
      and r.event_id = p_event_id
      and (
        app_private.resolve_permission('event.manage','event',p_event_id,null,null)
        or app_private.resolve_permission('event.results.review','event',p_event_id,null,null)
        or app_private.resolve_permission('event.disputes.review','event',p_event_id,null,null)
        or app_private.has_stage_staff_scope(
          r.id,
          array['competition_manager','tournament_director','match_operator','referee','result_reviewer','dispute_reviewer','support_staff']::text[]
        )
        or app_private.has_group_staff_scope(
          p_group_id,
          array['match_operator','referee','result_reviewer','dispute_reviewer','support_staff']::text[]
        )
        or app_private.is_event_group_team_member(p_group_id)
      )
  );
$function$;

revoke all on function app_private.can_access_event_group(uuid,uuid) from public,anon;
grant execute on function app_private.can_access_event_group(uuid,uuid) to authenticated;

create or replace function app_private.can_access_event_channel_scope(
  p_event_id uuid,
  p_stage_id uuid,
  p_group_id uuid,
  p_match_id uuid,
  p_channel_id uuid default null
) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_private boolean;
  v_match_stage uuid;
  v_match_group uuid;
  v_group_stage uuid;
begin
  -- The caller must identify a real event channel. Fail closed on missing or
  -- mismatched scope metadata instead of falling back to public event visibility.
  if p_channel_id is null then
    return false;
  end if;

  select c.is_private
    into v_private
  from public.channels c
  where c.id = p_channel_id
    and c.event_id = p_event_id
    and c.stage_id is not distinct from p_stage_id
    and c.group_id is not distinct from p_group_id
    and c.match_id is not distinct from p_match_id;

  if not found then
    return false;
  end if;

  if p_match_id is not null then
    select m.stage_id,m.group_id
      into v_match_stage,v_match_group
    from public.matches m
    where m.id = p_match_id
      and m.event_id = p_event_id;

    if not found
       or (p_stage_id is not null and p_stage_id is distinct from v_match_stage)
       or (p_group_id is not null and p_group_id is distinct from v_match_group) then
      return false;
    end if;

    return app_private.resolve_permission('match.operate','match',p_match_id,null,null)
      or app_private.resolve_permission('match.results.review','match',p_match_id,null,null)
      or app_private.resolve_permission('match.disputes.review','match',p_match_id,null,null)
      or app_private.is_match_host(p_match_id)
      or app_private.is_match_team_participant(p_match_id);
  end if;

  if p_group_id is not null then
    select r.id into v_group_stage
    from public.event_groups g
    join public.event_rounds r on r.id = g.round_id
    where g.id = p_group_id
      and r.event_id = p_event_id;

    if not found
       or (p_stage_id is not null and p_stage_id is distinct from v_group_stage) then
      return false;
    end if;

    -- Group chat is never made public merely because its parent event is public.
    return app_private.can_access_event_group(p_event_id,p_group_id);
  end if;

  if p_stage_id is not null then
    if not exists (
      select 1 from public.event_rounds r
      where r.id = p_stage_id and r.event_id = p_event_id
    ) then
      return false;
    end if;

    if v_private then
      return app_private.resolve_permission('event.manage','event',p_event_id,null,null)
        or app_private.has_stage_staff_scope(
          p_stage_id,
          array['competition_manager','tournament_director','match_operator','referee','result_reviewer','dispute_reviewer','support_staff']::text[]
        );
    end if;

    return app_private.resolve_permission('stage.view','stage',p_stage_id,null,null);
  end if;

  if v_private then
    -- Event-wide private channels are limited to event-level staff. A match- or
    -- group-scoped operator does not inherit access to the entire staff area.
    return app_private.resolve_permission('event.manage','event',p_event_id,null,null)
      or app_private.resolve_permission('event.results.review','event',p_event_id,null,null)
      or app_private.resolve_permission('event.disputes.review','event',p_event_id,null,null)
      or exists (
        select 1 from public.event_staff_assignments a
        where a.event_id = p_event_id
          and a.user_id = (select auth.uid())
          and a.scope_type = 'event'
      );
  end if;

  return app_private.resolve_permission('event.view','event',p_event_id,null,null);
end;
$function$;

revoke all on function app_private.can_access_event_channel_scope(uuid,uuid,uuid,uuid,uuid) from public,anon;
grant execute on function app_private.can_access_event_channel_scope(uuid,uuid,uuid,uuid,uuid) to authenticated;

comment on function app_private.can_access_event_channel_scope(uuid,uuid,uuid,uuid,uuid) is
  'Fail-closed event channel access. Match channels require exact match participation/staff; group channels require group membership/scoped staff; private stage/event channels require staff scope. Public event visibility never grants private-channel access.';
