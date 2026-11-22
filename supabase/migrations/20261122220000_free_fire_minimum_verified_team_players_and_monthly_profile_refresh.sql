-- Align Free Fire MAX team UID verification with the event's configured
-- minimum roster requirement, persist every verified member's account, and
-- enforce a 30-day interval between successful manual profile refreshes.

ALTER TABLE public.game_accounts
  ADD COLUMN IF NOT EXISTS profile_refresh_last_success_at timestamptz;

CREATE OR REPLACE FUNCTION app_private.is_event_registration_eligible_player(
  p_event_id uuid,
  p_user_id uuid,
  p_team_id uuid DEFAULT NULL::uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event public.events%ROWTYPE;
  v_team_id uuid;
  v_roster_count integer;
  v_joined_roster_count integer;
  v_min_roster integer;
  v_max_roster integer;
  v_uid_count integer;
  v_require_uid boolean;
  v_is_free_fire_max boolean := false;
BEGIN
  IF p_event_id IS NULL OR p_user_id IS NULL THEN RETURN false; END IF;

  SELECT * INTO v_event FROM public.events WHERE id = p_event_id;
  IF NOT FOUND OR v_event.community_id IS NULL THEN RETURN false; END IF;

  v_require_uid := coalesce((v_event.rules_json->>'require_game_uid')::boolean, false);
  SELECT EXISTS (
    SELECT 1 FROM public.games g
    WHERE g.id = v_event.game_id AND g.code = 'free_fire_max'
  ) INTO v_is_free_fire_max;

  IF v_event.format = 'solo' THEN
    IF p_team_id IS NOT NULL THEN RETURN false; END IF;
    IF v_is_free_fire_max THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.game_accounts ga
        WHERE ga.user_id = p_user_id
          AND ga.game_id = v_event.game_id
          AND ga.ownership_status = 'verified'
      ) THEN
        RETURN false;
      END IF;
    ELSIF v_require_uid AND NOT EXISTS (
      SELECT 1 FROM public.game_accounts ga
      WHERE ga.user_id = p_user_id
        AND ga.game_id = v_event.game_id
        AND ga.ownership_status <> 'rejected'
    ) THEN
      RETURN false;
    END IF;
    RETURN true;
  END IF;

  -- Any team member may register, but the submitting player must have joined
  -- the tournament community and the team must meet its required joined count.
  IF NOT EXISTS (
    SELECT 1 FROM public.community_members cm
    WHERE cm.community_id = v_event.community_id
      AND cm.user_id = p_user_id
  ) THEN
    RETURN false;
  END IF;

  v_min_roster := coalesce(
    nullif(v_event.rules_json->>'min_roster_size', '')::integer,
    CASE v_event.format WHEN 'duo' THEN 2 WHEN 'squad' THEN 4 ELSE 1 END
  );
  v_max_roster := coalesce(
    nullif(v_event.rules_json->>'max_roster_size', '')::integer,
    CASE v_event.format WHEN 'duo' THEN 2 WHEN 'squad' THEN 4 ELSE 8 END
  );
  IF v_min_roster < 1 OR v_max_roster < v_min_roster THEN RETURN false; END IF;

  FOR v_team_id IN
    SELECT t.id
    FROM public.teams t
    JOIN public.team_members tm ON tm.team_id = t.id
    WHERE tm.user_id = p_user_id
      AND t.game_id = v_event.game_id
      AND (p_team_id IS NULL OR t.id = p_team_id)
    ORDER BY t.created_at, t.id
  LOOP
    SELECT count(*), count(cm.user_id)
      INTO v_roster_count, v_joined_roster_count
    FROM public.team_members tm
    LEFT JOIN public.community_members cm
      ON cm.user_id = tm.user_id
     AND cm.community_id = v_event.community_id
    WHERE tm.team_id = v_team_id;

    IF v_roster_count < v_min_roster OR v_roster_count > v_max_roster
       OR v_joined_roster_count < v_min_roster THEN
      CONTINUE;
    END IF;

    IF v_is_free_fire_max THEN
      SELECT count(DISTINCT tm.user_id) INTO v_uid_count
      FROM public.team_members tm
      JOIN public.game_accounts ga
        ON ga.user_id = tm.user_id
       AND ga.game_id = v_event.game_id
       AND ga.ownership_status = 'verified'
      WHERE tm.team_id = v_team_id;
      IF v_uid_count < v_min_roster THEN CONTINUE; END IF;
    ELSIF v_require_uid THEN
      SELECT count(*) INTO v_uid_count
      FROM public.team_members tm
      JOIN public.game_accounts ga
        ON ga.user_id = tm.user_id
       AND ga.game_id = v_event.game_id
       AND ga.ownership_status <> 'rejected'
      WHERE tm.team_id = v_team_id;
      IF v_uid_count < v_roster_count THEN CONTINUE; END IF;
    END IF;

    RETURN true;
  END LOOP;

  RETURN false;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.is_event_registration_eligible_player(uuid,uuid,uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION app_private.register_for_event(p_event_id uuid, p_team_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_event public.events%rowtype;
  v_registration public.event_registrations%rowtype;
  v_count integer;
  v_roster_count integer;
  v_joined_roster_count integer;
  v_min_roster integer;
  v_max_roster integer;
  v_require_uid boolean;
  v_is_free_fire_max boolean := false;
  v_status text;
  v_duplicate_uid boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select * into v_event from public.events where id = p_event_id for update;
  if not found then raise exception 'Event not found'; end if;

  select exists (
    select 1 from public.games g
    where g.id = v_event.game_id and g.code = 'free_fire_max'
  ) into v_is_free_fire_max;

  if v_event.status not in ('published', 'registration_open') then raise exception 'Registration is closed'; end if;
  if v_event.registration_opens_at is null or v_event.registration_opens_at > now() then
    raise exception 'Registration has not started yet';
  end if;
  if v_event.registration_closes_at is null then
    raise exception 'Registration close time is not configured';
  end if;
  if v_event.registration_closes_at <= now() then
    raise exception 'Registration deadline has passed';
  end if;

  select count(*) into v_count
  from public.event_registrations
  where event_id = p_event_id and status in ('pending', 'approved', 'checked_in');

  v_status := case when v_count >= v_event.capacity then 'waitlisted' else 'pending' end;

  if v_event.format = 'solo' then
    if p_team_id is not null then raise exception 'Solo events do not accept a team registration'; end if;
    if v_is_free_fire_max and not exists (
      select 1 from public.game_accounts ga
      where ga.user_id = auth.uid()
        and ga.game_id = v_event.game_id
        and ga.ownership_status = 'verified'
    ) then
      raise exception 'Complete Free Fire UID ownership verification before registering';
    end if;

    if not v_is_free_fire_max then
      v_require_uid := coalesce((v_event.rules_json->>'require_game_uid')::boolean, false);
      if v_require_uid and not exists (
        select 1 from public.game_accounts ga
        where ga.user_id = auth.uid() and ga.game_id = v_event.game_id
          and ga.ownership_status <> 'rejected'
      ) then
        raise exception 'Link the required game UID before registering';
      end if;
    end if;

    insert into public.event_registrations (event_id, team_id, captain_user_id, status)
    values (p_event_id, null, auth.uid(), v_status)
    returning * into v_registration;

    insert into public.registration_players (registration_id, user_id, game_account_id)
    select v_registration.id, auth.uid(), ga.id
    from public.game_accounts ga
    where ga.user_id = auth.uid() and ga.game_id = v_event.game_id
      and (not v_is_free_fire_max or ga.ownership_status = 'verified')
    order by ga.last_synced_at desc nulls last
    limit 1;

    if not found then
      if v_is_free_fire_max then
        raise exception 'A verified Free Fire UID is required for this registration';
      end if;
      insert into public.registration_players (registration_id, user_id)
      values (v_registration.id, auth.uid());
    end if;
  else
    if p_team_id is null then raise exception 'Select a team before registering for this event'; end if;

    if not exists (
      select 1 from public.team_members tm
      join public.teams t on t.id = tm.team_id
      where tm.team_id = p_team_id
        and tm.user_id = auth.uid()
        and t.game_id = v_event.game_id
    ) then
      raise exception 'You must be a member of a team that matches this event game';
    end if;

    if v_event.community_id is null or not exists (
      select 1 from public.community_members cm
      where cm.community_id = v_event.community_id
        and cm.user_id = auth.uid()
    ) then
      raise exception 'Join the tournament community before registering your team';
    end if;

    select count(*) into v_roster_count
    from public.team_members tm
    where tm.team_id = p_team_id;

    v_min_roster := coalesce(
      nullif(v_event.rules_json->>'min_roster_size', '')::integer,
      case v_event.format when 'duo' then 2 when 'squad' then 4 else 1 end
    );
    v_max_roster := coalesce(
      nullif(v_event.rules_json->>'max_roster_size', '')::integer,
      case v_event.format when 'duo' then 2 when 'squad' then 4 else 8 end
    );
    if v_roster_count < v_min_roster or v_roster_count > v_max_roster then
      raise exception 'Team roster size must be between % and %', v_min_roster, v_max_roster;
    end if;

    select count(*) into v_joined_roster_count
    from public.team_members tm
    join public.community_members cm
      on cm.user_id = tm.user_id
     and cm.community_id = v_event.community_id
    where tm.team_id = p_team_id;

    if v_joined_roster_count < v_min_roster then
      raise exception 'At least % required team member(s) must join the tournament community before registration',
        v_min_roster;
    end if;

    if v_is_free_fire_max then
      if (
        select count(distinct tm.user_id)
        from public.team_members tm
        join public.game_accounts ga
          on ga.user_id = tm.user_id
         and ga.game_id = v_event.game_id
         and ga.ownership_status = 'verified'
        where tm.team_id = p_team_id
      ) < v_min_roster then
        raise exception 'At least % team member(s) must complete Free Fire MAX UID ownership verification before registration', v_min_roster;
      end if;
    else
      v_require_uid := coalesce((v_event.rules_json->>'require_game_uid')::boolean, false);
      if v_require_uid and (
        select count(*) from public.team_members tm
        join public.game_accounts ga on ga.user_id = tm.user_id and ga.game_id = v_event.game_id
        where tm.team_id = p_team_id and ga.ownership_status <> 'rejected'
      ) < v_roster_count then
        raise exception 'Every roster member must link a game UID before registering';
      end if;
    end if;

    select exists (
      select 1
      from public.team_members current_member
      join public.game_accounts current_account
        on current_account.user_id = current_member.user_id
       and current_account.game_id = v_event.game_id
       and (not v_is_free_fire_max or current_account.ownership_status = 'verified')
      join public.event_registrations existing_registration
        on existing_registration.event_id = p_event_id
       and existing_registration.status in ('pending', 'approved', 'checked_in')
      join public.registration_players existing_player
        on existing_player.registration_id = existing_registration.id
      join public.game_accounts existing_account
        on existing_account.id = existing_player.game_account_id
      where current_member.team_id = p_team_id
        and existing_account.uid = current_account.uid
        and existing_registration.team_id is distinct from p_team_id
    ) into v_duplicate_uid;

    if v_duplicate_uid then
      raise exception 'One or more game UIDs are already registered with another team';
    end if;

    insert into public.event_registrations (event_id, team_id, captain_user_id, status)
    values (p_event_id, p_team_id, auth.uid(), v_status)
    returning * into v_registration;

    insert into public.registration_players (registration_id, user_id, game_account_id)
    select v_registration.id, tm.user_id, ga.id
    from public.team_members tm
    left join lateral (
      select id from public.game_accounts
      where user_id = tm.user_id and game_id = v_event.game_id
        and (not v_is_free_fire_max or ownership_status = 'verified')
      order by last_synced_at desc nulls last
      limit 1
    ) ga on true
    where tm.team_id = p_team_id;

  end if;

  return jsonb_build_object(
    'registration_id', v_registration.id,
    'status', v_registration.status,
    'roster_size', v_roster_count,
    'roster_locked', false
  );
exception
  when unique_violation then raise exception 'This player or team is already registered';
end;
$function$
