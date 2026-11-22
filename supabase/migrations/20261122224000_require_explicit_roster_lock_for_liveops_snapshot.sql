-- Require the Match's event registrations to be explicitly roster-locked before
-- enabling expected-player comparison. Profile identity is read only as of
-- roster_locked_at; registered_at is not a substitute for a roster lock.

CREATE OR REPLACE FUNCTION public.get_liveops_match_roster_snapshot(
  p_session_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_session public.liveops_sessions%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_event public.events%ROWTYPE;
  v_roster jsonb := '[]'::jsonb;
  v_roster_locked boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_session_id IS NULL THEN
    RAISE EXCEPTION 'LiveOps session ID is required';
  END IF;

  SELECT * INTO v_session
  FROM public.liveops_sessions s
  WHERE s.id = p_session_id
    AND s.operator_id = v_uid
    AND s.state IN ('created','capturing','paused')
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active LiveOps session not found for this operator';
  END IF;
  IF v_session.match_id IS NULL OR v_session.event_id IS NULL THEN
    RAISE EXCEPTION 'This LiveOps session is not bound to an Event and Match';
  END IF;
  IF NOT app_private.resolve_permission(
    'event.matches.operate','event',v_session.event_id,NULL,NULL
  ) THEN
    RAISE EXCEPTION 'You are not authorised to inspect this Match roster'
      USING errcode='42501';
  END IF;

  SELECT * INTO v_match
  FROM public.matches m
  WHERE m.id = v_session.match_id
    AND m.event_id = v_session.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The session Match does not belong to its Event';
  END IF;

  SELECT * INTO v_event
  FROM public.events e
  WHERE e.id = v_match.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The Match Event no longer exists';
  END IF;

  SELECT count(*) > 0
    AND COALESCE(bool_and(
      r.roster_locked IS TRUE AND r.roster_locked_at IS NOT NULL
    ), false)
  INTO v_roster_locked
  FROM public.match_participants mp
  LEFT JOIN public.event_registrations r
    ON r.id = mp.registration_id
   AND r.event_id = v_match.event_id
  WHERE mp.match_id = v_match.id;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'team_id', mp.team_id,
      'team_name', t.name,
      'team_tag', t.tag,
      'slot_number', mp.slot_number,
      'registration_id', mp.registration_id,
      'roster_locked', (
        r.roster_locked IS TRUE AND r.roster_locked_at IS NOT NULL
      ),
      'roster_locked_at', r.roster_locked_at,
      'players', COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object(
            'user_id', rp.user_id,
            'is_verified', (
              ga.id IS NOT NULL AND ga.ownership_status = 'verified'
            ),
            'game_account_id', CASE
              WHEN ga.ownership_status = 'verified' THEN ga.id ELSE NULL END,
            'uid', CASE
              WHEN ga.ownership_status = 'verified' THEN ga.uid ELSE NULL END,
            'region', CASE
              WHEN ga.ownership_status = 'verified' AND v_roster_locked THEN
                COALESCE(
                  snap.profile_json ->> 'region',
                  snap.profile_json #>> '{basicInfo,region}',
                  snap.profile_json #>> '{BasicInfo,region}',
                  CASE WHEN snap.id IS NULL
                    AND ga.last_synced_at IS NOT NULL
                    AND ga.last_synced_at <= r.roster_locked_at
                    THEN ga.region ELSE NULL END
                )
              ELSE NULL END,
            'nickname', CASE
              WHEN ga.ownership_status = 'verified' AND v_roster_locked THEN
                COALESCE(
                  snap.profile_json #>> '{basicInfo,nickname}',
                  snap.profile_json #>> '{basicInfo,AccountName}',
                  snap.profile_json #>> '{BasicInfo,nickname}',
                  snap.profile_json #>> '{BasicInfo,AccountName}',
                  snap.profile_json ->> 'nickname',
                  CASE WHEN snap.id IS NULL
                    AND ga.last_synced_at IS NOT NULL
                    AND ga.last_synced_at <= r.roster_locked_at
                    THEN ga.nickname ELSE NULL END
                )
              ELSE NULL END,
            'profile_snapshot_id', CASE
              WHEN v_roster_locked AND ga.ownership_status = 'verified'
                THEN snap.id ELSE NULL END,
            'profile_snapshot_at', CASE
              WHEN v_roster_locked AND ga.ownership_status = 'verified' THEN
                COALESCE(
                  snap.captured_at,
                  CASE WHEN ga.last_synced_at IS NOT NULL
                    AND ga.last_synced_at <= r.roster_locked_at
                    THEN ga.last_synced_at ELSE NULL END
                )
              ELSE NULL END,
            'identity_snapshot_available',
              v_roster_locked
              AND ga.ownership_status = 'verified'
              AND COALESCE(
                snap.profile_json #>> '{basicInfo,nickname}',
                snap.profile_json #>> '{basicInfo,AccountName}',
                snap.profile_json #>> '{BasicInfo,nickname}',
                snap.profile_json #>> '{BasicInfo,AccountName}',
                snap.profile_json ->> 'nickname',
                CASE WHEN snap.id IS NULL
                  AND ga.last_synced_at IS NOT NULL
                  AND ga.last_synced_at <= r.roster_locked_at
                  THEN ga.nickname ELSE NULL END
              ) IS NOT NULL
          )
          ORDER BY rp.user_id
        )
        FROM public.registration_players rp
        LEFT JOIN public.game_accounts ga
          ON ga.id = rp.game_account_id
         AND ga.user_id = rp.user_id
         AND ga.game_id = v_event.game_id
        LEFT JOIN LATERAL (
          SELECT gps.id, gps.profile_json, gps.captured_at
          FROM public.game_profile_snapshots gps
          WHERE gps.game_account_id = rp.game_account_id
            AND r.roster_locked_at IS NOT NULL
            AND gps.captured_at <= r.roster_locked_at
          ORDER BY gps.captured_at DESC, gps.id DESC
          LIMIT 1
        ) snap ON true
        WHERE rp.registration_id = mp.registration_id
      ), '[]'::jsonb)
    )
    ORDER BY mp.slot_number NULLS LAST, t.name, mp.team_id
  ), '[]'::jsonb)
  INTO v_roster
  FROM public.match_participants mp
  JOIN public.teams t ON t.id = mp.team_id
  LEFT JOIN public.event_registrations r
    ON r.id = mp.registration_id
   AND r.event_id = v_match.event_id
  WHERE mp.match_id = v_match.id;

  RETURN jsonb_build_object(
    'session_id', v_session.id,
    'event_id', v_match.event_id,
    'match_id', v_match.id,
    'match_code', v_match.match_code,
    'roster_locked', v_roster_locked,
    'roster_snapshot_fingerprint', CASE
      WHEN v_roster_locked THEN md5(v_match.id::text || ':' || v_roster::text)
      ELSE NULL END,
    'roster_snapshot', v_roster
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_liveops_match_roster_snapshot(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_liveops_match_roster_snapshot(uuid)
  TO authenticated;

COMMENT ON FUNCTION public.get_liveops_match_roster_snapshot(uuid) IS
  'Operator-scoped snapshot for the exact LiveOps Match. It enables player comparison only after every Match participant registration is explicitly roster-locked. Profile values are read as-of roster_locked_at, and later IGN refreshes cannot rewrite the locked Match identity.';
