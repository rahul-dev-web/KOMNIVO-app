-- Player AI may discuss published public events before registration.
-- Private community events remain visible only to members or registered players.

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
begin
  if v_uid is null then return false; end if;

  if p_mode = 'organizer' then
    if p_community_id is null and p_event_id is null then return false; end if;
    if p_community_id is not null and not exists (
      select 1 from public.community_members cm
      where cm.community_id = p_community_id and cm.user_id = v_uid
        and cm.role in ('owner','admin','organiser')
    ) then return false; end if;
    if p_event_id is not null then
      select e.community_id, e.organizer_id into v_event_community, v_event_organizer
      from public.events e where e.id = p_event_id;
      if not found then return false; end if;
      if p_community_id is not null and v_event_community is distinct from p_community_id then return false; end if;
      if v_event_organizer is distinct from v_uid and not (
        v_event_community is not null and exists (
          select 1 from public.community_members cm
          where cm.community_id = v_event_community and cm.user_id = v_uid
            and cm.role in ('owner','admin','organiser')
        )
      ) then return false; end if;
    end if;
    return true;
  elsif p_mode = 'player' then
    if p_community_id is not null then
      select c.visibility into v_community_visibility
      from public.communities c where c.id = p_community_id;
      if not found then return false; end if;
      if v_community_visibility <> 'public' and not exists (
        select 1 from public.community_members cm
        where cm.community_id = p_community_id and cm.user_id = v_uid
      ) then return false; end if;
    end if;

    if p_event_id is not null then
      select e.community_id, e.status into v_event_community, v_event_status
      from public.events e where e.id = p_event_id;
      if not found then return false; end if;
      if p_community_id is not null and v_event_community is distinct from p_community_id then return false; end if;

      select exists (
        select 1 from public.event_registrations er
        where er.event_id = p_event_id and (
          er.captain_user_id = v_uid
          or exists (
            select 1 from public.registration_players rp
            where rp.registration_id = er.id and rp.user_id = v_uid
          )
        )
      ) into v_is_participant;

      if not v_is_participant then
        if v_event_status not in ('published','registration_open','live','completed') then return false; end if;
        if v_event_community is not null then
          select c.visibility into v_community_visibility
          from public.communities c where c.id = v_event_community;
          if v_community_visibility is distinct from 'public' and not exists (
            select 1 from public.community_members cm
            where cm.community_id = v_event_community and cm.user_id = v_uid
          ) then return false; end if;
        end if;
      end if;
    end if;
    return true;
  end if;
  return false;
end;
$function$;

revoke all on function app_private.can_access_ai_scope(text,uuid,uuid) from public, anon;
grant execute on function app_private.can_access_ai_scope(text,uuid,uuid) to authenticated;
