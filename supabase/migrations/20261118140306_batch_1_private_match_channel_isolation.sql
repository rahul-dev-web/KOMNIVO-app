-- Team membership at a particular event group is derived from the group's
-- seeded teams and the authenticated user's current team membership.
create or replace function app_private.is_event_group_team_member(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.event_group_teams gt
    where gt.group_id = p_group_id
      and app_private.is_team_member(gt.team_id)
  );
$function$;
revoke all on function app_private.is_event_group_team_member(uuid) from public,anon;
grant execute on function app_private.is_event_group_team_member(uuid) to authenticated;

-- Batch 1 follow-up: public event discovery must not grant access to private group/match surfaces.
-- The published schedule remains discoverable through the matches public-event policy;
-- chat, roster, room, lobby and evidence surfaces require their exact match/group scope.

create or replace function app_private.can_access_event_group(p_event_id uuid,p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.event_groups g
    join public.event_rounds r on r.id=g.round_id
    where g.id=p_group_id
      and r.event_id=p_event_id
      and (
        app_private.can_operate_event_matches(p_event_id)
        or app_private.can_review_event_results(p_event_id)
        or app_private.is_event_group_team_member(p_group_id)
      )
  );
$function$;
revoke all on function app_private.can_access_event_group(uuid,uuid) from public,anon;
grant execute on function app_private.can_access_event_group(uuid,uuid) to authenticated;

create or replace function app_private.can_access_event_channel(
  p_event_id uuid,
  p_group_id uuid,
  p_match_id uuid
) returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select case
    when p_match_id is not null then exists (
      select 1 from public.matches m
      where m.id=p_match_id
        and m.event_id=p_event_id
        and (
          app_private.is_match_host(m.id)
          or app_private.is_match_team_participant(m.id)
          or app_private.can_operate_event_matches(m.event_id)
          or app_private.can_review_event_results(m.event_id)
        )
    )
    when p_group_id is not null then
      app_private.can_access_event_group(p_event_id,p_group_id)
    else
      app_private.resolve_permission('event.view','event',p_event_id,null,null)
  end;
$function$;
revoke all on function app_private.can_access_event_channel(uuid,uuid,uuid) from public,anon;
grant execute on function app_private.can_access_event_channel(uuid,uuid,uuid) to authenticated;

drop policy if exists event_group_teams_read_visible on public.event_group_teams;
create policy event_group_teams_read_visible on public.event_group_teams
for select to authenticated
using (
  app_private.can_access_event_group(
    (select r.event_id from public.event_groups g
     join public.event_rounds r on r.id=g.round_id
     where g.id=event_group_teams.group_id),
    group_id
  )
);

comment on function app_private.can_access_event_channel(uuid,uuid,uuid) is
  'Event-level announcements use event visibility; group/match communication requires membership or authorised staff in that exact group/match.';
comment on function app_private.can_access_event_group(uuid,uuid) is
  'A group surface is visible only to teams assigned to that group or authorised tournament operators/reviewers.';
