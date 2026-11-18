-- Batch 2, item 1: enforce separate Community, Team and Event staff authority.
-- Community membership/roles may grant community-scoped powers only.
-- Team membership roles may grant team-scoped powers only.
-- Event operations require the organiser or an explicit event/stage/group/match staff assignment.

-- Batch 1 bug fix: permission checks must return false, never SQL NULL,
-- when a match has no host_user_id and the caller is not its participant/staff.
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
$function$;


comment on function app_private.resolve_permission(text,text,uuid,uuid,uuid) is
  'Canonical server-side permission resolver. Community built-in/custom roles are community-scoped, team_members roles are team-scoped, and event operations require the event organiser or explicit event staff assignment. Community role authority does not implicitly grant Event operations.';
comment on table public.community_members is
  'Membership and built-in role for one Community only. The role column never grants Team or Event staff authority.';
comment on column public.community_members.role is
  'Built-in Community-scoped role (owner/admin/moderator/organiser/member/spectator); not a global application role.';
comment on table public.community_roles is
  'Custom role definitions scoped to a single Community; permission grants are restricted to community-scoped permission keys.';
comment on table public.community_member_roles is
  'Assignments of custom Community roles to members of that same Community; not Team or Event staff assignments.';
comment on table public.role_permissions is
  'Permission grants for Community custom roles only; the authority guard rejects non-community permission keys.';
comment on table public.team_members is
  'Team roster and Team-scoped role per team (owner/captain/member/substitute); does not grant Community or Event staff authority.';
comment on column public.team_members.role is
  'Role within this team only; never treated as a global or Community/Event role.';
comment on table public.event_staff_assignments is
  'Explicit Event staff assignments scoped to one event, stage, group or match; independent of Community roles and Team membership.';
