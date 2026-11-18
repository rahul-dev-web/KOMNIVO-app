CREATE OR REPLACE FUNCTION app_private.has_event_staff_role(p_event_id uuid, p_roles text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
    from public.event_staff_assignments a
    where a.event_id = p_event_id
      and a.user_id = (select auth.uid())
      and a.role_key = any(p_roles)
  );
$function$;


CREATE OR REPLACE FUNCTION app_private.has_stage_staff_scope(p_stage_id uuid, p_role_keys text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from public.event_rounds r
    join public.event_staff_assignments a on a.event_id=r.event_id
    where r.id=p_stage_id and a.user_id=(select auth.uid()) and a.role_key=any(p_role_keys)
      and (a.scope_type='event' or (a.scope_type='stage' and a.stage_id=r.id))
  );
$function$;


CREATE OR REPLACE FUNCTION app_private.has_group_staff_scope(p_group_id uuid, p_role_keys text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from public.event_groups g
    join public.event_rounds r on r.id=g.round_id
    join public.event_staff_assignments a on a.event_id=r.event_id
    where g.id=p_group_id and a.user_id=(select auth.uid()) and a.role_key=any(p_role_keys)
      and (a.scope_type<>'event' or a.role_key<>'match_operator')
      and (
        a.scope_type='event'
        or (a.scope_type='stage' and a.stage_id=r.id)
        or (a.scope_type='group' and a.group_id=g.id)
      )
  );
$function$;


CREATE OR REPLACE FUNCTION app_private.has_match_staff_scope(p_match_id uuid, p_role_keys text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from public.matches m
    join public.event_staff_assignments a on a.event_id=m.event_id
    where m.id=p_match_id and a.user_id=(select auth.uid()) and a.role_key=any(p_role_keys)
      and (a.scope_type<>'event' or a.role_key<>'match_operator')
      and (
        a.scope_type='event'
        or (a.scope_type='stage' and a.stage_id=m.stage_id)
        or (a.scope_type='group' and a.group_id=m.group_id)
        or (a.scope_type='match' and a.match_id=m.id)
      )
  );
$function$;


CREATE OR REPLACE FUNCTION app_private.event_staff_authority_rank(p_event_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_organizer uuid;
  v_rank integer := 0;
begin
  select e.organizer_id into v_organizer from public.events e where e.id=p_event_id;
  if v_organizer=(select auth.uid()) then return 2147483647; end if;
  select coalesce(max(case a.role_key
    when 'competition_manager' then 900000
    when 'tournament_director' then 800000
    when 'match_operator' then 600000
    when 'referee' then 500000
    when 'result_reviewer' then 500000
    when 'dispute_reviewer' then 500000
    when 'support_staff' then 200000
    when 'caster' then 100000
    when 'streamer' then 100000
    else 0 end),0)
  into v_rank
  from public.event_staff_assignments a
  where a.event_id=p_event_id and a.user_id=(select auth.uid())
    and a.scope_type='event';
  return v_rank;
end;
$function$;


CREATE OR REPLACE FUNCTION app_private.guard_event_staff_assignment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_event_id uuid;
  v_target_role text;
  v_rank integer;
  v_target_rank integer;
  v_scope_valid boolean := false;
begin
  v_event_id := case when TG_OP='DELETE' then OLD.event_id else NEW.event_id end;
  v_target_role := case when TG_OP='DELETE' then OLD.role_key else NEW.role_key end;
  if auth.uid() is null then
    if TG_OP='DELETE' then return OLD; end if;
    return NEW;
  end if;
  if TG_OP='UPDATE' and (
    NEW.id is distinct from OLD.id
    or NEW.event_id is distinct from OLD.event_id
    or NEW.user_id is distinct from OLD.user_id
  ) then
    raise exception 'Event staff assignment identity is immutable';
  end if;
  if not app_private.resolve_permission('event.staff.assign','event',v_event_id,null,null) then
    raise exception 'You cannot assign event staff in this event';
  end if;
  if TG_OP <> 'DELETE' then
    if NEW.assigned_by is distinct from auth.uid() then
      raise exception 'Event staff assignment actor must be the authenticated user';
    end if;
    if NEW.scope_type='event' then
      v_scope_valid := NEW.stage_id is null and NEW.group_id is null and NEW.match_id is null;
    elsif NEW.scope_type='stage' then
      select exists(select 1 from public.event_rounds r where r.id=NEW.stage_id and r.event_id=NEW.event_id) into v_scope_valid;
    elsif NEW.scope_type='group' then
      select exists(
        select 1 from public.event_groups g join public.event_rounds r on r.id=g.round_id
        where g.id=NEW.group_id and r.event_id=NEW.event_id
      ) into v_scope_valid;
    elsif NEW.scope_type='match' then
      select exists(select 1 from public.matches m where m.id=NEW.match_id and m.event_id=NEW.event_id) into v_scope_valid;
    end if;
    if not v_scope_valid then
      raise exception 'Event staff scope must reference a resource within the same event';
    end if;
    if NEW.role_key='match_operator' and NEW.scope_type='event' then
      raise exception 'Match Operators must be assigned to a stage, group, or match scope';
    end if;
    if NEW.role_key in ('competition_manager','tournament_director') and NEW.scope_type<>'event' then
      raise exception 'Competition Managers and Tournament Directors require event scope';
    end if;
  end if;
  v_rank := app_private.event_staff_authority_rank(v_event_id);
  v_target_rank := case v_target_role
    when 'competition_manager' then 900000
    when 'tournament_director' then 800000
    when 'match_operator' then 600000
    when 'referee' then 500000
    when 'result_reviewer' then 500000
    when 'dispute_reviewer' then 500000
    when 'support_staff' then 200000
    when 'caster' then 100000
    when 'streamer' then 100000
    else 2147483647 end;
  if v_target_rank >= v_rank then
    raise exception 'You cannot assign or modify an event role at or above your own authority';
  end if;
  if TG_OP='DELETE' then return OLD; end if;
  return NEW;
end;
$function$;


CREATE OR REPLACE FUNCTION app_private.resolve_permission(p_permission_key text, p_scope_type text, p_scope_id uuid, p_related_id uuid DEFAULT NULL::uuid, p_resource_id uuid DEFAULT NULL::uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := (select auth.uid());
  v_scope_type text;
  v_owner_override boolean := false;
  v_community_owner uuid;
  v_community_visibility text;
  v_member_role text;
  v_is_member boolean := false;
  v_is_owner boolean := false;
  v_builtin_allowed boolean := false;
  v_custom_allowed boolean := false;
  v_custom_denied boolean := false;
  v_override_allowed boolean := false;
  v_override_denied boolean := false;
  v_channel_private boolean := false;
  v_team_owner uuid;
  v_team_public boolean := false;
  v_event_id uuid;
  v_event_organizer uuid;
  v_event_community uuid;
  v_event_status text;
  v_is_organizer boolean := false;
  v_community_manager boolean := false;
  v_is_staff_role boolean := false;
  v_match_event uuid;
  v_match_host uuid;
  v_is_match_participant boolean := false;
  v_session_operator uuid;
  v_session_match uuid;
  v_session_event uuid;
begin
  if v_uid is null or p_permission_key is null or p_scope_type is null then
    return false;
  end if;

  select d.scope_type,d.owner_override
    into v_scope_type,v_owner_override
  from app_private.permission_definitions d
  where d.permission_key = p_permission_key;

  if not found or v_scope_type <> p_scope_type then
    return false;
  end if;

  if p_scope_type = 'platform' then
    -- No platform super-user or global administrator is defined in the current product.
    return false;
  elsif p_scope_type = 'user' then
    return p_scope_id = v_uid
      and p_permission_key in ('user.self.read','user.self.manage');
  elsif p_scope_id is null then
    return false;
  end if;

  if p_scope_type = 'community' then
    select c.owner_user_id,c.visibility
      into v_community_owner,v_community_visibility
    from public.communities c where c.id = p_scope_id;
    if not found then return false; end if;

    v_is_owner := v_community_owner = v_uid;
    select cm.role into v_member_role
    from public.community_members cm
    where cm.community_id = p_scope_id and cm.user_id = v_uid;
    v_is_member := found or v_is_owner;

    if p_permission_key = 'community.view' then
      return v_is_member or v_community_visibility = 'public';
    end if;

    if not v_is_member then return false; end if;

    if p_resource_id is not null then
      select c.is_private into v_channel_private
      from public.channels c
      where c.id = p_resource_id and c.community_id = p_scope_id and c.event_id is null;
      if not found then return false; end if;

      select
        coalesce(bool_or(cpo.effect = 'allow'),false),
        coalesce(bool_or(cpo.effect = 'deny'),false)
      into v_override_allowed,v_override_denied
      from public.channel_permission_overrides cpo
      join public.community_member_roles cmr
        on cmr.role_id = cpo.role_id
       and cmr.community_id = cpo.community_id
       and cmr.user_id = v_uid
      where cpo.community_id = p_scope_id
        and cpo.channel_id = p_resource_id
        and cpo.permission_key = p_permission_key;
    end if;

    select
      coalesce(bool_or(rp.allowed),false),
      coalesce(bool_or(not rp.allowed),false)
    into v_custom_allowed,v_custom_denied
    from public.community_member_roles cmr
    join public.role_permissions rp on rp.role_id = cmr.role_id
    where cmr.community_id = p_scope_id
      and cmr.user_id = v_uid
      and rp.permission_key = p_permission_key;

    if p_permission_key = 'channel.view' then
      v_builtin_allowed :=
        (not v_channel_private)
        or v_member_role in ('owner','admin','moderator','organiser')
        or exists (
          select 1 from public.channel_members cm
          where cm.channel_id = p_resource_id and cm.user_id = v_uid
        );
    else
      v_builtin_allowed := case p_permission_key
        when 'community.manage_settings' then v_is_owner or v_member_role = 'admin'
        when 'community.manage_structure' then v_is_owner or v_member_role in ('admin','moderator','organiser')
        when 'community.manage_members' then v_is_owner or v_member_role in ('admin','moderator')
        when 'community.manage_invites' then v_is_owner or v_member_role in ('admin','organiser')
        when 'community.manage_roles' then v_is_owner or v_member_role = 'admin'
        when 'community.manage_permissions' then v_is_owner or v_member_role = 'admin'
        when 'community.audit.read' then v_is_owner or v_member_role = 'admin'
        when 'channel.read_history' then
          (not v_channel_private)
          or v_member_role in ('owner','admin','moderator','organiser')
          or exists (select 1 from public.channel_members cm where cm.channel_id = p_resource_id and cm.user_id = v_uid)
        when 'channel.send_messages' then
          (not v_channel_private or v_member_role in ('owner','admin','moderator','organiser') or exists (
            select 1 from public.channel_members cm where cm.channel_id = p_resource_id and cm.user_id = v_uid
          ))
          and not exists (
            select 1 from public.community_members cm
            where cm.community_id = p_scope_id and cm.user_id = v_uid
              and cm.muted_until is not null and cm.muted_until > now()
          )
        when 'channel.react' then
          (not v_channel_private or v_member_role in ('owner','admin','moderator','organiser') or exists (
            select 1 from public.channel_members cm where cm.channel_id = p_resource_id and cm.user_id = v_uid
          ))
        when 'channel.manage_messages' then v_is_owner or v_member_role in ('admin','moderator')
        else false
      end;
    end if;

    if (v_custom_denied or v_override_denied)
       and not (v_is_owner and v_owner_override) then
      return false;
    end if;
    if v_is_owner and v_owner_override then return true; end if;
    return v_builtin_allowed or v_custom_allowed or v_override_allowed;

  elsif p_scope_type = 'team' then
    select t.owner_user_id,t.is_public
      into v_team_owner,v_team_public
    from public.teams t where t.id = p_scope_id;
    if not found then return false; end if;
    if p_permission_key = 'team.view' then
      return v_team_public or v_team_owner = v_uid or exists (
        select 1 from public.team_members tm where tm.team_id = p_scope_id and tm.user_id = v_uid
      );
    elsif p_permission_key = 'team.manage' then
      return v_team_owner = v_uid or exists (
        select 1 from public.team_members tm
        where tm.team_id = p_scope_id and tm.user_id = v_uid and tm.role in ('owner','captain')
      );
    end if;
    return false;

  elsif p_scope_type = 'event' then
    select e.organizer_id,e.community_id,e.status
      into v_event_organizer,v_event_community,v_event_status
    from public.events e where e.id = p_scope_id;
    if not found then return false; end if;

    v_is_organizer := v_event_organizer = v_uid;
    v_community_manager := v_event_community is not null
      and app_private.resolve_permission('community.manage_structure','community',v_event_community,null,null);

    if p_permission_key = 'event.view' then
      return v_event_status in ('published','registration_open','registration_closed','live','completed')
        or v_is_organizer
        or v_community_manager
        or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
        )
        or exists (
          select 1 from public.event_registrations er
          where er.event_id = p_scope_id and (
            er.captain_user_id = v_uid
            or (er.team_id is not null and exists (
              select 1 from public.team_members tm where tm.team_id = er.team_id and tm.user_id = v_uid
            ))
            or exists (
              select 1 from public.registration_players rp
              where rp.registration_id = er.id and rp.user_id = v_uid
            )
          )
        );
    end if;

    case p_permission_key
      when 'event.manage' then
        return v_is_organizer or v_community_manager or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key in ('competition_manager','tournament_director')
        );
      when 'event.staff.assign' then
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key in ('competition_manager','tournament_director')
        );
      when 'event.matches.operate','event.checkin.manage','event.matches.manage',
           'event.room_credentials.read','event.room_credentials.release' then
        return v_is_organizer or v_community_manager or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array['competition_manager','tournament_director']::text[])
        );
      when 'event.registrations.manage','event.roster.lock' then
        return v_is_organizer or v_community_manager or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array['competition_manager','tournament_director']::text[])
        );
      when 'event.results.review' then
        return v_is_organizer or v_community_manager or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array[
              'competition_manager','tournament_director','referee','result_reviewer','dispute_reviewer'
            ]::text[])
        );
      when 'event.disputes.review' then
        return v_is_organizer or v_community_manager or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array['competition_manager','tournament_director','dispute_reviewer']::text[])
        );
      when 'event.standings.publish' then
        return v_is_organizer or v_community_manager or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array['competition_manager','tournament_director','result_reviewer']::text[])
        );
      when 'event.audit.read' then
        return v_is_organizer or v_community_manager or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array['competition_manager','tournament_director']::text[])
        );
      else
        return false;
    end case;

  elsif p_scope_type = 'stage' then
    select r.event_id into v_event_id
    from public.event_rounds r where r.id = p_scope_id;
    if not found then return false; end if;
    if p_permission_key = 'stage.view' then
      return exists (
        select 1 from public.events e
        where e.id = v_event_id
          and e.status in ('published','registration_open','registration_closed','live','completed')
      )
      or app_private.resolve_permission('event.manage','event',v_event_id,null,null)
      or app_private.resolve_permission('event.results.review','event',v_event_id,null,null)
      or app_private.resolve_permission('event.disputes.review','event',v_event_id,null,null)
      or app_private.has_stage_staff_scope(p_scope_id, array[
        'competition_manager','tournament_director','match_operator','referee','result_reviewer','dispute_reviewer','support_staff','caster','streamer'
      ]::text[])
      or exists (
        select 1
        from public.event_groups g
        join public.event_group_teams gt on gt.group_id = g.id
        join public.team_members tm on tm.team_id = gt.team_id
        where g.round_id = p_scope_id and tm.user_id = v_uid
      );
    elsif p_permission_key = 'stage.manage' then
      return app_private.resolve_permission('event.matches.operate','event',v_event_id,null,null);
    end if;
    return false;

  elsif p_scope_type = 'group' then
    select r.event_id into v_event_id
    from public.event_groups g
    join public.event_rounds r on r.id = g.round_id
    where g.id = p_scope_id;
    if not found then return false; end if;
    if p_permission_key = 'group.view' then
      return exists (
        select 1 from public.events e
        where e.id = v_event_id
          and e.status in ('published','registration_open','registration_closed','live','completed')
      )
      or app_private.resolve_permission('event.manage','event',v_event_id,null,null)
      or app_private.resolve_permission('event.results.review','event',v_event_id,null,null)
      or app_private.resolve_permission('event.disputes.review','event',v_event_id,null,null)
      or app_private.has_group_staff_scope(p_scope_id, array[
        'competition_manager','tournament_director','match_operator','referee','result_reviewer','dispute_reviewer','support_staff'
      ]::text[])
      or app_private.is_event_group_team_member(p_scope_id);
    elsif p_permission_key = 'group.manage' then
      return app_private.resolve_permission('event.matches.operate','event',v_event_id,null,null);
    end if;
    return false;

  elsif p_scope_type = 'match' then
    select m.event_id,m.host_user_id into v_match_event,v_match_host
    from public.matches m where m.id = p_scope_id;
    if not found then return false; end if;

    select exists (
      select 1
      from public.match_participants mp
      join public.team_members tm on tm.team_id = mp.team_id
      where mp.match_id = p_scope_id and tm.user_id = v_uid
    ) into v_is_match_participant;

    select e.status into v_event_status from public.events e where e.id = v_match_event;

    case p_permission_key
      when 'match.view' then
        return v_event_status in ('published','registration_open','registration_closed','live','completed')
          or v_match_host = v_uid
          or v_is_match_participant
          or app_private.resolve_permission('event.manage','event',v_match_event,null,null)
          or app_private.resolve_permission('event.results.review','event',v_match_event,null,null)
          or app_private.resolve_permission('event.disputes.review','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array[
            'match_operator','referee','result_reviewer','dispute_reviewer','support_staff','caster','streamer'
          ]::text[]);
      when 'match.participants.view' then
        return v_match_host = v_uid
          or v_is_match_participant
          or app_private.resolve_permission('event.matches.operate','event',v_match_event,null,null)
          or app_private.resolve_permission('match.results.review','match',p_scope_id,null,null)
          or app_private.resolve_permission('match.disputes.review','match',p_scope_id,null,null);
      when 'match.operate' then
        return v_match_host = v_uid
          or app_private.resolve_permission('event.matches.operate','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array['match_operator']::text[]);
      when 'match.credentials.release' then
        return v_match_host = v_uid
          or app_private.resolve_permission('event.room_credentials.release','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array['match_operator']::text[]);
      when 'match.credentials.read' then
        return v_match_host = v_uid
          or app_private.resolve_permission('event.room_credentials.read','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array['match_operator']::text[])
          or exists (
            select 1
            from public.match_participants mp
            join public.team_members tm on tm.team_id = mp.team_id
            where mp.match_id = p_scope_id
              and mp.check_in_status = 'ready'
              and tm.user_id = v_uid
          );
      when 'match.results.review' then
        return app_private.resolve_permission('event.results.review','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array['referee','result_reviewer']::text[]);
      when 'match.disputes.review' then
        return app_private.resolve_permission('event.disputes.review','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array['dispute_reviewer']::text[]);
      when 'liveops.session.manage','liveops.capture.submit' then
        return app_private.resolve_permission('match.operate','match',p_scope_id,null,null);
      when 'liveops.capture.read' then
        return v_match_host = v_uid
          or app_private.resolve_permission('event.matches.operate','event',v_match_event,null,null)
          or app_private.resolve_permission('match.results.review','match',p_scope_id,null,null)
          or app_private.resolve_permission('match.disputes.review','match',p_scope_id,null,null);
      else
        return app_private.resolve_permission(p_permission_key,'event',v_match_event,null,null);
    end case;

  elsif p_scope_type = 'participant' then
    if p_related_id is null then return false; end if;
    if not exists (
      select 1 from public.match_participants mp
      where mp.match_id = p_scope_id and mp.team_id = p_related_id
    ) then return false; end if;
    if p_permission_key = 'participant.view' then
      return exists (
        select 1 from public.team_members tm
        where tm.team_id = p_related_id and tm.user_id = v_uid
      ) or app_private.resolve_permission('match.participants.view','match',p_scope_id,null,null);
    elsif p_permission_key = 'participant.checkin' then
      return exists (
        select 1 from public.team_members tm
        where tm.team_id = p_related_id and tm.user_id = v_uid
      );
    end if;
    return false;

  elsif p_scope_type = 'liveops_session' then
    select s.operator_id,s.match_id,s.event_id
      into v_session_operator,v_session_match,v_session_event
    from public.liveops_sessions s where s.id = p_scope_id;
    if not found then return false; end if;
    if p_permission_key = 'liveops.capture.review' then
      return app_private.resolve_permission('match.results.review','match',v_session_match,null,null);
    elsif p_permission_key = 'liveops.capture.read' then
      return v_session_operator = v_uid
        or app_private.resolve_permission('liveops.capture.read','match',v_session_match,null,null);
    elsif p_permission_key = 'liveops.session.manage' then
      return v_session_operator = v_uid
        and app_private.resolve_permission('liveops.session.manage','match',v_session_match,null,null);
    end if;
    return false;
  end if;

  return false;
end;
$function$;


revoke all on function app_private.has_event_staff_role(uuid,text[]) from public,anon;
revoke all on function app_private.has_stage_staff_scope(uuid,text[]) from public,anon;
revoke all on function app_private.has_group_staff_scope(uuid,text[]) from public,anon;
revoke all on function app_private.has_match_staff_scope(uuid,text[]) from public,anon;
grant execute on function app_private.has_event_staff_role(uuid,text[]) to authenticated;
grant execute on function app_private.has_stage_staff_scope(uuid,text[]) to authenticated;
grant execute on function app_private.has_group_staff_scope(uuid,text[]) to authenticated;
grant execute on function app_private.has_match_staff_scope(uuid,text[]) to authenticated;
revoke all on function app_private.event_staff_authority_rank(uuid) from public,anon,authenticated;
grant execute on function app_private.event_staff_authority_rank(uuid) to authenticated;
revoke all on function app_private.guard_event_staff_assignment() from public,anon,authenticated;
revoke all on function app_private.resolve_permission(text,text,uuid,uuid,uuid) from public,anon;
grant execute on function app_private.resolve_permission(text,text,uuid,uuid,uuid) to authenticated;

create or replace function app_private.can_access_event_channel_scope(
  p_event_id uuid,
  p_stage_id uuid,
  p_group_id uuid,
  p_match_id uuid,
  p_channel_id uuid default null
) returns boolean
language sql stable security definer set search_path = ''
as $function$
  select case
    when p_match_id is not null then
      exists(select 1 from public.matches m where m.id=p_match_id and m.event_id=p_event_id)
      and (
        app_private.resolve_permission('match.operate','match',p_match_id,null,null)
        or app_private.resolve_permission('match.results.review','match',p_match_id,null,null)
        or app_private.resolve_permission('match.disputes.review','match',p_match_id,null,null)
        or exists (
          select 1 from public.match_participants mp
          join public.team_members tm on tm.team_id=mp.team_id
          where mp.match_id=p_match_id and tm.user_id=(select auth.uid())
        )
      )
    when p_group_id is not null then app_private.can_access_event_group(p_event_id,p_group_id)
    when p_stage_id is not null then
      exists(select 1 from public.event_rounds r where r.id=p_stage_id and r.event_id=p_event_id)
      and app_private.resolve_permission('stage.view','stage',p_stage_id,null,null)
    else app_private.resolve_permission('event.view','event',p_event_id,null,null)
  end;
$function$;
revoke all on function app_private.can_access_event_channel_scope(uuid,uuid,uuid,uuid,uuid) from public,anon;
grant execute on function app_private.can_access_event_channel_scope(uuid,uuid,uuid,uuid,uuid) to authenticated;

drop policy if exists channels_read_member on public.channels;
create policy channels_read_member on public.channels
for select to authenticated
using (
  (event_id is not null and app_private.can_access_event_channel_scope(event_id,stage_id,group_id,match_id,id))
  or (event_id is null and community_id is not null
      and app_private.resolve_permission('channel.view','community',community_id,null,id))
  or (community_id is null and event_id is null and app_private.is_channel_member(id))
);
