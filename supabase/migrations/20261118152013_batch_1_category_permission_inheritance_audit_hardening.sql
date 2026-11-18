-- Batch 1 completion: category/channel permission inheritance and scoped audit coverage.
-- Inherit is absence of an override row. A channel override takes precedence over its category.
-- Deny wins across roles at the same level. Secrets/evidence paths/OCR are excluded from audit snapshots.

create table public.category_permission_overrides (
  community_id uuid not null,
  category_id uuid not null,
  role_id uuid not null,
  permission_key text not null,
  effect text not null check (effect in ('allow','deny')),
  updated_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  constraint category_permission_overrides_pkey primary key (category_id,role_id,permission_key),
  constraint category_permission_overrides_category_community_fkey
    foreign key (category_id,community_id) references public.channel_categories(id,community_id) on delete cascade,
  constraint category_permission_overrides_role_community_fkey
    foreign key (role_id,community_id) references public.community_roles(id,community_id) on delete cascade,
  constraint category_permission_overrides_community_fkey
    foreign key (community_id) references public.communities(id) on delete cascade,
  constraint category_permission_overrides_permission_key_check
    check (char_length(permission_key) between 3 and 80)
);
create index category_permission_overrides_role_permission_idx
  on public.category_permission_overrides(role_id,permission_key,category_id);
alter table public.category_permission_overrides enable row level security;
revoke all on table public.category_permission_overrides from public,anon;
grant select,insert,update,delete on table public.category_permission_overrides to authenticated;
create policy category_permission_overrides_read_staff
on public.category_permission_overrides for select to authenticated
using (app_private.can_manage_community_structure(community_id));
create policy category_permission_overrides_write_admin
on public.category_permission_overrides for all to authenticated
using (app_private.can_manage_community_roles(community_id))
with check (app_private.can_manage_community_roles(community_id));

create or replace function app_private.guard_category_permission_override()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_community_id uuid;
  v_category_id uuid;
  v_role_id uuid;
  v_permission text;
  v_effect text;
  v_position integer;
  v_rank integer;
begin
  v_community_id := case when TG_OP='DELETE' then OLD.community_id else NEW.community_id end;
  v_category_id := case when TG_OP='DELETE' then OLD.category_id else NEW.category_id end;
  v_role_id := case when TG_OP='DELETE' then OLD.role_id else NEW.role_id end;
  v_permission := case when TG_OP='DELETE' then OLD.permission_key else NEW.permission_key end;
  v_effect := case when TG_OP='DELETE' then OLD.effect else NEW.effect end;

  if auth.uid() is null then
    if TG_OP='DELETE' then return OLD; end if;
    return NEW;
  end if;
  if TG_OP='UPDATE' and (
    NEW.community_id is distinct from OLD.community_id or NEW.category_id is distinct from OLD.category_id
    or NEW.role_id is distinct from OLD.role_id or NEW.permission_key is distinct from OLD.permission_key
  ) then raise exception 'Category permission override identity and scope are immutable'; end if;
  if not app_private.resolve_permission('community.manage_permissions','community',v_community_id,null,null) then
    raise exception 'You cannot manage category permission overrides';
  end if;
  if not exists (
    select 1 from public.channel_categories cc
    where cc.id=v_category_id and cc.community_id=v_community_id
      and cc.event_id is null and cc.stage_id is null and cc.group_id is null
  ) then raise exception 'Category overrides are only supported on community categories'; end if;
  if not exists (
    select 1 from app_private.permission_definitions d
    where d.permission_key=v_permission and d.scope_type='community'
  ) then raise exception 'Unknown or out-of-scope category permission: %',v_permission; end if;
  select cr.position into v_position from public.community_roles cr
  where cr.id=v_role_id and cr.community_id=v_community_id;
  v_rank := app_private.community_authority_rank(v_community_id);
  if v_position is null or v_position >= v_rank then
    raise exception 'You cannot override permissions for a role at or above your hierarchy level';
  end if;
  if TG_OP <> 'DELETE' then
    if NEW.updated_by is distinct from auth.uid() then
      raise exception 'Permission override actor must match the authenticated user';
    end if;
    if v_effect='allow' and not app_private.resolve_permission(v_permission,'community',v_community_id,null,null) then
      raise exception 'You cannot allow a permission you do not hold';
    end if;
    return NEW;
  end if;
  return OLD;
end;
$function$;
revoke all on function app_private.guard_category_permission_override() from public,anon,authenticated;
create trigger category_permission_overrides_authority_guard
before insert or update or delete on public.category_permission_overrides
for each row execute function app_private.guard_category_permission_override();

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

CREATE OR REPLACE FUNCTION app_private.audit_sensitive_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  elsif TG_TABLE_NAME='category_permission_overrides' then
    v_entity_type := 'category_permission_override';
    v_entity_id := nullif(v_row->>'category_id','')::uuid;
    v_community_id := nullif(v_row->>'community_id','')::uuid;
  elsif TG_TABLE_NAME='matches' then
    v_entity_type := 'match';
    v_entity_id := nullif(v_row->>'id','')::uuid;
    v_event_id := nullif(v_row->>'event_id','')::uuid;
  elsif TG_TABLE_NAME='match_participants' then
    v_entity_type := 'match_participant';
    v_entity_id := nullif(v_row->>'match_id','')::uuid;
    select m.event_id into v_event_id from public.matches m where m.id=nullif(v_row->>'match_id','')::uuid;
  elsif TG_TABLE_NAME='match_checkins' then
    v_entity_type := 'match_checkin';
    v_entity_id := nullif(v_row->>'match_id','')::uuid;
    select m.event_id into v_event_id from public.matches m where m.id=nullif(v_row->>'match_id','')::uuid;
  elsif TG_TABLE_NAME='room_credentials' then
    v_entity_type := 'room_credential';
    v_entity_id := nullif(v_row->>'id','')::uuid;
    select m.event_id into v_event_id from public.matches m where m.id=nullif(v_row->>'match_id','')::uuid;
  elsif TG_TABLE_NAME='match_results' then
    v_entity_type := 'match_result';
    v_entity_id := nullif(v_row->>'id','')::uuid;
    select m.event_id into v_event_id from public.matches m where m.id=nullif(v_row->>'match_id','')::uuid;
  elsif TG_TABLE_NAME='result_evidence' then
    v_entity_type := 'result_evidence';
    v_entity_id := nullif(v_row->>'id','')::uuid;
    select m.event_id into v_event_id from public.match_results r join public.matches m on m.id=r.match_id
    where r.id=nullif(v_row->>'result_id','')::uuid;
  elsif TG_TABLE_NAME='result_disputes' then
    v_entity_type := 'result_dispute';
    v_entity_id := nullif(v_row->>'id','')::uuid;
    select m.event_id into v_event_id from public.match_results r join public.matches m on m.id=r.match_id
    where r.id=nullif(v_row->>'result_id','')::uuid;
  elsif TG_TABLE_NAME='liveops_captures' then
    v_entity_type := 'liveops_capture';
    v_entity_id := nullif(v_row->>'id','')::uuid;
    v_event_id := nullif(v_row->>'event_id','')::uuid;
  elsif TG_TABLE_NAME='liveops_sessions' then
    v_entity_type := 'liveops_session';
    v_entity_id := nullif(v_row->>'id','')::uuid;
    v_event_id := nullif(v_row->>'event_id','')::uuid;
  end if;

  v_action := lower(TG_TABLE_NAME) || '_' || lower(TG_OP);
  if TG_TABLE_NAME='room_credentials' then
    v_metadata := jsonb_build_object(
      'before',case when v_old is null then null else jsonb_build_object(
        'match_id',v_old->'match_id','release_at',v_old->'release_at',
        'room_code_present',nullif(v_old->>'room_code','') is not null,
        'room_password_present',nullif(v_old->>'room_password','') is not null) end,
      'after',case when v_new is null then null else jsonb_build_object(
        'match_id',v_new->'match_id','release_at',v_new->'release_at',
        'room_code_present',nullif(v_new->>'room_code','') is not null,
        'room_password_present',nullif(v_new->>'room_password','') is not null) end
    );
  elsif TG_TABLE_NAME='liveops_captures' then
    v_metadata := jsonb_build_object(
      'before',case when v_old is null then null else jsonb_build_object(
        'match_id',v_old->'match_id','event_id',v_old->'event_id','capture_kind',v_old->'capture_kind',
        'review_status',v_old->'review_status','reviewed_by',v_old->'reviewed_by','reviewed_at',v_old->'reviewed_at') end,
      'after',case when v_new is null then null else jsonb_build_object(
        'match_id',v_new->'match_id','event_id',v_new->'event_id','capture_kind',v_new->'capture_kind',
        'review_status',v_new->'review_status','reviewed_by',v_new->'reviewed_by','reviewed_at',v_new->'reviewed_at') end
    );
  elsif TG_TABLE_NAME='liveops_sessions' then
    v_metadata := jsonb_build_object(
      'before',case when v_old is null then null else jsonb_build_object(
        'match_id',v_old->'match_id','event_id',v_old->'event_id','operator_id',v_old->'operator_id','state',v_old->'state') end,
      'after',case when v_new is null then null else jsonb_build_object(
        'match_id',v_new->'match_id','event_id',v_new->'event_id','operator_id',v_new->'operator_id','state',v_new->'state') end
    );
  elsif TG_TABLE_NAME='match_checkins' then
    v_metadata := jsonb_build_object(
      'before',case when v_old is null then null else jsonb_build_object(
        'match_id',v_old->'match_id','user_id',v_old->'user_id','status',v_old->'status','checked_in_at',v_old->'checked_in_at') end,
      'after',case when v_new is null then null else jsonb_build_object(
        'match_id',v_new->'match_id','user_id',v_new->'user_id','status',v_new->'status','checked_in_at',v_new->'checked_in_at') end
    );
  elsif TG_TABLE_NAME='match_participants' then
    v_metadata := jsonb_build_object(
      'before',case when v_old is null then null else jsonb_build_object(
        'match_id',v_old->'match_id','team_id',v_old->'team_id','slot_number',v_old->'slot_number','check_in_status',v_old->'check_in_status') end,
      'after',case when v_new is null then null else jsonb_build_object(
        'match_id',v_new->'match_id','team_id',v_new->'team_id','slot_number',v_new->'slot_number','check_in_status',v_new->'check_in_status') end
    );
  elsif TG_TABLE_NAME='match_results' then
    v_metadata := jsonb_build_object(
      'before',case when v_old is null then null else jsonb_build_object(
        'match_id',v_old->'match_id','team_id',v_old->'team_id','status',v_old->'status',
        'placement',v_old->'placement','kills',v_old->'kills','points',v_old->'points',
        'approved_by',v_old->'approved_by','approved_at',v_old->'approved_at') end,
      'after',case when v_new is null then null else jsonb_build_object(
        'match_id',v_new->'match_id','team_id',v_new->'team_id','status',v_new->'status',
        'placement',v_new->'placement','kills',v_new->'kills','points',v_new->'points',
        'approved_by',v_new->'approved_by','approved_at',v_new->'approved_at') end
    );
  elsif TG_TABLE_NAME='result_evidence' then
    v_metadata := jsonb_build_object(
      'before',case when v_old is null then null else jsonb_build_object(
        'result_id',v_old->'result_id','uploaded_by',v_old->'uploaded_by','content_type',v_old->'content_type',
        'file_size',v_old->'file_size','storage_object_present',nullif(v_old->>'storage_path','') is not null) end,
      'after',case when v_new is null then null else jsonb_build_object(
        'result_id',v_new->'result_id','uploaded_by',v_new->'uploaded_by','content_type',v_new->'content_type',
        'file_size',v_new->'file_size','storage_object_present',nullif(v_new->>'storage_path','') is not null) end
    );
  elsif TG_TABLE_NAME='result_disputes' then
    v_metadata := jsonb_build_object(
      'before',case when v_old is null then null else jsonb_build_object(
        'result_id',v_old->'result_id','opened_by',v_old->'opened_by','reason',v_old->'reason',
        'status',v_old->'status','decision',v_old->'decision','decided_by',v_old->'decided_by','resolved_at',v_old->'resolved_at') end,
      'after',case when v_new is null then null else jsonb_build_object(
        'result_id',v_new->'result_id','opened_by',v_new->'opened_by','reason',v_new->'reason',
        'status',v_new->'status','decision',v_new->'decision','decided_by',v_new->'decided_by','resolved_at',v_new->'resolved_at') end
    );
  elsif TG_TABLE_NAME='matches' then
    v_metadata := jsonb_build_object(
      'before',case when v_old is null then null else jsonb_build_object(
        'event_id',v_old->'event_id','stage_id',v_old->'stage_id','group_id',v_old->'group_id','status',v_old->'status') end,
      'after',case when v_new is null then null else jsonb_build_object(
        'event_id',v_new->'event_id','stage_id',v_new->'stage_id','group_id',v_new->'group_id','status',v_new->'status') end
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

drop trigger if exists audit_category_permission_overrides_change on public.category_permission_overrides;
create trigger audit_category_permission_overrides_change after insert or update or delete
on public.category_permission_overrides for each row execute function app_private.audit_sensitive_change();

drop trigger if exists audit_matches_change on public.matches;
create trigger audit_matches_change after insert or update or delete
on public.matches for each row execute function app_private.audit_sensitive_change();
drop trigger if exists audit_match_participants_change on public.match_participants;
create trigger audit_match_participants_change after insert or update or delete
on public.match_participants for each row execute function app_private.audit_sensitive_change();
drop trigger if exists audit_match_checkins_change on public.match_checkins;
create trigger audit_match_checkins_change after insert or update or delete
on public.match_checkins for each row execute function app_private.audit_sensitive_change();
drop trigger if exists audit_room_credentials_change on public.room_credentials;
create trigger audit_room_credentials_change after insert or update or delete
on public.room_credentials for each row execute function app_private.audit_sensitive_change();
drop trigger if exists audit_match_results_change on public.match_results;
create trigger audit_match_results_change after insert or update or delete
on public.match_results for each row execute function app_private.audit_sensitive_change();
drop trigger if exists audit_result_evidence_change on public.result_evidence;
create trigger audit_result_evidence_change after insert or update or delete
on public.result_evidence for each row execute function app_private.audit_sensitive_change();
drop trigger if exists audit_result_disputes_change on public.result_disputes;
create trigger audit_result_disputes_change after insert or update or delete
on public.result_disputes for each row execute function app_private.audit_sensitive_change();
drop trigger if exists audit_liveops_captures_change on public.liveops_captures;
create trigger audit_liveops_captures_change after insert or update or delete
on public.liveops_captures for each row execute function app_private.audit_sensitive_change();

comment on table public.category_permission_overrides is
  'Category-level permission defaults for community channels. A channel override takes precedence; absence means Inherit. Deny wins among roles at the same level.';
comment on function app_private.resolve_permission(text,text,uuid,uuid,uuid) is
  'Canonical server-side permission resolver. Community channel decisions apply channel override > category inheritance > role/built-in grant; Deny wins within a level and Owner override is permission-definition controlled.';
