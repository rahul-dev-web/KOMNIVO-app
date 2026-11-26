-- Temporary, isolated UID ownership bypass for tournament Test registration.
-- Real registrations continue to require verified Free Fire ownership.
-- Turn the test bypass off after testing by setting
-- app_private.registration_test_settings.allow_unverified_uid_for_test_registration = false.

CREATE TABLE IF NOT EXISTS app_private.registration_test_settings (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton IS TRUE),
  allow_unverified_uid_for_test_registration boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE app_private.registration_test_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE app_private.registration_test_settings
  FROM PUBLIC, anon, authenticated;

-- Enable the bypass only for the isolated test-registration RPC.
-- ON CONFLICT DO NOTHING preserves an operator's later explicit off switch.
INSERT INTO app_private.registration_test_settings(singleton, allow_unverified_uid_for_test_registration)
VALUES (true, true)
ON CONFLICT (singleton) DO NOTHING;

COMMENT ON TABLE app_private.registration_test_settings IS
  'Private runtime switches for isolated tournament test registration. Never controls real registration eligibility.';

CREATE OR REPLACE FUNCTION app_private.is_event_test_registration_eligible_player(
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
    -- Keep UID linking mandatory where the game/tournament requires it;
    -- only the Bio/signature ownership proof is bypassed in test mode.
    IF v_is_free_fire_max OR v_require_uid THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.game_accounts ga
        WHERE ga.user_id = p_user_id
          AND ga.game_id = v_event.game_id
          AND ga.ownership_status <> 'rejected'
      ) THEN
        RETURN false;
      END IF;
    END IF;
    RETURN true;
  END IF;

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
      -- Count linked, non-rejected UIDs, not ownership-verified UIDs.
      SELECT count(DISTINCT tm.user_id) INTO v_uid_count
      FROM public.team_members tm
      JOIN public.game_accounts ga
        ON ga.user_id = tm.user_id
       AND ga.game_id = v_event.game_id
       AND ga.ownership_status <> 'rejected'
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

REVOKE ALL ON FUNCTION app_private.is_event_test_registration_eligible_player(uuid,uuid,uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION app_private.submit_test_registration(
  p_event_id uuid,
  p_team_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event public.events%ROWTYPE;
  v_registration_id uuid;
  v_roster_size integer := 1;
  v_allow_unverified_uid boolean := false;
  v_eligible boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT * INTO v_event
  FROM public.events
  WHERE id = p_event_id
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Event not found'; END IF;
  IF v_event.status NOT IN ('published','registration_open') THEN
    RAISE EXCEPTION 'Test registration is unavailable before publication or after registration closes';
  END IF;
  IF v_event.registration_closes_at IS NULL OR v_event.registration_closes_at <= now() THEN
    RAISE EXCEPTION 'Test registration window has closed or is not configured';
  END IF;
  IF NOT app_private.resolve_permission('event.view','event',p_event_id,NULL,NULL) THEN
    RAISE EXCEPTION 'You cannot access this tournament';
  END IF;

  SELECT coalesce((
    SELECT s.allow_unverified_uid_for_test_registration
    FROM app_private.registration_test_settings s
    WHERE s.singleton
  ), false)
  INTO v_allow_unverified_uid;

  IF v_allow_unverified_uid THEN
    IF v_event.format = 'solo' THEN
      IF p_team_id IS NOT NULL THEN
        RAISE EXCEPTION 'Solo test registrations do not accept a team';
      END IF;
    ELSE
      IF p_team_id IS NULL THEN
        RAISE EXCEPTION 'Select a team for this test registration';
      END IF;
    END IF;
    v_eligible := app_private.is_event_test_registration_eligible_player(
      p_event_id, auth.uid(), p_team_id
    );
  ELSE
    v_eligible := app_private.is_event_registration_eligible_player(
      p_event_id, auth.uid(), p_team_id
    );
  END IF;

  IF NOT v_eligible THEN
    IF v_event.format = 'solo' THEN
      RAISE EXCEPTION 'You are not eligible for this tournament test registration';
    ELSE
      RAISE EXCEPTION 'Your team is not eligible for this tournament test registration';
    END IF;
  END IF;

  IF v_event.format <> 'solo' THEN
    SELECT count(*) INTO v_roster_size
    FROM public.team_members tm
    WHERE tm.team_id = p_team_id;
  END IF;

  INSERT INTO public.event_test_registrations(event_id,team_id,submitted_by)
  VALUES (p_event_id,p_team_id,auth.uid())
  RETURNING id INTO v_registration_id;

  IF v_event.format = 'solo' THEN
    INSERT INTO public.event_test_registration_players(registration_id,user_id,game_account_id)
    SELECT v_registration_id,auth.uid(),ga.id
    FROM public.game_accounts ga
    WHERE ga.user_id = auth.uid()
      AND ga.game_id = v_event.game_id
      AND ga.ownership_status <> 'rejected'
    ORDER BY ga.last_synced_at DESC NULLS LAST
    LIMIT 1;
    IF NOT FOUND THEN
      INSERT INTO public.event_test_registration_players(registration_id,user_id)
      VALUES (v_registration_id,auth.uid());
    END IF;
  ELSE
    INSERT INTO public.event_test_registration_players(registration_id,user_id,game_account_id)
    SELECT v_registration_id,tm.user_id,ga.id
    FROM public.team_members tm
    LEFT JOIN LATERAL (
      SELECT id FROM public.game_accounts
      WHERE user_id=tm.user_id
        AND game_id=v_event.game_id
        AND ownership_status <> 'rejected'
      ORDER BY last_synced_at DESC NULLS LAST
      LIMIT 1
    ) ga ON true
    WHERE tm.team_id=p_team_id;
  END IF;

  RETURN jsonb_build_object(
    'test_registration_id',v_registration_id,
    'status','submitted',
    'roster_size',v_roster_size,
    'is_test',true,
    'consumes_real_slot',false,
    'affects_standings',false,
    'ownership_verification_bypassed',v_allow_unverified_uid
  );
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'An active test registration already exists for this player or team';
END;
$function$;

REVOKE ALL ON FUNCTION app_private.submit_test_registration(uuid,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app_private.submit_test_registration(uuid,uuid)
  TO authenticated;
