-- Batch 2: scoped hierarchy, non-delegable system presets, and automatic preset bootstrapping.
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
  v_category_id uuid;
  v_direct_override_found boolean := false;
  v_team_owner uuid;
  v_team_public boolean := false;
  v_event_id uuid;
  v_event_organizer uuid;
  v_event_status text;
  v_is_organizer boolean := false;
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

    if p_permission_key like 'channel.%' and p_resource_id is null then
      return false;
    end if;

    if p_resource_id is not null then
      select c.is_private,c.category_id
        into v_channel_private,v_category_id
      from public.channels c
      where c.id = p_resource_id and c.community_id = p_scope_id and c.event_id is null;
      if not found then return false; end if;

      -- The most specific setting wins: channel override, otherwise category inheritance.
      -- Deny wins across roles at one level. No row means Inherit.
      select exists (
        select 1 from public.channel_permission_overrides cpo
        join public.community_member_roles cmr
          on cmr.role_id=cpo.role_id and cmr.community_id=cpo.community_id and cmr.user_id=v_uid
        where cpo.community_id=p_scope_id and cpo.channel_id=p_resource_id
          and cpo.permission_key=p_permission_key
      ) into v_direct_override_found;

      if v_direct_override_found then
        select coalesce(bool_or(cpo.effect='allow'),false),
               coalesce(bool_or(cpo.effect='deny'),false)
        into v_override_allowed,v_override_denied
        from public.channel_permission_overrides cpo
        join public.community_member_roles cmr
          on cmr.role_id=cpo.role_id and cmr.community_id=cpo.community_id and cmr.user_id=v_uid
        where cpo.community_id=p_scope_id and cpo.channel_id=p_resource_id
          and cpo.permission_key=p_permission_key;
      elsif v_category_id is not null then
        select coalesce(bool_or(cpo.effect='allow'),false),
               coalesce(bool_or(cpo.effect='deny'),false)
        into v_override_allowed,v_override_denied
        from public.category_permission_overrides cpo
        join public.community_member_roles cmr
          on cmr.role_id=cpo.role_id and cmr.community_id=cpo.community_id and cmr.user_id=v_uid
        where cpo.community_id=p_scope_id and cpo.category_id=v_category_id
          and cpo.permission_key=p_permission_key;
      end if;
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
        when 'community.manage_settings' then v_is_owner
        when 'community.manage_structure' then v_is_owner or v_member_role in ('admin','moderator','organiser')
        when 'community.manage_members' then v_is_owner or v_member_role in ('admin','moderator')
        when 'community.manage_invites' then v_is_owner or v_member_role in ('admin','organiser')
        when 'community.manage_roles' then v_is_owner or v_member_role = 'admin'
        when 'community.manage_permissions' then v_is_owner
        when 'community.audit.read' then v_is_owner
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
    select e.organizer_id,e.status
      into v_event_organizer,v_event_status
    from public.events e where e.id = p_scope_id;
    if not found then return false; end if;

    v_is_organizer := v_event_organizer = v_uid;
    if p_permission_key = 'event.view' then
      return v_event_status in ('published','registration_open','registration_closed','live','completed')
        or v_is_organizer
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
        return v_is_organizer or exists (
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
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array['competition_manager','tournament_director']::text[])
        );
      when 'event.registrations.manage','event.roster.lock' then
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array['competition_manager','tournament_director']::text[])
        );
      when 'event.results.review' then
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array[
              'competition_manager','tournament_director','referee','result_reviewer','dispute_reviewer'
            ]::text[])
        );
      when 'event.disputes.review' then
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array['competition_manager','tournament_director','dispute_reviewer']::text[])
        );
      when 'event.standings.publish' then
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array['competition_manager','tournament_director','result_reviewer']::text[])
        );
      when 'event.audit.read' then
        return v_is_organizer or exists (
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
          or coalesce(v_match_host = v_uid,false)
          or v_is_match_participant
          or app_private.resolve_permission('event.manage','event',v_match_event,null,null)
          or app_private.resolve_permission('event.results.review','event',v_match_event,null,null)
          or app_private.resolve_permission('event.disputes.review','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array[
            'match_operator','referee','result_reviewer','dispute_reviewer','support_staff','caster','streamer'
          ]::text[]);
      when 'match.participants.view' then
        return coalesce(v_match_host = v_uid,false)
          or v_is_match_participant
          or app_private.resolve_permission('event.matches.operate','event',v_match_event,null,null)
          or app_private.resolve_permission('match.results.review','match',p_scope_id,null,null)
          or app_private.resolve_permission('match.disputes.review','match',p_scope_id,null,null);
      when 'match.operate' then
        return coalesce(v_match_host = v_uid,false)
          or app_private.resolve_permission('event.matches.operate','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array['match_operator']::text[]);
      when 'match.credentials.release' then
        return coalesce(v_match_host = v_uid,false)
          or app_private.resolve_permission('event.room_credentials.release','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array['match_operator']::text[]);
      when 'match.credentials.read' then
        return coalesce(v_match_host = v_uid,false)
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
        return coalesce(v_match_host = v_uid,false)
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
$function$
;
CREATE OR REPLACE FUNCTION app_private.community_authority_rank(p_community_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_rank integer := 0;
BEGIN
 SELECT COALESCE(MAX(CASE cm.role WHEN 'owner' THEN 1000000 WHEN 'admin' THEN 200 WHEN 'moderator' THEN 100 WHEN 'organiser' THEN 90 ELSE 0 END),0)
 INTO v_rank FROM public.community_members cm
 WHERE cm.community_id=p_community_id AND cm.user_id=(SELECT auth.uid());
 SELECT GREATEST(v_rank,COALESCE(MAX(cr.position),0)) INTO v_rank
 FROM public.community_member_roles cmr
 JOIN public.community_roles cr ON cr.id=cmr.role_id AND cr.community_id=cmr.community_id
 JOIN public.role_permissions rp ON rp.role_id=cr.id
 WHERE cmr.community_id=p_community_id AND cmr.user_id=(SELECT auth.uid())
 AND rp.permission_key='community.manage_roles' AND rp.allowed;
 RETURN v_rank;
END;
$function$
;
CREATE OR REPLACE FUNCTION app_private.guard_custom_role_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_community_id uuid;
  v_position integer;
  v_rank integer;
  v_is_system boolean;
begin
  v_community_id := case when TG_OP='DELETE' then OLD.community_id else NEW.community_id end;
  if auth.uid() is null then
    if TG_OP='DELETE' then return OLD; end if;
  return NEW;
  end if;
  if not app_private.resolve_permission('community.manage_roles','community',v_community_id,null,null) then
    raise exception 'You cannot manage roles in this community';
  end if;
  if TG_OP in ('UPDATE','DELETE') and OLD.is_system then
    raise exception 'System roles cannot be modified or deleted';
  end if;
  if TG_OP <> 'DELETE' then
    if NEW.is_system and current_setting('app_private.allow_system_role_seed',true) is distinct from 'on' then
      raise exception 'System roles can only be provisioned by trusted migrations';
    end if;
    v_position := NEW.position;
    v_rank := app_private.community_authority_rank(v_community_id);
    if v_position >= v_rank then
      raise exception 'You cannot create or move a role at or above your own hierarchy level';
    end if;
    NEW.created_by := coalesce(auth.uid(),NEW.created_by);
  end if;
  if TG_OP='DELETE' then return OLD; end if;
  return NEW;
end;
$function$
;
CREATE OR REPLACE FUNCTION app_private.seed_community_roles(p_community_id uuid, p_owner_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_previous text;
BEGIN
 v_previous:=current_setting('app_private.allow_system_role_seed',true);
 PERFORM set_config('app_private.allow_system_role_seed','on',true);
 INSERT INTO public.community_roles(community_id,name,description,colour,position,is_system,created_by,preset_key)
 SELECT p_community_id,p.display_name,p.description,p.colour,p.position,true,p_owner_user_id,p.preset_key
 FROM public.community_role_presets p ON CONFLICT DO NOTHING;
 INSERT INTO public.role_permissions(role_id,permission_key,allowed)
 SELECT cr.id,k.key,k.value::boolean FROM public.community_roles cr
 JOIN public.community_role_presets p ON p.preset_key=cr.preset_key
 CROSS JOIN LATERAL jsonb_each_text(p.permissions) k(key,value)
 WHERE cr.community_id=p_community_id AND cr.archived_at IS NULL
 ON CONFLICT(role_id,permission_key) DO NOTHING;
 PERFORM set_config('app_private.allow_system_role_seed',COALESCE(v_previous,''),true);
EXCEPTION WHEN OTHERS THEN
 PERFORM set_config('app_private.allow_system_role_seed',COALESCE(v_previous,''),true);
 RAISE;
END;
$function$
;
CREATE OR REPLACE FUNCTION app_private.seed_community_roles_after_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
 PERFORM app_private.seed_community_roles(NEW.id,NEW.owner_user_id);
 RETURN NEW;
END;
$function$
;
CREATE OR REPLACE FUNCTION app_private.guard_role_permission_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 v_role_id uuid; v_community_id uuid; v_position integer; v_is_system boolean;
 v_rank integer; v_permission text; v_allowed boolean;
BEGIN
 v_role_id:=CASE WHEN TG_OP='DELETE' THEN OLD.role_id ELSE NEW.role_id END;
 v_permission:=CASE WHEN TG_OP='DELETE' THEN OLD.permission_key ELSE NEW.permission_key END;
 v_allowed:=CASE WHEN TG_OP='DELETE' THEN false ELSE NEW.allowed END;
 SELECT cr.community_id,cr.position,cr.is_system INTO v_community_id,v_position,v_is_system
 FROM public.community_roles cr WHERE cr.id=v_role_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Community role not found'; END IF;
 IF auth.uid() IS NULL THEN
  IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
 END IF;
 IF NOT app_private.resolve_permission('community.manage_roles','community',v_community_id,NULL,NULL) THEN
  RAISE EXCEPTION 'You cannot edit role permissions in this community';
 END IF;
 v_rank:=app_private.community_authority_rank(v_community_id);
 IF v_position IS NULL OR v_position>=v_rank THEN
  RAISE EXCEPTION 'You cannot edit a role at or above your own hierarchy level';
 END IF;
 IF v_is_system AND current_setting('app_private.allow_system_role_seed',true) IS DISTINCT FROM 'on' THEN
  RAISE EXCEPTION 'Built-in role permissions cannot be modified';
 END IF;
 IF TG_OP<>'DELETE' AND NEW.allowed THEN
  IF v_permission LIKE 'channel.%' THEN
   IF NOT EXISTS(SELECT 1 FROM public.channels c WHERE c.community_id=v_community_id AND c.event_id IS NULL
    AND app_private.resolve_permission(v_permission,'community',v_community_id,NULL,c.id)) THEN
    RAISE EXCEPTION 'You cannot grant a channel permission you do not hold';
   END IF;
  ELSIF NOT app_private.resolve_permission(v_permission,'community',v_community_id,NULL,NULL) THEN
   RAISE EXCEPTION 'You cannot grant a permission you do not hold: %',v_permission;
  END IF;
  RETURN NEW;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END;
$function$
;
REVOKE ALL ON FUNCTION app_private.seed_community_roles(uuid,uuid) FROM public,anon,authenticated;
REVOKE ALL ON FUNCTION app_private.seed_community_roles_after_insert() FROM public,anon,authenticated;
REVOKE ALL ON FUNCTION app_private.guard_role_permission_change() FROM public,anon,authenticated;
DROP TRIGGER IF EXISTS community_roles_preset_seed ON public.communities;
CREATE TRIGGER community_roles_preset_seed AFTER INSERT ON public.communities
FOR EACH ROW EXECUTE FUNCTION app_private.seed_community_roles_after_insert();
DROP TRIGGER IF EXISTS role_permissions_authority_guard ON public.role_permissions;
CREATE TRIGGER role_permissions_authority_guard BEFORE INSERT OR UPDATE OR DELETE ON public.role_permissions
FOR EACH ROW EXECUTE FUNCTION app_private.guard_role_permission_change();
DO $function$
DECLARE v_row record;
BEGIN
  FOR v_row IN SELECT id,owner_user_id FROM public.communities LOOP
    PERFORM app_private.seed_community_roles(v_row.id,v_row.owner_user_id);
  END LOOP;
END;
$function$;
