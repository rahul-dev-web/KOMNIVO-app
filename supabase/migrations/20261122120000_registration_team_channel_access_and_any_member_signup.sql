-- Tournament registration and test-registration channel access.
-- Everyone with event.view can read these channels. The eligible team member may
-- write only in the applicable registration window. Help-desk remains open to
-- the event audience for read/write.

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
BEGIN
  IF p_event_id IS NULL OR p_user_id IS NULL THEN RETURN false; END IF;

  SELECT * INTO v_event FROM public.events WHERE id = p_event_id;
  IF NOT FOUND OR v_event.community_id IS NULL THEN RETURN false; END IF;

  v_require_uid := coalesce((v_event.rules_json->>'require_game_uid')::boolean, false);

  IF v_event.format = 'solo' THEN
    IF p_team_id IS NOT NULL THEN RETURN false; END IF;
    IF v_require_uid AND NOT EXISTS (
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

    IF v_require_uid THEN
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

CREATE OR REPLACE FUNCTION app_private.can_write_event_registration_channel(p_channel_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_channel public.channels%ROWTYPE;
  v_event public.events%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR p_channel_id IS NULL THEN RETURN false; END IF;

  SELECT * INTO v_channel
  FROM public.channels c
  WHERE c.id = p_channel_id
    AND c.event_id IS NOT NULL
    AND c.stage_id IS NULL
    AND c.group_id IS NULL
    AND c.match_id IS NULL
    AND c.archived_at IS NULL;
  IF NOT FOUND THEN RETURN false; END IF;

  IF v_channel.name NOT IN ('registration','test-registration') THEN RETURN false; END IF;

  SELECT * INTO v_event FROM public.events e WHERE e.id = v_channel.event_id;
  IF NOT FOUND THEN RETURN false; END IF;

  IF v_event.registration_closes_at IS NULL
     OR v_event.registration_closes_at <= now() THEN
    RETURN false;
  END IF;

  IF v_channel.name = 'registration' THEN
    IF v_event.status NOT IN ('published','registration_open')
       OR v_event.registration_opens_at IS NULL
       OR v_event.registration_opens_at > now() THEN
      RETURN false;
    END IF;
  ELSE
    -- Test-registration write access begins on publish and ends at the real
    -- registration close, regardless of whether registration has opened yet.
    IF v_event.status NOT IN ('published','registration_open') THEN
      RETURN false;
    END IF;
  END IF;

  RETURN app_private.is_event_registration_eligible_player(
    v_event.id, auth.uid(), NULL
  );
END;
$function$;

REVOKE ALL ON FUNCTION app_private.can_write_event_registration_channel(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION app_private.can_write_event_registration_channel(uuid)
  TO authenticated;


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
  v_status text;
  v_duplicate_uid boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select * into v_event from public.events where id = p_event_id for update;
  if not found then raise exception 'Event not found'; end if;
  if v_event.status not in ('published', 'registration_open') then raise exception 'Registration is closed'; end if;
  if v_event.registration_opens_at is null or v_event.registration_opens_at > now() then
    raise exception 'Registration has not started yet';
  end if;
  if v_event.registration_closes_at is not null and v_event.registration_closes_at <= now() then
    raise exception 'Registration deadline has passed';
  end if;

  select count(*) into v_count
  from public.event_registrations
  where event_id = p_event_id and status in ('pending', 'approved', 'checked_in');

  v_status := case when v_count >= v_event.capacity then 'waitlisted' else 'pending' end;

  if v_event.format = 'solo' then
    if p_team_id is not null then raise exception 'Solo events do not accept a team registration'; end if;
    v_require_uid := coalesce((v_event.rules_json->>'require_game_uid')::boolean, false);
    if v_require_uid and not exists (
      select 1 from public.game_accounts ga
      where ga.user_id = auth.uid() and ga.game_id = v_event.game_id
        and ga.ownership_status <> 'rejected'
    ) then
      raise exception 'Link the required game UID before registering';
    end if;

    insert into public.event_registrations (event_id, team_id, captain_user_id, status)
    values (p_event_id, null, auth.uid(), v_status)
    returning * into v_registration;

    insert into public.registration_players (registration_id, user_id, game_account_id)
    select v_registration.id, auth.uid(), ga.id
    from public.game_accounts ga
    where ga.user_id = auth.uid() and ga.game_id = v_event.game_id
    order by ga.last_synced_at desc nulls last
    limit 1;

    if not found then
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

    v_require_uid := coalesce((v_event.rules_json->>'require_game_uid')::boolean, false);
    if v_require_uid and (
      select count(*) from public.team_members tm
      join public.game_accounts ga on ga.user_id = tm.user_id and ga.game_id = v_event.game_id
      where tm.team_id = p_team_id and ga.ownership_status <> 'rejected'
    ) < v_roster_count then
      raise exception 'Every roster member must link a game UID before registration';
    end if;

    select exists (
      select 1
      from public.team_members current_member
      join public.game_accounts current_account
        on current_account.user_id = current_member.user_id
       and current_account.game_id = v_event.game_id
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
;
CREATE OR REPLACE FUNCTION app_private.can_send_channel_message(p_channel_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from public.channels c
    where c.id=p_channel_id and c.archived_at is null and (
      (c.event_id is not null and app_private.can_access_event_channel_scope(
        c.event_id,c.stage_id,c.group_id,c.match_id,c.id
      ))
      or
      (c.event_id is null and c.community_id is not null and app_private.resolve_permission(
        'channel.send_messages','community',c.community_id,null,c.id
      ))
    )
  ) and (
    not coalesce((select cs.read_only from public.channel_settings cs where cs.channel_id=p_channel_id),false)
    or app_private.can_write_event_registration_channel(p_channel_id)
  );
$function$
;
CREATE OR REPLACE FUNCTION app_private.guard_batch3_channel_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_settings public.channel_settings%ROWTYPE;
  v_last_sent timestamptz;
  v_channel public.channels%ROWTYPE;
  v_can_manage boolean;
  v_can_publish_event_channel boolean;
  v_announcement_publishers_only boolean;
  v_can_write_event_registration boolean;
BEGIN
  IF app_private.is_batch3_maintenance_context() THEN RETURN NEW; END IF;

  SELECT * INTO v_channel
  FROM public.channels c
  WHERE c.id=NEW.channel_id AND c.archived_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Channel is unavailable or archived'; END IF;

  SELECT * INTO v_settings FROM public.channel_settings WHERE channel_id=NEW.channel_id;

  v_can_manage := CASE
    WHEN v_channel.event_id IS NOT NULL THEN app_private.can_manage_event_channel(v_channel.id)
    ELSE app_private.resolve_permission('channel.manage_messages','community',v_channel.community_id,NULL,v_channel.id)
  END;

  v_can_write_event_registration := app_private.can_write_event_registration_channel(v_channel.id);

  v_announcement_publishers_only := CASE
    WHEN v_settings.channel_id IS NULL THEN v_channel.kind='announcement'
    ELSE v_settings.announcement_publishers_only
  END;

  v_can_publish_event_channel := v_can_manage;
  IF v_channel.event_id IS NOT NULL
     AND v_channel.stage_id IS NULL
     AND v_channel.group_id IS NULL
     AND v_channel.match_id IS NULL
     AND (coalesce(v_settings.read_only,false) OR v_announcement_publishers_only) THEN
    v_can_publish_event_channel := app_private.resolve_permission(
      'event.manage','event',v_channel.event_id,NULL,NULL
    );
  END IF;

  IF v_settings.channel_id IS NOT NULL
     AND v_settings.read_only
     AND NOT v_can_publish_event_channel
     AND NOT v_can_write_event_registration THEN
    RAISE EXCEPTION 'This channel is read-only';
  END IF;

  IF NOT app_private.can_send_channel_message(NEW.channel_id) AND NOT v_can_manage
  THEN RAISE EXCEPTION 'You cannot send messages in this channel'; END IF;

  IF NEW.parent_message_id IS NOT NULL AND v_settings.channel_id IS NOT NULL
     AND NOT v_settings.allow_threads AND NOT v_can_manage THEN
    RAISE EXCEPTION 'Message threads are disabled in this channel';
  END IF;

  IF v_announcement_publishers_only
     AND NOT v_can_publish_event_channel
     AND NOT v_can_write_event_registration
  THEN RAISE EXCEPTION 'Only authorised announcement publishers can post'; END IF;

  IF v_settings.channel_id IS NOT NULL THEN
    IF NOT v_settings.allow_links AND NEW.body ~* '(https?://|www[.])'
    THEN RAISE EXCEPTION 'Links are disabled in this channel'; END IF;
    IF NOT v_settings.allow_everyone_mention
       AND NEW.body ~* '(^|[[:space:]])@(everyone|here)([[:space:]]|$)' THEN
      RAISE EXCEPTION 'Broad mentions are disabled in this channel';
    END IF;
    IF NOT v_settings.allow_role_mentions AND NEW.body ~ '<@&[0-9a-fA-F-]{36}>' THEN
      RAISE EXCEPTION 'Role mentions are disabled in this channel';
    END IF;
    IF NOT v_settings.allow_user_mentions AND NEW.body ~ '<@[0-9a-fA-F-]{36}>' THEN
      RAISE EXCEPTION 'User mentions are disabled in this channel';
    END IF;

    IF v_settings.slow_mode_seconds > 0 AND NOT v_can_manage THEN
      PERFORM pg_advisory_xact_lock(hashtextextended(NEW.channel_id::text||':'||NEW.sender_id::text,0));
      SELECT max(m.created_at) INTO v_last_sent
      FROM public.messages m
      WHERE m.channel_id=NEW.channel_id AND m.sender_id=NEW.sender_id AND m.deleted_at IS NULL;
      IF v_last_sent IS NOT NULL
         AND v_last_sent > now() - make_interval(secs => v_settings.slow_mode_seconds) THEN
        RAISE EXCEPTION 'Slow mode is active. Please wait before sending again';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$
;
