-- Batch 3 lifecycle notifications include scoped staff and affected event participants,
-- not only users materialised in channel_members snapshots.
create or replace function app_private.apply_event_channel_lifecycle(
  p_event_id uuid,
  p_scope_type text,
  p_scope_id uuid,
  p_trigger text
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
    select *
    from public.event_channel_lifecycle_rules
    where event_id=p_event_id
      and scope_type=p_scope_type
      and scope_id is not distinct from p_scope_id
      and lifecycle_trigger=p_trigger
      and enabled
  loop
    if v_rule.action='archive' then
      update public.channels
      set archived_at=coalesce(archived_at,now())
      where event_id=p_event_id
        and (not v_rule.only_temporary or is_temporary)
        and (case p_scope_type
          when 'stage' then stage_id=p_scope_id
          when 'group' then group_id=p_scope_id
          when 'match' then match_id=p_scope_id
          else true end);
    else
      insert into public.channel_settings(channel_id,community_id,read_only)
      select c.id,c.community_id,true
      from public.channels c
      where c.event_id=p_event_id
        and (not v_rule.only_temporary or c.is_temporary)
        and (case p_scope_type
          when 'stage' then c.stage_id=p_scope_id
          when 'group' then c.group_id=p_scope_id
          when 'match' then c.match_id=p_scope_id
          else true end)
      on conflict(channel_id) do update
        set read_only=true,updated_at=now();
    end if;
    get diagnostics v_rows = row_count;
    v_affected := v_affected + v_rows;

    if v_rule.notify_affected then
      with affected_channels as (
        select c.id
        from public.channels c
        where c.event_id=p_event_id
          and (not v_rule.only_temporary or c.is_temporary)
          and (case p_scope_type
            when 'stage' then c.stage_id=p_scope_id
            when 'group' then c.group_id=p_scope_id
            when 'match' then c.match_id=p_scope_id
            else true end)
      ),
      recipients as (
        -- Existing channel membership snapshots are still included.
        select cm.user_id
        from affected_channels ac
        join public.channel_members cm on cm.channel_id=ac.id

        union

        -- Staff inherited from the affected event/stage/group/match hierarchy.
        select a.user_id
        from public.event_staff_assignments a
        where a.event_id=p_event_id
          and (
            p_scope_type='event'
            or (
              p_scope_type='stage'
              and (
                a.scope_type='event'
                or (a.scope_type='stage' and a.stage_id=p_scope_id)
                or (a.scope_type='group' and exists(
                  select 1 from public.event_groups g
                  where g.id=a.group_id and g.round_id=p_scope_id
                ))
                or (a.scope_type='match' and exists(
                  select 1 from public.matches m
                  where m.id=a.match_id and m.stage_id=p_scope_id
                ))
              )
            )
            or (
              p_scope_type='group'
              and (
                a.scope_type='event'
                or (a.scope_type='stage' and a.stage_id=(
                  select g.round_id from public.event_groups g where g.id=p_scope_id
                ))
                or (a.scope_type='group' and a.group_id=p_scope_id)
                or (a.scope_type='match' and exists(
                  select 1 from public.matches m
                  where m.id=a.match_id and m.group_id=p_scope_id
                ))
              )
            )
            or (
              p_scope_type='match'
              and (
                a.scope_type='event'
                or (a.scope_type='stage' and a.stage_id=(
                  select m.stage_id from public.matches m where m.id=p_scope_id
                ))
                or (a.scope_type='group' and a.group_id=(
                  select m.group_id from public.matches m where m.id=p_scope_id
                ))
                or (a.scope_type='match' and a.match_id=p_scope_id)
              )
            )
          )

        union

        -- Captains and roster players in the affected event/stage/group.
        select er.captain_user_id
        from public.event_registrations er
        where er.event_id=p_event_id
          and (
            p_scope_type='event'
            or (
              p_scope_type='stage'
              and exists (
                select 1
                from public.matches m
                where m.event_id=p_event_id and m.stage_id=p_scope_id
                  and (m.group_id is null or exists (
                    select 1 from public.event_groups g
                    where g.id=m.group_id and g.round_id=p_scope_id
                  ))
                  and (m.group_id is null or exists (
                    select 1 from public.event_group_teams gt
                    where gt.group_id=m.group_id and gt.team_id=er.team_id
                  ))
                  and exists (
                    select 1 from public.match_participants mp
                    where mp.match_id=m.id and mp.registration_id=er.id
                  )
              )
              or exists (
                select 1
                from public.event_groups g
                join public.event_group_teams gt on gt.group_id=g.id
                where g.round_id=p_scope_id and gt.team_id=er.team_id
              )
            )
            or (
              p_scope_type='group'
              and (
                exists (
                  select 1 from public.event_group_teams gt
                  where gt.group_id=p_scope_id and gt.team_id=er.team_id
                )
                or exists (
                  select 1 from public.matches m
                  join public.match_participants mp on mp.match_id=m.id
                  where m.event_id=p_event_id and m.group_id=p_scope_id
                    and mp.registration_id=er.id
                )
              )
            )
            or (
              p_scope_type='match'
              and exists (
                select 1 from public.match_participants mp
                where mp.match_id=p_scope_id and mp.registration_id=er.id
              )
            )
          )

        union

        select rp.user_id
        from public.event_registrations er
        join public.registration_players rp on rp.registration_id=er.id
        where er.event_id=p_event_id
          and (
            p_scope_type='event'
            or (
              p_scope_type='stage'
              and (
                exists (
                  select 1 from public.matches m
                  join public.match_participants mp on mp.match_id=m.id
                  where m.event_id=p_event_id and m.stage_id=p_scope_id
                    and mp.registration_id=er.id
                )
                or exists (
                  select 1 from public.event_groups g
                  join public.event_group_teams gt on gt.group_id=g.id
                  where g.round_id=p_scope_id and gt.team_id=er.team_id
                )
              )
            )
            or (
              p_scope_type='group'
              and (
                exists (
                  select 1 from public.event_group_teams gt
                  where gt.group_id=p_scope_id and gt.team_id=er.team_id
                )
                or exists (
                  select 1 from public.matches m
                  join public.match_participants mp on mp.match_id=m.id
                  where m.event_id=p_event_id and m.group_id=p_scope_id
                    and mp.registration_id=er.id
                )
              )
            )
            or (
              p_scope_type='match'
              and exists (
                select 1 from public.match_participants mp
                where mp.match_id=p_scope_id and mp.registration_id=er.id
              )
            )
          )

        union

        -- Team members for teams assigned to groups in the affected scope.
        select tm.user_id
        from public.event_groups g
        join public.event_rounds r on r.id=g.round_id
        join public.event_group_teams gt on gt.group_id=g.id
        join public.team_members tm on tm.team_id=gt.team_id
        where r.event_id=p_event_id
          and (
            (p_scope_type='event')
            or (p_scope_type='stage' and g.round_id=p_scope_id)
            or (p_scope_type='group' and g.id=p_scope_id)
            or (
              p_scope_type='match'
              and exists (
                select 1 from public.matches m
                where m.id=p_scope_id and m.group_id=g.id
              )
            )
          )
      )
      insert into public.notifications(user_id,title,body,kind,entity_type,entity_id)
      select distinct
        r.user_id,
        'Event communication access updated',
        'A '||p_scope_type||' communication channel was '||
          case when v_rule.action='archive' then 'archived' else 'locked for new messages' end||
          ' after the configured '||p_trigger||' lifecycle step. Official event records were preserved.',
        'event',
        'event',
        p_event_id
      from recipients r
      where r.user_id is not null
        and not exists (
          select 1 from public.notifications n
          where n.user_id=r.user_id
            and n.title='Event communication access updated'
            and n.entity_type='event'
            and n.entity_id=p_event_id
            and n.created_at >= now()-interval '1 second'
        );
    end if;
  end loop;
  return v_affected;
end;
$function$;
revoke all on function app_private.apply_event_channel_lifecycle(uuid,text,uuid,text) from public,anon,authenticated;
