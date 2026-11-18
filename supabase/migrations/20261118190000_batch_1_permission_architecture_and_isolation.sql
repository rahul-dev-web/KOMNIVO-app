-- Batch 1: canonical permission resolution, scope isolation and immutable audit history.
-- Values such as group sizes, round counts and match labels are deliberately not encoded here.

create schema if not exists app_private;
grant usage on schema app_private to authenticated;

create table if not exists app_private.permission_definitions (
  permission_key text primary key,
  scope_type text not null check (scope_type in (
    'platform','user','community','team','event','stage','group','match','participant','liveops_session'
  )),
  owner_override boolean not null default false,
  description text not null
);
revoke all on app_private.permission_definitions from public, anon, authenticated, service_role;

insert into app_private.permission_definitions(permission_key,scope_type,owner_override,description) values
 ('platform.manage','platform',false,'Reserved platform-wide administration; fails closed until a platform authority system exists'),
 ('user.self.read','user',false,'Read the authenticated user scope only'),
 ('user.self.manage','user',false,'Manage the authenticated user scope only'),
 ('community.view','community',false,'View a community and its member-visible information'),
 ('community.manage_settings','community',true,'Manage community identity and settings'),
 ('community.manage_structure','community',true,'Create and manage community communication structure'),
 ('community.manage_members','community',true,'Manage community membership and scoped restrictions'),
 ('community.manage_invites','community',true,'Create and revoke community invitations'),
 ('community.manage_roles','community',true,'Manage community role definitions and assignments'),
 ('community.manage_permissions','community',true,'Manage community permission grants'),
 ('community.audit.read','community',true,'Read community administrative audit history'),
 ('channel.view','community',true,'View a community channel'),
 ('channel.read_history','community',true,'Read community channel history'),
 ('channel.send_messages','community',false,'Send messages to a community channel'),
 ('channel.react','community',false,'React to messages in a community channel'),
 ('channel.manage_messages','community',true,'Moderate messages in a community channel'),
 ('team.view','team',false,'View a public team or a team the user belongs to'),
 ('team.manage','team',false,'Manage a team roster and team settings'),
 ('event.view','event',false,'View a published event'),
 ('event.manage','event',false,'Manage event configuration and lifecycle'),
 ('event.staff.assign','event',false,'Assign lower-authority event staff roles'),
 ('event.registrations.manage','event',false,'Manage event registrations'),
 ('event.roster.lock','event',false,'Lock an event roster'),
 ('event.matches.manage','event',false,'Create and schedule matches'),
 ('event.matches.operate','event',false,'Operate match check-in and room workflows'),
 ('event.checkin.manage','event',false,'Manage event match check-in'),
 ('event.room_credentials.read','event',false,'Read event room credentials as authorised staff'),
 ('event.room_credentials.release','event',false,'Schedule or release event room credentials'),
 ('event.results.review','event',false,'Review event results and submitted evidence'),
 ('event.disputes.review','event',false,'Review and decide event result disputes'),
 ('event.standings.publish','event',false,'Publish official event standings'),
 ('event.audit.read','event',false,'Read event audit history'),
 ('stage.view','stage',false,'View a stage in its parent event'),
 ('stage.manage','stage',false,'Manage a stage in its parent event'),
 ('group.view','group',false,'View a group in its parent stage'),
 ('group.manage','group',false,'Manage a group in its parent stage'),
 ('match.view','match',false,'View a match schedule and match-visible data'),
 ('match.operate','match',false,'Operate one match'),
 ('match.participants.view','match',false,'View the participant slots for one match'),
 ('match.credentials.read','match',false,'Read released credentials as an eligible checked-in participant or authorised operator'),
 ('match.credentials.release','match',false,'Schedule or release credentials for one match'),
 ('participant.view','participant',false,'View a participant slot when authorised'),
 ('participant.checkin','participant',false,'Check in only for a match the user participates in'),
 ('liveops.session.manage','match',false,'Start LiveOps for a match the user is authorised to operate'),
 ('liveops.capture.submit','match',false,'Attach evidence to the exact match session'),
 ('liveops.capture.read','match',false,'Read match-scoped LiveOps observations and evidence'),
 ('liveops.capture.review','liveops_session',false,'Review a capture session as an authorised result reviewer')
on conflict (permission_key) do update
set scope_type = excluded.scope_type,
    owner_override = excluded.owner_override,
    description = excluded.description;

create index if not exists community_member_roles_scope_user_idx
  on public.community_member_roles(community_id,user_id,role_id);
create index if not exists role_permissions_key_allowed_idx
  on public.role_permissions(role_id,permission_key,allowed);
create index if not exists event_staff_assignments_scope_user_role_idx
  on public.event_staff_assignments(event_id,user_id,role_key);

create or replace function app_private.resolve_permission(
  p_permission_key text,
  p_scope_type text,
  p_scope_id uuid,
  p_related_id uuid default null,
  p_resource_id uuid default null
) returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $function$
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
            and a.role_key in ('competition_manager','tournament_director')
        );
      when 'event.staff.assign' then
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.role_key in ('competition_manager','tournament_director')
        );
      when 'event.matches.operate','event.checkin.manage','event.matches.manage',
           'event.room_credentials.read','event.room_credentials.release' then
        return v_is_organizer or v_community_manager or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.role_key = any(array['competition_manager','tournament_director','match_operator']::text[])
        );
      when 'event.registrations.manage','event.roster.lock' then
        return v_is_organizer or v_community_manager or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.role_key = any(array['competition_manager','tournament_director']::text[])
        );
      when 'event.results.review' then
        return v_is_organizer or v_community_manager or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.role_key = any(array[
              'competition_manager','tournament_director','referee','result_reviewer','dispute_reviewer'
            ]::text[])
        );
      when 'event.disputes.review' then
        return v_is_organizer or v_community_manager or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.role_key = any(array['competition_manager','tournament_director','dispute_reviewer']::text[])
        );
      when 'event.standings.publish' then
        return v_is_organizer or v_community_manager or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.role_key = any(array['competition_manager','tournament_director','result_reviewer']::text[])
        );
      when 'event.audit.read' then
        return v_is_organizer or v_community_manager or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
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
      return app_private.resolve_permission('event.view','event',v_event_id,null,null);
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
      return app_private.resolve_permission('event.view','event',v_event_id,null,null);
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

    case p_permission_key
      when 'match.view' then
        return app_private.resolve_permission('event.view','event',v_match_event,null,null)
          or v_match_host = v_uid or v_is_match_participant;
      when 'match.participants.view' then
        return v_match_host = v_uid
          or v_is_match_participant
          or app_private.resolve_permission('event.matches.operate','event',v_match_event,null,null)
          or app_private.resolve_permission('event.results.review','event',v_match_event,null,null);
      when 'match.operate' then
        return v_match_host = v_uid
          or app_private.resolve_permission('event.matches.operate','event',v_match_event,null,null);
      when 'match.credentials.release' then
        return v_match_host = v_uid
          or app_private.resolve_permission('event.room_credentials.release','event',v_match_event,null,null);
      when 'match.credentials.read' then
        return v_match_host = v_uid
          or app_private.resolve_permission('event.room_credentials.read','event',v_match_event,null,null)
          or exists (
            select 1
            from public.match_participants mp
            join public.team_members tm on tm.team_id = mp.team_id
            where mp.match_id = p_scope_id
              and mp.check_in_status = 'ready'
              and tm.user_id = v_uid
          );
      when 'liveops.session.manage','liveops.capture.submit' then
        return v_match_host = v_uid
          or app_private.resolve_permission('event.matches.operate','event',v_match_event,null,null);
      when 'liveops.capture.read' then
        return v_match_host = v_uid
          or app_private.resolve_permission('event.matches.operate','event',v_match_event,null,null)
          or app_private.resolve_permission('event.results.review','event',v_match_event,null,null);
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
      return app_private.resolve_permission('event.results.review','event',v_session_event,null,null);
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

revoke all on function app_private.resolve_permission(text,text,uuid,uuid,uuid) from public,anon;
grant execute on function app_private.resolve_permission(text,text,uuid,uuid,uuid) to authenticated;

create or replace function public.has_permission(
  p_permission_key text,
  p_scope_type text,
  p_scope_id uuid,
  p_related_id uuid default null,
  p_resource_id uuid default null
) returns boolean
language sql
stable
security invoker
set search_path = ''
as $function$
  select app_private.resolve_permission(
    p_permission_key,p_scope_type,p_scope_id,p_related_id,p_resource_id
  );
$function$;
revoke all on function public.has_permission(text,text,uuid,uuid,uuid) from public,anon;
grant execute on function public.has_permission(text,text,uuid,uuid,uuid) to authenticated;

create or replace function app_private.can_manage_community_roles(p_community_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select app_private.resolve_permission('community.manage_roles','community',p_community_id,null,null);
$function$;

create or replace function app_private.can_manage_community_structure(p_community_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select app_private.resolve_permission('community.manage_structure','community',p_community_id,null,null);
$function$;

create or replace function app_private.can_manage_community(p_community_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select
    app_private.resolve_permission('community.manage_settings','community',p_community_id,null,null)
    or app_private.resolve_permission('community.manage_structure','community',p_community_id,null,null);
$function$;

create or replace function app_private.is_event_staff(p_event_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select app_private.resolve_permission('event.manage','event',p_event_id,null,null);
$function$;

create or replace function app_private.can_operate_event_matches(p_event_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select app_private.resolve_permission('event.matches.operate','event',p_event_id,null,null);
$function$;

create or replace function app_private.can_review_event_results(p_event_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select app_private.resolve_permission('event.results.review','event',p_event_id,null,null);
$function$;

create or replace function app_private.is_match_host(p_match_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select app_private.resolve_permission('match.operate','match',p_match_id,null,null);
$function$;

create or replace function app_private.can_access_event_channel(
  p_event_id uuid,p_group_id uuid,p_match_id uuid
) returns boolean
language sql stable security definer set search_path = ''
as $function$
  select case
    when p_match_id is not null then
      app_private.resolve_permission('match.view','match',p_match_id,null,null)
    when p_group_id is not null then
      app_private.resolve_permission('group.view','group',p_group_id,null,null)
    else
      app_private.resolve_permission('event.view','event',p_event_id,null,null)
  end;
$function$;

revoke all on function app_private.can_manage_community_roles(uuid) from public,anon;
revoke all on function app_private.can_manage_community_structure(uuid) from public,anon;
revoke all on function app_private.can_manage_community(uuid) from public,anon;
revoke all on function app_private.is_event_staff(uuid) from public,anon;
revoke all on function app_private.can_operate_event_matches(uuid) from public,anon;
revoke all on function app_private.can_review_event_results(uuid) from public,anon;
revoke all on function app_private.is_match_host(uuid) from public,anon;
revoke all on function app_private.can_access_event_channel(uuid,uuid,uuid) from public,anon;
grant execute on function app_private.can_manage_community_roles(uuid) to authenticated;
grant execute on function app_private.can_manage_community_structure(uuid) to authenticated;
grant execute on function app_private.can_manage_community(uuid) to authenticated;
grant execute on function app_private.is_event_staff(uuid) to authenticated;
grant execute on function app_private.can_operate_event_matches(uuid) to authenticated;
grant execute on function app_private.can_review_event_results(uuid) to authenticated;
grant execute on function app_private.is_match_host(uuid) to authenticated;
grant execute on function app_private.can_access_event_channel(uuid,uuid,uuid) to authenticated;

create or replace function app_private.community_authority_rank(p_community_id uuid)
returns integer
language plpgsql stable security definer set search_path = ''
as $function$
declare
  v_rank integer := 0;
begin
  select coalesce(max(case cm.role
    when 'owner' then 2147483647
    when 'admin' then 2000000000
    when 'moderator' then 1000000
    when 'organiser' then 900000
    else 0 end),0)
  into v_rank
  from public.community_members cm
  where cm.community_id=p_community_id and cm.user_id=(select auth.uid());

  select greatest(v_rank,coalesce(max(cr.position),0))
  into v_rank
  from public.community_member_roles cmr
  join public.community_roles cr on cr.id=cmr.role_id and cr.community_id=cmr.community_id
  join public.role_permissions rp on rp.role_id=cr.id
  where cmr.community_id=p_community_id
    and cmr.user_id=(select auth.uid())
    and rp.permission_key='community.manage_roles'
    and rp.allowed;

  return v_rank;
end;
$function$;
revoke all on function app_private.community_authority_rank(uuid) from public,anon;
grant execute on function app_private.community_authority_rank(uuid) to authenticated;

create or replace function app_private.guard_community_membership_authority()
returns trigger
language plpgsql security definer set search_path = ''
as $function$
declare
  v_community_id uuid;
  v_actor uuid := (select auth.uid());
  v_owner uuid;
  v_old_role text;
begin
  v_community_id := case when TG_OP='DELETE' then OLD.community_id else NEW.community_id end;
  if v_actor is null then
    if TG_OP='DELETE' then return OLD; end if;
  return NEW;
  end if;

  select c.owner_user_id into v_owner from public.communities c where c.id=v_community_id;
  if TG_OP='INSERT' then
    if NEW.role='owner' then
      if NEW.user_id is distinct from v_owner then
        raise exception 'Owner membership must match communities.owner_user_id';
      end if;
    elsif NEW.user_id=v_actor and NEW.role='member' then
      return NEW;
    elsif not app_private.resolve_permission('community.manage_members','community',v_community_id,null,null) then
      raise exception 'You cannot add or promote community members';
    end if;
    if NEW.role='admin' and v_owner is distinct from v_actor then
      raise exception 'Only the community owner may appoint an admin';
    end if;
    if NEW.role='owner' and v_owner is distinct from NEW.user_id then
      raise exception 'Community ownership cannot be assigned through membership roles';
    end if;
    return NEW;
  elsif TG_OP='UPDATE' then
    if NEW.community_id is distinct from OLD.community_id or NEW.user_id is distinct from OLD.user_id then
      raise exception 'Community membership identity is immutable';
    end if;
    if not app_private.resolve_permission('community.manage_members','community',v_community_id,null,null) then
      raise exception 'You cannot update this community membership';
    end if;
    if NEW.role is distinct from OLD.role then
      if NEW.role='owner' or OLD.role='owner' then
        raise exception 'Community ownership requires a dedicated transfer workflow';
      end if;
      if NEW.role='admin' and v_owner is distinct from v_actor then
        raise exception 'Only the community owner may appoint an admin';
      end if;
      if v_owner is distinct from v_actor and OLD.role='admin' then
        raise exception 'Only the community owner may change an admin membership';
      end if;
    end if;
    return NEW;
  end if;
  return OLD;
end;
$function$;
revoke all on function app_private.guard_community_membership_authority() from public,anon,authenticated;

drop trigger if exists community_members_authority_guard on public.community_members;
create trigger community_members_authority_guard
before insert or update on public.community_members
for each row execute function app_private.guard_community_membership_authority();

create or replace function app_private.guard_custom_role_change()
returns trigger
language plpgsql security definer set search_path = ''
as $function$
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
    if auth.uid() is not null and NEW.is_system then
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
$function$;
revoke all on function app_private.guard_custom_role_change() from public,anon,authenticated;

drop trigger if exists community_roles_authority_guard on public.community_roles;
create trigger community_roles_authority_guard
before insert or update or delete on public.community_roles
for each row execute function app_private.guard_custom_role_change();

create or replace function app_private.guard_custom_permission_grant()
returns trigger
language plpgsql security definer set search_path = ''
as $function$
declare
  v_role_id uuid;
  v_community_id uuid;
  v_position integer;
  v_rank integer;
  v_key text;
  v_allowed boolean;
begin
  v_role_id := case when TG_OP='DELETE' then OLD.role_id else NEW.role_id end;
  v_key := case when TG_OP='DELETE' then OLD.permission_key else NEW.permission_key end;
  v_allowed := case when TG_OP='DELETE' then false else NEW.allowed end;
  select cr.community_id,cr.position into v_community_id,v_position
  from public.community_roles cr where cr.id=v_role_id;
  if not found then raise exception 'Role not found'; end if;
  if auth.uid() is null then
    if TG_OP='DELETE' then return OLD; end if;
  return NEW;
  end if;
  if not app_private.resolve_permission('community.manage_permissions','community',v_community_id,null,null) then
    raise exception 'You cannot manage permission grants in this community';
  end if;
  v_rank := app_private.community_authority_rank(v_community_id);
  if v_position >= v_rank then
    raise exception 'You cannot edit permissions for a role at or above your hierarchy level';
  end if;
  if not exists (
    select 1 from app_private.permission_definitions d
    where d.permission_key=v_key and d.scope_type='community'
  ) then
    raise exception 'Unknown or out-of-scope community permission: %',v_key;
  end if;
  if v_allowed and not app_private.resolve_permission(v_key,'community',v_community_id,null,null) then
    raise exception 'You cannot delegate a permission you do not hold';
  end if;
  if TG_OP <> 'DELETE' then
    return NEW;
  end if;
  return OLD;
end;
$function$;
revoke all on function app_private.guard_custom_permission_grant() from public,anon,authenticated;

drop trigger if exists role_permissions_authority_guard on public.role_permissions;
create trigger role_permissions_authority_guard
before insert or update or delete on public.role_permissions
for each row execute function app_private.guard_custom_permission_grant();

create or replace function app_private.guard_custom_role_assignment()
returns trigger
language plpgsql security definer set search_path = ''
as $function$
declare
  v_position integer;
  v_rank integer;
  v_has_community boolean;
begin
  if auth.uid() is null then
    if TG_OP='DELETE' then return OLD; end if;
  return NEW;
  end if;
  if TG_OP='DELETE' then
    if not app_private.resolve_permission('community.manage_roles','community',OLD.community_id,null,null) then
      raise exception 'You cannot remove community roles';
    end if;
    select cr.position into v_position from public.community_roles cr
    where cr.id=OLD.role_id and cr.community_id=OLD.community_id;
    v_rank := app_private.community_authority_rank(OLD.community_id);
    if v_position is null or v_position >= v_rank then
      raise exception 'You cannot remove a role at or above your hierarchy level';
    end if;
    return OLD;
  end if;

  if NEW.assigned_by is distinct from auth.uid() then
    raise exception 'Role assignment actor must be the authenticated user';
  end if;
  if not app_private.resolve_permission('community.manage_roles','community',NEW.community_id,null,null) then
    raise exception 'You cannot assign community roles';
  end if;
  select cr.position into v_position from public.community_roles cr
  where cr.id=NEW.role_id and cr.community_id=NEW.community_id;
  v_rank := app_private.community_authority_rank(NEW.community_id);
  if v_position is null or v_position >= v_rank then
    raise exception 'You cannot assign a role at or above your hierarchy level';
  end if;
  if not exists (
    select 1 from public.community_members cm
    where cm.community_id=NEW.community_id and cm.user_id=NEW.user_id
  ) then
    raise exception 'Only an existing community member can receive a custom role';
  end if;
  if exists (
    select 1
    from public.role_permissions rp
    where rp.role_id=NEW.role_id and rp.allowed
      and not app_private.resolve_permission(rp.permission_key,'community',NEW.community_id,null,null)
  ) then
    raise exception 'This role contains permissions that exceed your own authority';
  end if;
  return NEW;
end;
$function$;
revoke all on function app_private.guard_custom_role_assignment() from public,anon,authenticated;

drop trigger if exists community_member_roles_authority_guard on public.community_member_roles;
create trigger community_member_roles_authority_guard
before insert or update or delete on public.community_member_roles
for each row execute function app_private.guard_custom_role_assignment();

create or replace function app_private.event_staff_authority_rank(p_event_id uuid)
returns integer language plpgsql stable security definer set search_path = ''
as $function$
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
  where a.event_id=p_event_id and a.user_id=(select auth.uid());
  return v_rank;
end;
$function$;
revoke all on function app_private.event_staff_authority_rank(uuid) from public,anon,authenticated;
grant execute on function app_private.event_staff_authority_rank(uuid) to authenticated;

create or replace function app_private.guard_event_staff_assignment()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_event_id uuid;
  v_target_role text;
  v_rank integer;
  v_target_rank integer;
begin
  v_event_id := case when TG_OP='DELETE' then OLD.event_id else NEW.event_id end;
  v_target_role := case when TG_OP='DELETE' then OLD.role_key else NEW.role_key end;
  if auth.uid() is null then
    if TG_OP='DELETE' then return OLD; end if;
  return NEW;
  end if;
  if not app_private.resolve_permission('event.staff.assign','event',v_event_id,null,null) then
    raise exception 'You cannot assign event staff in this event';
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
  if TG_OP <> 'DELETE' and NEW.assigned_by is distinct from auth.uid() then
    raise exception 'Event staff assignment actor must be the authenticated user';
  end if;
  if TG_OP='DELETE' then return OLD; end if;
  return NEW;
end;
$function$;
revoke all on function app_private.guard_event_staff_assignment() from public,anon,authenticated;

drop trigger if exists event_staff_assignments_authority_guard on public.event_staff_assignments;
create trigger event_staff_assignments_authority_guard
before insert or update or delete on public.event_staff_assignments
for each row execute function app_private.guard_event_staff_assignment();

create or replace function app_private.guard_channel_permission_override()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_community_id uuid;
  v_role_id uuid;
  v_permission text;
  v_effect text;
  v_position integer;
  v_rank integer;
begin
  v_community_id := case when TG_OP='DELETE' then OLD.community_id else NEW.community_id end;
  v_role_id := case when TG_OP='DELETE' then OLD.role_id else NEW.role_id end;
  v_permission := case when TG_OP='DELETE' then OLD.permission_key else NEW.permission_key end;
  v_effect := case when TG_OP='DELETE' then OLD.effect else NEW.effect end;
  if auth.uid() is null then
    if TG_OP='DELETE' then return OLD; end if;
  return NEW;
  end if;
  if not app_private.resolve_permission('community.manage_permissions','community',v_community_id,null,null) then
    raise exception 'You cannot manage channel permission overrides';
  end if;
  if not exists (
    select 1 from app_private.permission_definitions d
    where d.permission_key=v_permission and d.scope_type='community'
  ) then
    raise exception 'Unknown or out-of-scope channel permission: %',v_permission;
  end if;
  select cr.position into v_position from public.community_roles cr
  where cr.id=v_role_id and cr.community_id=v_community_id;
  v_rank := app_private.community_authority_rank(v_community_id);
  if v_position is null or v_position >= v_rank then
    raise exception 'You cannot override permissions for a role at or above your hierarchy level';
  end if;
  if v_effect='allow' and not app_private.resolve_permission(v_permission,'community',v_community_id,null,null) then
    raise exception 'You cannot allow a permission you do not hold';
  end if;
  if TG_OP <> 'DELETE' then
    if NEW.updated_by is distinct from auth.uid() then
      raise exception 'Permission override actor must be the authenticated user';
    end if;
    return NEW;
  end if;
  return OLD;
end;
$function$;
revoke all on function app_private.guard_channel_permission_override() from public,anon,authenticated;

drop trigger if exists channel_permission_overrides_authority_guard on public.channel_permission_overrides;
create trigger channel_permission_overrides_authority_guard
before insert or update or delete on public.channel_permission_overrides
for each row execute function app_private.guard_channel_permission_override();

create or replace function app_private.guard_liveops_session_scope()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_match_event uuid;
begin
  if TG_OP='INSERT' then
    if NEW.match_id is null then raise exception 'LiveOps sessions must be bound to a platform match ID'; end if;
    select m.event_id into v_match_event from public.matches m where m.id=NEW.match_id;
    if not found or v_match_event is distinct from NEW.event_id then
      raise exception 'LiveOps session event and match scope do not match';
    end if;
    if auth.uid() is not null then
      if NEW.operator_id is distinct from auth.uid() then
        raise exception 'LiveOps operator must be the authenticated user';
      end if;
      if not app_private.resolve_permission('liveops.session.manage','match',NEW.match_id,null,null) then
        raise exception 'You are not authorised to operate this match';
      end if;
    end if;
    return NEW;
  end if;

  if NEW.id is distinct from OLD.id
     or NEW.operator_id is distinct from OLD.operator_id
     or NEW.match_id is distinct from OLD.match_id
     or NEW.event_id is distinct from OLD.event_id
     or NEW.started_at is distinct from OLD.started_at then
    raise exception 'LiveOps session identity and match binding are immutable';
  end if;
  if auth.uid() is not null and OLD.operator_id is distinct from auth.uid() then
    raise exception 'Only the LiveOps session operator may update it';
  end if;
  if NEW.state is distinct from OLD.state and not (
    (OLD.state='created' and NEW.state in ('capturing','failed'))
    or (OLD.state='capturing' and NEW.state in ('paused','stopped','failed'))
    or (OLD.state='paused' and NEW.state in ('capturing','stopped','failed'))
  ) then
    raise exception 'Invalid LiveOps session state transition';
  end if;
  return NEW;
end;
$function$;
revoke all on function app_private.guard_liveops_session_scope() from public,anon,authenticated;

drop trigger if exists liveops_sessions_scope_guard on public.liveops_sessions;
create trigger liveops_sessions_scope_guard
before insert or update on public.liveops_sessions
for each row execute function app_private.guard_liveops_session_scope();

create or replace function app_private.start_liveops_session(
  p_match_id uuid,
  p_device_info jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = ''
as $function$
declare
  v_event_id uuid;
  v_session_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_match_id is null then raise exception 'Select a platform Match ID before starting LiveOps'; end if;
  select m.event_id into v_event_id from public.matches m where m.id=p_match_id;
  if not found then raise exception 'Match not found'; end if;
  if not app_private.resolve_permission('liveops.session.manage','match',p_match_id,null,null) then
    raise exception 'You are not authorised to start LiveOps for this match';
  end if;
  insert into public.liveops_sessions(operator_id,match_id,event_id,state,started_at,device_info)
  values (auth.uid(),p_match_id,v_event_id,'created',now(),coalesce(p_device_info,'{}'::jsonb))
  returning id into v_session_id;
  return jsonb_build_object('session_id',v_session_id,'match_id',p_match_id,'event_id',v_event_id,'state','created');
end;
$function$;
revoke all on function app_private.start_liveops_session(uuid,jsonb) from public,anon;
grant execute on function app_private.start_liveops_session(uuid,jsonb) to authenticated;

create or replace function public.start_liveops_session(
  p_match_id uuid,
  p_device_info jsonb default '{}'::jsonb
) returns jsonb
language sql security invoker set search_path = ''
as $function$
  select app_private.start_liveops_session(p_match_id,p_device_info);
$function$;
revoke all on function public.start_liveops_session(uuid,jsonb) from public,anon;
grant execute on function public.start_liveops_session(uuid,jsonb) to authenticated;

create or replace function app_private.guard_audit_log_insert()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  if auth.uid() is not null then
    if NEW.actor_id is null then NEW.actor_id := auth.uid(); end if;
    if NEW.actor_id is distinct from auth.uid() then
      raise exception 'Audit actor must match the authenticated user';
    end if;
  end if;
  if NEW.entity_type is null or char_length(trim(NEW.entity_type))=0
     or NEW.action is null or char_length(trim(NEW.action))=0
     or jsonb_typeof(NEW.metadata) is distinct from 'object' then
    raise exception 'Audit records require an entity, action and object metadata';
  end if;
  return NEW;
end;
$function$;
revoke all on function app_private.guard_audit_log_insert() from public,anon,authenticated;

create or replace function app_private.reject_audit_log_mutation()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  raise exception 'Audit history is append-only; UPDATE and DELETE are prohibited';
end;
$function$;
revoke all on function app_private.reject_audit_log_mutation() from public,anon,authenticated;

create or replace function app_private.audit_sensitive_change()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_old jsonb := case when TG_OP in ('UPDATE','DELETE') then to_jsonb(OLD) else null end;
  v_new jsonb := case when TG_OP in ('INSERT','UPDATE') then to_jsonb(NEW) else null end;
  v_row jsonb;
  v_community_id uuid;
  v_event_id uuid;
  v_entity_id uuid;
  v_entity_type text;
  v_action text;
  v_metadata jsonb;
begin
  v_row := coalesce(v_new,v_old);
  v_entity_type := TG_TABLE_NAME;
  if TG_TABLE_NAME='role_permissions' then
    v_entity_type := 'community_role_permission';
    v_entity_id := nullif(v_row->>'role_id','')::uuid;
    select cr.community_id into v_community_id from public.community_roles cr
    where cr.id=v_entity_id;
  elsif TG_TABLE_NAME='community_member_roles' then
    v_entity_type := 'community_member_role';
    v_entity_id := nullif(v_row->>'user_id','')::uuid;
    v_community_id := nullif(v_row->>'community_id','')::uuid;
  elsif TG_TABLE_NAME='community_members' then
    v_entity_type := 'community_member';
    v_entity_id := nullif(v_row->>'user_id','')::uuid;
    v_community_id := nullif(v_row->>'community_id','')::uuid;
  elsif TG_TABLE_NAME='community_roles' then
    v_entity_type := 'community_role';
    v_entity_id := nullif(v_row->>'id','')::uuid;
    v_community_id := nullif(v_row->>'community_id','')::uuid;
  elsif TG_TABLE_NAME='event_staff_assignments' then
    v_entity_type := 'event_staff_assignment';
    v_entity_id := nullif(v_row->>'id','')::uuid;
    v_event_id := nullif(v_row->>'event_id','')::uuid;
  elsif TG_TABLE_NAME='channel_permission_overrides' then
    v_entity_type := 'channel_permission_override';
    v_entity_id := nullif(v_row->>'channel_id','')::uuid;
    v_community_id := nullif(v_row->>'community_id','')::uuid;
  elsif TG_TABLE_NAME='liveops_sessions' then
    v_entity_type := 'liveops_session';
    v_entity_id := nullif(v_row->>'id','')::uuid;
    v_event_id := nullif(v_row->>'event_id','')::uuid;
  end if;

  v_action := lower(TG_TABLE_NAME) || '_' || lower(TG_OP);
  if TG_TABLE_NAME='liveops_sessions' then
    v_metadata := jsonb_build_object(
      'before',case when v_old is null then null else jsonb_build_object('match_id',v_old->'match_id','state',v_old->'state') end,
      'after',case when v_new is null then null else jsonb_build_object('match_id',v_new->'match_id','state',v_new->'state') end
    );
  else
    v_metadata := jsonb_build_object('before',v_old,'after',v_new);
  end if;

  insert into public.audit_logs(actor_id,community_id,event_id,entity_type,entity_id,action,reason,metadata)
  values (
    (select auth.uid()),v_community_id,v_event_id,v_entity_type,v_entity_id,
    v_action,coalesce(v_row->>'reason',null),v_metadata
  );

  if TG_OP='DELETE' then return OLD; end if;
  return NEW;
end;
$function$;
revoke all on function app_private.audit_sensitive_change() from public,anon,authenticated;

drop trigger if exists audit_logs_insert_actor_guard on public.audit_logs;
create trigger audit_logs_insert_actor_guard
before insert on public.audit_logs
for each row execute function app_private.guard_audit_log_insert();

drop trigger if exists audit_logs_no_update_delete on public.audit_logs;
create trigger audit_logs_no_update_delete
before update or delete on public.audit_logs
for each row execute function app_private.reject_audit_log_mutation();

drop trigger if exists audit_community_members_change on public.community_members;
create trigger audit_community_members_change after insert or update or delete on public.community_members
for each row execute function app_private.audit_sensitive_change();
drop trigger if exists audit_community_roles_change on public.community_roles;
create trigger audit_community_roles_change after insert or update or delete on public.community_roles
for each row execute function app_private.audit_sensitive_change();
drop trigger if exists audit_community_member_roles_change on public.community_member_roles;
create trigger audit_community_member_roles_change after insert or update or delete on public.community_member_roles
for each row execute function app_private.audit_sensitive_change();
drop trigger if exists audit_role_permissions_change on public.role_permissions;
create trigger audit_role_permissions_change after insert or update or delete on public.role_permissions
for each row execute function app_private.audit_sensitive_change();
drop trigger if exists audit_event_staff_assignments_change on public.event_staff_assignments;
create trigger audit_event_staff_assignments_change after insert or update or delete on public.event_staff_assignments
for each row execute function app_private.audit_sensitive_change();
drop trigger if exists audit_channel_permission_overrides_change on public.channel_permission_overrides;
create trigger audit_channel_permission_overrides_change after insert or update or delete on public.channel_permission_overrides
for each row execute function app_private.audit_sensitive_change();
drop trigger if exists audit_liveops_sessions_change on public.liveops_sessions;
create trigger audit_liveops_sessions_change after insert or update on public.liveops_sessions
for each row execute function app_private.audit_sensitive_change();

-- Audit scope columns are historical identifiers, not cascading ownership links.
alter table public.audit_logs drop constraint if exists audit_logs_community_id_fkey;
alter table public.audit_logs drop constraint if exists audit_logs_event_id_fkey;
drop policy if exists audit_logs_insert_staff on public.audit_logs;
drop policy if exists audit_logs_read_staff on public.audit_logs;
create policy audit_logs_read_scoped on public.audit_logs
for select to authenticated
using (
  (community_id is not null and app_private.resolve_permission('community.audit.read','community',community_id,null,null))
  or
  (event_id is not null and app_private.resolve_permission('event.audit.read','event',event_id,null,null))
);
revoke insert,update,delete,truncate on public.audit_logs from public,anon,authenticated;
grant select on public.audit_logs to authenticated;

-- Community channels now resolve visibility and actions through the same server-side permission engine.
drop policy if exists channels_read_member on public.channels;
create policy channels_read_member on public.channels
for select to authenticated
using (
  (event_id is not null and app_private.can_access_event_channel(event_id,group_id,match_id))
  or
  (event_id is null and community_id is not null
    and app_private.resolve_permission('channel.view','community',community_id,null,id))
  or
  (community_id is null and app_private.is_channel_member(id))
);

drop policy if exists channels_create_manager on public.channels;
create policy channels_create_manager on public.channels
for insert to authenticated
with check (
  (event_id is null and community_id is not null
    and app_private.resolve_permission('community.manage_structure','community',community_id,null,null))
  or
  (event_id is not null
    and app_private.resolve_permission('event.matches.operate','event',event_id,null,null))
);

drop policy if exists channels_update_manager on public.channels;
create policy channels_update_manager on public.channels
for update to authenticated
using (
  (event_id is null and community_id is not null
    and app_private.resolve_permission('community.manage_structure','community',community_id,null,null))
  or
  (event_id is not null
    and app_private.resolve_permission('event.matches.operate','event',event_id,null,null))
)
with check (
  (event_id is null and community_id is not null
    and app_private.resolve_permission('community.manage_structure','community',community_id,null,null))
  or
  (event_id is not null
    and app_private.resolve_permission('event.matches.operate','event',event_id,null,null))
);

drop policy if exists channel_categories_write_staff on public.channel_categories;
create policy channel_categories_write_staff on public.channel_categories
for all to authenticated
using (
  (event_id is null and app_private.resolve_permission('community.manage_structure','community',community_id,null,null))
  or
  (event_id is not null and app_private.resolve_permission('event.matches.operate','event',event_id,null,null))
)
with check (
  (event_id is null and app_private.resolve_permission('community.manage_structure','community',community_id,null,null))
  or
  (event_id is not null and app_private.resolve_permission('event.matches.operate','event',event_id,null,null))
);

drop policy if exists channel_members_add_manager on public.channel_members;
create policy channel_members_add_manager on public.channel_members
for insert to authenticated
with check (
  exists (
    select 1 from public.channels c
    where c.id=channel_id and c.community_id is not null and c.is_private
      and app_private.resolve_permission('community.manage_structure','community',c.community_id,null,null)
  )
);

drop policy if exists channel_members_add_self on public.channel_members;
create policy channel_members_add_self on public.channel_members
for insert to authenticated
with check (
  user_id=(select auth.uid())
  and exists (
    select 1 from public.channels c
    where c.id=channel_id and c.community_id is not null and not c.is_private
      and app_private.resolve_permission('channel.view','community',c.community_id,null,c.id)
  )
);

drop policy if exists messages_read_channel_member on public.messages;
create policy messages_read_channel_member on public.messages
for select to authenticated
using (
  exists (
    select 1 from public.channels c
    where c.id=messages.channel_id
      and (
        (c.event_id is not null and app_private.can_access_event_channel(c.event_id,c.group_id,c.match_id))
        or
        (c.event_id is null and c.community_id is not null
          and app_private.resolve_permission('channel.view','community',c.community_id,null,c.id))
        or
        (c.community_id is null and app_private.is_channel_member(c.id))
      )
  )
);

drop policy if exists messages_send_channel_member on public.messages;
create policy messages_send_channel_member on public.messages
for insert to authenticated
with check (
  sender_id=(select auth.uid())
  and exists (
    select 1 from public.channels c
    where c.id=messages.channel_id
      and c.archived_at is null
      and (
        (c.event_id is not null and app_private.can_access_event_channel(c.event_id,c.group_id,c.match_id))
        or
        (c.event_id is null and c.community_id is not null
          and app_private.resolve_permission('channel.send_messages','community',c.community_id,null,c.id))
        or
        (c.community_id is null and app_private.is_channel_member(c.id))
      )
  )
);

drop policy if exists messages_update_sender_or_manager on public.messages;
create policy messages_update_sender_or_manager on public.messages
for update to authenticated
using (
  sender_id=(select auth.uid())
  or exists (
    select 1 from public.channels c
    where c.id=messages.channel_id and c.community_id is not null
      and app_private.resolve_permission('channel.manage_messages','community',c.community_id,null,c.id)
  )
)
with check (
  sender_id=(select auth.uid())
  and exists (
    select 1 from public.channels c
    where c.id=messages.channel_id and (
      (c.community_id is not null and app_private.resolve_permission('channel.view','community',c.community_id,null,c.id))
      or (c.community_id is null and app_private.is_channel_member(c.id))
    )
  )
  or exists (
    select 1 from public.channels c
    where c.id=messages.channel_id and c.community_id is not null
      and app_private.resolve_permission('channel.manage_messages','community',c.community_id,null,c.id)
  )
);

drop policy if exists message_attachments_read_channel_member on public.message_attachments;
create policy message_attachments_read_channel_member on public.message_attachments
for select to authenticated
using (
  exists (
    select 1 from public.messages m
    join public.channels c on c.id=m.channel_id
    where m.id=message_attachments.message_id
      and (
        (c.event_id is not null and app_private.can_access_event_channel(c.event_id,c.group_id,c.match_id))
        or
        (c.event_id is null and c.community_id is not null
          and app_private.resolve_permission('channel.view','community',c.community_id,null,c.id))
        or
        (c.community_id is null and app_private.is_channel_member(c.id))
      )
  )
);

drop policy if exists reactions_read_channel_member on public.message_reactions;
create policy reactions_read_channel_member on public.message_reactions
for select to authenticated
using (
  exists (
    select 1 from public.messages m
    join public.channels c on c.id=m.channel_id
    where m.id=message_reactions.message_id
      and (
        (c.event_id is not null and app_private.can_access_event_channel(c.event_id,c.group_id,c.match_id))
        or
        (c.event_id is null and c.community_id is not null
          and app_private.resolve_permission('channel.view','community',c.community_id,null,c.id))
        or
        (c.community_id is null and app_private.is_channel_member(c.id))
      )
  )
);

drop policy if exists reactions_manage_self on public.message_reactions;
create policy reactions_manage_self on public.message_reactions
for all to authenticated
using (
  user_id=(select auth.uid())
  and exists (
    select 1 from public.messages m
    join public.channels c on c.id=m.channel_id
    where m.id=message_reactions.message_id
      and (
        (c.community_id is not null and app_private.resolve_permission('channel.react','community',c.community_id,null,c.id))
        or (c.community_id is null and app_private.is_channel_member(c.id))
      )
  )
)
with check (
  user_id=(select auth.uid())
  and exists (
    select 1 from public.messages m
    join public.channels c on c.id=m.channel_id
    where m.id=message_reactions.message_id
      and (
        (c.community_id is not null and app_private.resolve_permission('channel.react','community',c.community_id,null,c.id))
        or (c.community_id is null and app_private.is_channel_member(c.id))
      )
  )
);

-- Match check-ins are tied to the signed-in user's current team membership in that exact match.
drop policy if exists checkins_upsert_self on public.match_checkins;
create policy checkins_upsert_self on public.match_checkins
for insert to authenticated
with check (
  user_id=(select auth.uid())
  and exists (
    select 1
    from public.match_participants mp
    join public.team_members tm on tm.team_id=mp.team_id
    where mp.match_id=public.match_checkins.match_id
      and tm.user_id=(select auth.uid())
  )
);

drop policy if exists checkins_update_self on public.match_checkins;
create policy checkins_update_self on public.match_checkins
for update to authenticated
using (
  user_id=(select auth.uid())
  and exists (
    select 1
    from public.match_participants mp
    join public.team_members tm on tm.team_id=mp.team_id
    where mp.match_id=public.match_checkins.match_id
      and tm.user_id=(select auth.uid())
  )
)
with check (
  user_id=(select auth.uid())
  and exists (
    select 1
    from public.match_participants mp
    join public.team_members tm on tm.team_id=mp.team_id
    where mp.match_id=public.match_checkins.match_id
      and tm.user_id=(select auth.uid())
  )
);

-- Room credentials may only be created through the audited, match-scoped RPC.
drop policy if exists room_credentials_create_staff on public.room_credentials;
revoke insert,update,delete,truncate on public.room_credentials from public,anon,authenticated;
grant select on public.room_credentials to authenticated;

drop policy if exists room_credentials_read_eligible on public.room_credentials;
create policy room_credentials_read_eligible on public.room_credentials
for select to authenticated
using (
  app_private.resolve_permission('match.credentials.release','match',match_id,null,null)
  or (
    release_at <= now()
    and exists (
      select 1
      from public.match_participants mp
      join public.team_members tm on tm.team_id=mp.team_id
      where mp.match_id=room_credentials.match_id
        and mp.check_in_status='ready'
        and tm.user_id=(select auth.uid())
    )
  )
);

-- Bind every LiveOps session and capture to the same exact platform match.
drop policy if exists liveops_sessions_insert_self on public.liveops_sessions;
create policy liveops_sessions_insert_self on public.liveops_sessions
for insert to authenticated
with check (
  operator_id=(select auth.uid())
  and match_id is not null
  and exists (
    select 1 from public.matches m
    where m.id=liveops_sessions.match_id
      and m.event_id=liveops_sessions.event_id
      and app_private.resolve_permission('liveops.session.manage','match',m.id,null,null)
  )
);

drop policy if exists liveops_sessions_read_owner_or_staff on public.liveops_sessions;
create policy liveops_sessions_read_owner_or_staff on public.liveops_sessions
for select to authenticated
using (
  operator_id=(select auth.uid())
  or app_private.resolve_permission('liveops.capture.read','match',match_id,null,null)
);

drop policy if exists liveops_sessions_update_owner on public.liveops_sessions;
create policy liveops_sessions_update_owner on public.liveops_sessions
for update to authenticated
using (
  operator_id=(select auth.uid())
  and app_private.resolve_permission('liveops.session.manage','match',match_id,null,null)
)
with check (
  operator_id=(select auth.uid())
  and app_private.resolve_permission('liveops.session.manage','match',match_id,null,null)
);

drop policy if exists liveops_captures_insert_operator on public.liveops_captures;
create policy liveops_captures_insert_operator on public.liveops_captures
for insert to authenticated
with check (
  operator_id=(select auth.uid())
  and split_part(evidence_path,'/',1)=(select auth.uid())::text
  and exists (
    select 1
    from public.liveops_sessions s
    join public.matches m on m.id=s.match_id
    where s.id=liveops_captures.session_id
      and s.operator_id=(select auth.uid())
      and s.match_id=liveops_captures.match_id
      and s.event_id=liveops_captures.event_id
      and m.id=liveops_captures.match_id
      and m.event_id=liveops_captures.event_id
      and app_private.resolve_permission('liveops.capture.submit','match',m.id,null,null)
  )
);

drop policy if exists liveops_captures_read_operator_or_staff on public.liveops_captures;
create policy liveops_captures_read_operator_or_staff on public.liveops_captures
for select to authenticated
using (
  operator_id=(select auth.uid())
  or app_private.resolve_permission('liveops.capture.read','match',match_id,null,null)
);

drop policy if exists liveops_captures_review_staff on public.liveops_captures;
create policy liveops_captures_review_staff on public.liveops_captures
for update to authenticated
using (
  app_private.resolve_permission('liveops.capture.read','match',match_id,null,null)
)
with check (
  app_private.resolve_permission('liveops.capture.read','match',match_id,null,null)
);

comment on function app_private.resolve_permission(text,text,uuid,uuid,uuid) is
  'Canonical fail-closed server-side permission resolver. Uses auth.uid(), real scope IDs and explicit resource IDs; never trusts client-supplied actor IDs or display labels.';
comment on function public.has_permission(text,text,uuid,uuid,uuid) is
  'Authenticated read-only permission preview endpoint. Authoritative enforcement remains in RLS and privileged RPCs.';
comment on table public.audit_logs is
  'Append-only audit history. Direct authenticated INSERT/UPDATE/DELETE/TRUNCATE is revoked; trusted RPCs and security triggers append records.';


-- Use the canonical resolver for team, stage, group and match data access.
drop policy if exists teams_read_visible on public.teams;
create policy teams_read_visible on public.teams
for select to authenticated
using (app_private.resolve_permission('team.view','team',id,null,null));

drop policy if exists teams_update_owner on public.teams;
create policy teams_update_owner on public.teams
for update to authenticated
using (app_private.resolve_permission('team.manage','team',id,null,null))
with check (app_private.resolve_permission('team.manage','team',id,null,null));

drop policy if exists team_members_read_roster on public.team_members;
create policy team_members_read_roster on public.team_members
for select to authenticated
using (app_private.resolve_permission('team.view','team',team_id,null,null));

drop policy if exists team_members_leave on public.team_members;
create policy team_members_leave on public.team_members
for delete to authenticated
using (
  user_id=(select auth.uid())
  or app_private.resolve_permission('team.manage','team',team_id,null,null)
);

drop policy if exists team_invites_create_captain on public.team_invites;
create policy team_invites_create_captain on public.team_invites
for insert to authenticated
with check (
  invited_by=(select auth.uid())
  and app_private.resolve_permission('team.manage','team',team_id,null,null)
);

drop policy if exists team_invites_participants on public.team_invites;
create policy team_invites_participants on public.team_invites
for select to authenticated
using (
  invited_user_id=(select auth.uid())
  or invited_by=(select auth.uid())
  or app_private.resolve_permission('team.view','team',team_id,null,null)
);

drop policy if exists team_invites_respond_invitee on public.team_invites;
create policy team_invites_respond_invitee on public.team_invites
for update to authenticated
using (
  invited_user_id=(select auth.uid())
  or (
    invited_by=(select auth.uid())
    and app_private.resolve_permission('team.manage','team',team_id,null,null)
  )
)
with check (
  invited_user_id=(select auth.uid())
  or (
    invited_by=(select auth.uid())
    and status='cancelled'
    and app_private.resolve_permission('team.manage','team',team_id,null,null)
  )
);

create or replace function app_private.guard_team_invite_response()
returns trigger language plpgsql security definer set search_path = ''
as $function$
begin
  if NEW.id is distinct from OLD.id
     or NEW.team_id is distinct from OLD.team_id
     or NEW.invited_user_id is distinct from OLD.invited_user_id
     or NEW.invited_by is distinct from OLD.invited_by
     or NEW.expires_at is distinct from OLD.expires_at
     or NEW.created_at is distinct from OLD.created_at then
    raise exception 'Team invite identity and scope are immutable';
  end if;
  if OLD.status <> 'pending' then
    raise exception 'Only a pending team invite may be updated';
  end if;
  if auth.uid() = OLD.invited_user_id then
    if NEW.status not in ('accepted','declined') then
      raise exception 'Invitees may only accept or decline their invitation';
    end if;
  elsif auth.uid() = OLD.invited_by
     and NEW.status = 'cancelled'
     and app_private.resolve_permission('team.manage','team',OLD.team_id,null,null) then
    null;
  else
    raise exception 'Only the invited user may respond or the inviter may cancel this invite';
  end if;
  return NEW;
end;
$function$;
revoke all on function app_private.guard_team_invite_response() from public,anon,authenticated;
drop trigger if exists team_invites_response_guard on public.team_invites;
create trigger team_invites_response_guard
before update on public.team_invites
for each row execute function app_private.guard_team_invite_response();

drop policy if exists events_read_published on public.events;
create policy events_read_published on public.events
for select to authenticated
using (app_private.resolve_permission('event.view','event',id,null,null));

drop policy if exists event_rounds_read_visible on public.event_rounds;
create policy event_rounds_read_visible on public.event_rounds
for select to authenticated
using (app_private.resolve_permission('stage.view','stage',id,null,null));

drop policy if exists event_rounds_manage_staff on public.event_rounds;
create policy event_rounds_manage_staff on public.event_rounds
for all to authenticated
using (app_private.resolve_permission('stage.manage','stage',id,null,null))
with check (app_private.resolve_permission('stage.manage','stage',id,null,null));

drop policy if exists event_groups_read_visible on public.event_groups;
create policy event_groups_read_visible on public.event_groups
for select to authenticated
using (app_private.resolve_permission('group.view','group',id,null,null));

drop policy if exists event_groups_manage_staff on public.event_groups;
create policy event_groups_manage_staff on public.event_groups
for all to authenticated
using (app_private.resolve_permission('group.manage','group',id,null,null))
with check (app_private.resolve_permission('group.manage','group',id,null,null));

drop policy if exists event_group_teams_read_visible on public.event_group_teams;
create policy event_group_teams_read_visible on public.event_group_teams
for select to authenticated
using (app_private.resolve_permission('group.view','group',group_id,null,null));

drop policy if exists event_group_teams_manage_staff on public.event_group_teams;
create policy event_group_teams_manage_staff on public.event_group_teams
for all to authenticated
using (app_private.resolve_permission('group.manage','group',group_id,null,null))
with check (app_private.resolve_permission('group.manage','group',group_id,null,null));

drop policy if exists matches_read_event_members on public.matches;
create policy matches_read_event_members on public.matches
for select to authenticated
using (app_private.resolve_permission('match.view','match',id,null,null));

drop policy if exists matches_read_published_event on public.matches;
create policy matches_read_published_event on public.matches
for select to authenticated
using (app_private.resolve_permission('event.view','event',event_id,null,null));

drop policy if exists matches_create_staff on public.matches;
create policy matches_create_staff on public.matches
for insert to authenticated
with check (app_private.resolve_permission('event.matches.manage','event',event_id,null,null));

drop policy if exists matches_update_staff on public.matches;
create policy matches_update_staff on public.matches
for update to authenticated
using (app_private.resolve_permission('event.matches.manage','event',event_id,null,null))
with check (app_private.resolve_permission('event.matches.manage','event',event_id,null,null));

drop policy if exists participants_manage_staff on public.match_participants;
create policy participants_manage_staff on public.match_participants
for all to authenticated
using (app_private.resolve_permission('match.operate','match',match_id,null,null))
with check (app_private.resolve_permission('match.operate','match',match_id,null,null));

drop policy if exists participants_read_team_or_staff on public.match_participants;
create policy participants_read_team_or_staff on public.match_participants
for select to authenticated
using (
  app_private.resolve_permission('participant.view','participant',match_id,team_id,null)
);

drop policy if exists checkins_read_self_or_staff on public.match_checkins;
create policy checkins_read_self_or_staff on public.match_checkins
for select to authenticated
using (
  user_id=(select auth.uid())
  or exists (
    select 1 from public.matches m
    where m.id=match_checkins.match_id
      and app_private.resolve_permission('event.checkin.manage','event',m.event_id,null,null)
  )
);

drop policy if exists standings_write_staff on public.event_stage_standings;
create policy standings_write_staff on public.event_stage_standings
for all to authenticated
using (app_private.resolve_permission('event.standings.publish','event',event_id,null,null))
with check (app_private.resolve_permission('event.standings.publish','event',event_id,null,null));

drop policy if exists disputes_decide_staff on public.result_disputes;
create policy disputes_decide_staff on public.result_disputes
for update to authenticated
using (
  exists (
    select 1 from public.match_results r
    join public.matches m on m.id=r.match_id
    where r.id=result_disputes.result_id
      and app_private.resolve_permission('event.disputes.review','event',m.event_id,null,null)
  )
)
with check (
  exists (
    select 1 from public.match_results r
    join public.matches m on m.id=r.match_id
    where r.id=result_disputes.result_id
      and app_private.resolve_permission('event.disputes.review','event',m.event_id,null,null)
  )
);

drop policy if exists disputes_read_reporter_or_staff on public.result_disputes;
create policy disputes_read_reporter_or_staff on public.result_disputes
for select to authenticated
using (
  opened_by=(select auth.uid())
  or exists (
    select 1 from public.match_results r
    join public.matches m on m.id=r.match_id
    where r.id=result_disputes.result_id
      and (
        app_private.resolve_permission('event.disputes.review','event',m.event_id,null,null)
        or app_private.resolve_permission('event.results.review','event',m.event_id,null,null)
      )
  )
);

drop policy if exists evidence_insert_owner_or_staff on public.result_evidence;
create policy evidence_insert_owner_or_staff on public.result_evidence
for insert to authenticated
with check (
  uploaded_by=(select auth.uid())
  and exists (
    select 1 from public.match_results r
    join public.matches m on m.id=r.match_id
    where r.id=result_evidence.result_id
      and (
        app_private.is_team_member(r.team_id)
        or app_private.resolve_permission('event.results.review','event',m.event_id,null,null)
      )
  )
);

drop policy if exists liveops_captures_review_staff on public.liveops_captures;
create policy liveops_captures_review_staff on public.liveops_captures
for update to authenticated
using (
  exists (
    select 1 from public.liveops_sessions s
    where s.id=liveops_captures.session_id
      and app_private.resolve_permission('liveops.capture.review','liveops_session',s.id,null,null)
  )
)
with check (
  exists (
    select 1 from public.liveops_sessions s
    where s.id=liveops_captures.session_id
      and app_private.resolve_permission('liveops.capture.review','liveops_session',s.id,null,null)
  )
);

drop policy if exists room_credentials_read_eligible on public.room_credentials;
create policy room_credentials_read_eligible on public.room_credentials
for select to authenticated
using (
  app_private.resolve_permission('match.credentials.release','match',match_id,null,null)
  or (
    release_at <= now()
    and app_private.resolve_permission('match.credentials.read','match',match_id,null,null)
  )
);

-- A user-created role may never claim the protected system-role flag.


-- A capture's identity and source are immutable once submitted; reviewers can only
-- change review fields, never retarget evidence to another match/session.
create or replace function app_private.guard_liveops_capture_scope()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_match_event uuid;
  v_session_operator uuid;
  v_session_match uuid;
  v_session_event uuid;
begin
  if TG_OP='INSERT' then
    select s.operator_id,s.match_id,s.event_id,m.event_id
      into v_session_operator,v_session_match,v_session_event,v_match_event
    from public.liveops_sessions s
    join public.matches m on m.id=s.match_id
    where s.id=NEW.session_id;
    if not found
       or v_session_operator is distinct from NEW.operator_id
       or v_session_match is distinct from NEW.match_id
       or v_session_event is distinct from NEW.event_id
       or v_match_event is distinct from NEW.event_id then
      raise exception 'Capture must be bound to its operator session, match and event';
    end if;
    if auth.uid() is not null then
      if NEW.operator_id is distinct from auth.uid()
         or not app_private.resolve_permission('liveops.capture.submit','match',NEW.match_id,null,null) then
        raise exception 'You are not authorised to attach evidence to this match';
      end if;
    end if;
    return NEW;
  end if;

  if NEW.id is distinct from OLD.id
     or NEW.session_id is distinct from OLD.session_id
     or NEW.event_id is distinct from OLD.event_id
     or NEW.match_id is distinct from OLD.match_id
     or NEW.operator_id is distinct from OLD.operator_id
     or NEW.evidence_path is distinct from OLD.evidence_path
     or NEW.ocr_text is distinct from OLD.ocr_text
     or NEW.capture_kind is distinct from OLD.capture_kind
     or NEW.created_at is distinct from OLD.created_at then
    raise exception 'Capture identity, evidence and source cannot be edited after upload';
  end if;
  if auth.uid() is not null
     and not app_private.resolve_permission('liveops.capture.review','liveops_session',OLD.session_id,null,null) then
    raise exception 'Only an authorised reviewer may review a capture';
  end if;
  if NEW.review_status not in ('pending','submitted','accepted','rejected') then
    raise exception 'Invalid capture review status';
  end if;
  if NEW.review_status is distinct from OLD.review_status
     or NEW.reviewed_by is distinct from OLD.reviewed_by
     or NEW.reviewed_at is distinct from OLD.reviewed_at
     or NEW.review_note is distinct from OLD.review_note then
    if NEW.reviewed_by is distinct from auth.uid() and auth.uid() is not null then
      raise exception 'Capture reviewer must match the authenticated user';
    end if;
  end if;
  return NEW;
end;
$function$;
revoke all on function app_private.guard_liveops_capture_scope() from public,anon,authenticated;
drop trigger if exists liveops_captures_scope_guard on public.liveops_captures;
create trigger liveops_captures_scope_guard
before insert or update on public.liveops_captures
for each row execute function app_private.guard_liveops_capture_scope();
