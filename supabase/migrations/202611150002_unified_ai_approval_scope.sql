-- Unify AI proposal approval and conversation RLS with the contextual assistant.
-- Legacy ai_conversations.mode is a history label, never the authorization authority.

begin;

create or replace function app_private.can_access_ai_scope(
  p_mode text,
  p_community_id uuid default null,
  p_event_id uuid default null
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_community_visibility text;
  v_event_community uuid;
  v_event_status text;
  v_event_organizer uuid;
  v_is_participant boolean := false;
  v_can_manage_event boolean := false;
begin
  if v_uid is null then
    return false;
  end if;

  if p_mode = 'organizer' then
    if p_community_id is null and p_event_id is null then
      return false;
    end if;

    if p_community_id is not null and not exists (
      select 1
      from public.community_members cm
      where cm.community_id = p_community_id
        and cm.user_id = v_uid
        and cm.role in ('owner', 'admin', 'organiser')
    ) and not exists (
      select 1
      from public.communities c
      where c.id = p_community_id
        and c.owner_user_id = v_uid
    ) then
      return false;
    end if;

    if p_event_id is not null then
      select e.community_id, e.organizer_id
        into v_event_community, v_event_organizer
      from public.events e
      where e.id = p_event_id;

      if not found then
        return false;
      end if;

      if p_community_id is not null
        and v_event_community is distinct from p_community_id then
        return false;
      end if;

      if v_event_organizer is distinct from v_uid and not (
        v_event_community is not null and (
          exists (
            select 1
            from public.community_members cm
            where cm.community_id = v_event_community
              and cm.user_id = v_uid
              and cm.role in ('owner', 'admin', 'organiser')
          )
          or exists (
            select 1
            from public.communities c
            where c.id = v_event_community
              and c.owner_user_id = v_uid
          )
        )
      ) then
        return false;
      end if;
    end if;

    return true;

  elsif p_mode = 'player' then
    if p_community_id is not null then
      select c.visibility
        into v_community_visibility
      from public.communities c
      where c.id = p_community_id;

      if not found then
        return false;
      end if;

      -- A non-member event organiser may access that exact assigned event,
      -- but does not receive general access to the private community.
      if v_community_visibility <> 'public'
        and not exists (
          select 1
          from public.community_members cm
          where cm.community_id = p_community_id
            and cm.user_id = v_uid
        )
        and not (
          p_event_id is not null and exists (
            select 1
            from public.events e
            where e.id = p_event_id
              and e.community_id = p_community_id
              and e.organizer_id = v_uid
          )
        ) then
        return false;
      end if;
    end if;

    if p_event_id is not null then
      select e.community_id, e.status, e.organizer_id
        into v_event_community, v_event_status, v_event_organizer
      from public.events e
      where e.id = p_event_id;

      if not found then
        return false;
      end if;

      if p_community_id is not null
        and v_event_community is distinct from p_community_id then
        return false;
      end if;

      select exists (
        select 1
        from public.event_registrations er
        where er.event_id = p_event_id
          and (
            er.captain_user_id = v_uid
            or exists (
              select 1
              from public.registration_players rp
              where rp.registration_id = er.id
                and rp.user_id = v_uid
            )
          )
      ) into v_is_participant;

      v_can_manage_event := v_event_organizer = v_uid
        or (
          v_event_community is not null and (
            exists (
              select 1
              from public.community_members cm
              where cm.community_id = v_event_community
                and cm.user_id = v_uid
                and cm.role in ('owner', 'admin', 'organiser')
            )
            or exists (
              select 1
              from public.communities c
              where c.id = v_event_community
                and c.owner_user_id = v_uid
            )
          )
        );

      if not v_is_participant and not v_can_manage_event then
        if v_event_status not in ('published', 'registration_open', 'live', 'completed') then
          return false;
        end if;

        if v_event_community is not null then
          select c.visibility
            into v_community_visibility
          from public.communities c
          where c.id = v_event_community;

          if v_community_visibility is distinct from 'public'
            and not exists (
              select 1
              from public.community_members cm
              where cm.community_id = v_event_community
                and cm.user_id = v_uid
            ) then
            return false;
          end if;
        end if;
      end if;
    end if;

    return true;
  end if;

  return false;
end;
$function$;

-- The proposal row and its linked conversation are already selected by the
-- service-role endpoint for this authenticated owner. Remove only the legacy
-- mode-label gate; preserve the resolver's explicit permission rechecks.
do $migration$
declare
  v_definition text;
  v_old text := 'IF NOT FOUND OR v_conversation.mode <> ''organizer'' THEN';
  v_new text := 'IF NOT FOUND THEN';
begin
  v_definition := pg_get_functiondef(
    'public.resolve_organizer_ai_proposal(uuid,uuid,text)'::regprocedure
  );

  if position(v_old in v_definition) = 0 then
    raise exception 'Expected legacy Organizer mode gate was not found in proposal resolver';
  end if;

  v_definition := replace(v_definition, v_old, v_new);
  v_definition := replace(
    v_definition,
    'RAISE EXCEPTION ''organizer conversation required'' USING errcode = ''42501'';',
    'RAISE EXCEPTION ''conversation not found'' USING errcode = ''42501'';'
  );

  execute v_definition;
end;
$migration$;

comment on function app_private.can_access_ai_scope(text,uuid,uuid) is
  'Contextual AI scope check. Player access is always available for owned/visible/player-participant data; community and event organisers may access their exact selected scope regardless of the legacy conversation mode label.';

comment on function public.resolve_organizer_ai_proposal(uuid,uuid,text) is
  'Service-role-only transactional proposal resolver. Rechecks current community/event organizer permissions; conversation mode is not an authorization source; creates a DRAFT event only and never publishes.';

commit;
