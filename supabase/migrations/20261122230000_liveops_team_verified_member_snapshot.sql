-- Organizer approval accepts the registered Team; it does not lock a player lineup.
-- LiveOps captures the current Team membership once for each Match and treats only
-- verified game accounts as eligible identity matches. Existing Community join and
-- minimum verified-player registration rules remain unchanged.

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
  v_snapshot_ready boolean := false;
  v_snapshot_at timestamptz := clock_timestamp();
  v_saved public.liveops_match_roster_snapshots%ROWTYPE;
  v_fingerprint text;
  v_reused boolean := false;
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
  FOR UPDATE;
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

  SELECT EXISTS (
    SELECT 1 FROM public.match_participants mp WHERE mp.match_id = v_match.id
  ) INTO v_snapshot_ready;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'team_id', mp.team_id,
      'team_name', t.name,
      'team_tag', t.tag,
      'slot_number', mp.slot_number,
      'registration_id', mp.registration_id,
      'snapshot_basis', 'team_members_at_capture',
      'team_member_count', (
        SELECT count(*)::integer
        FROM public.team_members tm
        WHERE tm.team_id = mp.team_id
      ),
      'verified_player_count', (
        SELECT count(DISTINCT tm.user_id)::integer
        FROM public.team_members tm
        JOIN public.game_accounts ga
          ON ga.user_id = tm.user_id
         AND ga.game_id = v_event.game_id
         AND ga.ownership_status = 'verified'
        WHERE tm.team_id = mp.team_id
      ),
      'community_member_count', (
        SELECT count(DISTINCT tm.user_id)::integer
        FROM public.team_members tm
        JOIN public.community_members cm
          ON cm.user_id = tm.user_id
         AND cm.community_id = v_event.community_id
        WHERE tm.team_id = mp.team_id
      ),
      'players', COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object(
            'user_id', tm.user_id,
            'team_role', tm.role,
            'team_joined_at', tm.joined_at,
            'is_community_member', EXISTS (
              SELECT 1 FROM public.community_members cm
              WHERE cm.community_id = v_event.community_id
                AND cm.user_id = tm.user_id
            ),
            'is_verified', ga.id IS NOT NULL,
            'game_account_id', CASE WHEN ga.id IS NOT NULL THEN ga.id ELSE NULL END,
            'uid', CASE WHEN ga.id IS NOT NULL THEN ga.uid ELSE NULL END,
            'region', CASE WHEN ga.id IS NOT NULL THEN
              COALESCE(
                snap.profile_json ->> 'region',
                snap.profile_json #>> '{basicInfo,region}',
                snap.profile_json #>> '{BasicInfo,region}',
                CASE WHEN snap.id IS NULL
                  AND ga.last_synced_at IS NOT NULL
                  AND ga.last_synced_at <= v_snapshot_at
                  THEN ga.region ELSE NULL END
              )
            ELSE NULL END,
            'nickname', CASE WHEN ga.id IS NOT NULL THEN
              COALESCE(
                snap.profile_json #>> '{basicInfo,nickname}',
                snap.profile_json #>> '{basicInfo,AccountName}',
                snap.profile_json #>> '{BasicInfo,nickname}',
                snap.profile_json #>> '{BasicInfo,AccountName}',
                snap.profile_json ->> 'nickname',
                CASE WHEN snap.id IS NULL
                  AND ga.last_synced_at IS NOT NULL
                  AND ga.last_synced_at <= v_snapshot_at
                  THEN ga.nickname ELSE NULL END
              )
            ELSE NULL END,
            'profile_snapshot_id', CASE WHEN ga.id IS NOT NULL THEN snap.id ELSE NULL END,
            'profile_snapshot_at', CASE WHEN ga.id IS NOT NULL THEN
              COALESCE(
                snap.captured_at,
                CASE WHEN ga.last_synced_at IS NOT NULL
                  AND ga.last_synced_at <= v_snapshot_at
                  THEN ga.last_synced_at ELSE NULL END
              )
            ELSE NULL END,
            'identity_snapshot_available',
              ga.id IS NOT NULL
              AND COALESCE(
                snap.profile_json #>> '{basicInfo,nickname}',
                snap.profile_json #>> '{basicInfo,AccountName}',
                snap.profile_json #>> '{BasicInfo,nickname}',
                snap.profile_json #>> '{BasicInfo,AccountName}',
                snap.profile_json ->> 'nickname',
                CASE WHEN snap.id IS NULL
                  AND ga.last_synced_at IS NOT NULL
                  AND ga.last_synced_at <= v_snapshot_at
                  THEN ga.nickname ELSE NULL END
              ) IS NOT NULL
          )
          ORDER BY tm.joined_at, tm.user_id
        )
        FROM public.team_members tm
        LEFT JOIN LATERAL (
          SELECT
            ga0.id, ga0.uid, ga0.region, ga0.nickname,
            ga0.last_synced_at, ga0.updated_at
          FROM public.game_accounts ga0
          WHERE ga0.user_id = tm.user_id
            AND ga0.game_id = v_event.game_id
            AND ga0.ownership_status = 'verified'
          ORDER BY ga0.last_synced_at DESC NULLS LAST,
                   ga0.updated_at DESC, ga0.id DESC
          LIMIT 1
        ) ga ON true
        LEFT JOIN LATERAL (
          SELECT gps.id, gps.profile_json, gps.captured_at
          FROM public.game_profile_snapshots gps
          WHERE gps.game_account_id = ga.id
            AND gps.captured_at <= v_snapshot_at
          ORDER BY gps.captured_at DESC, gps.id DESC
          LIMIT 1
        ) snap ON true
        WHERE tm.team_id = mp.team_id
      ), '[]'::jsonb)
    )
    ORDER BY mp.slot_number NULLS LAST, t.name, mp.team_id
  ), '[]'::jsonb)
  INTO v_roster
  FROM public.match_participants mp
  JOIN public.teams t ON t.id = mp.team_id
  WHERE mp.match_id = v_match.id;

  SELECT * INTO v_saved
  FROM public.liveops_match_roster_snapshots s
  WHERE s.match_id = v_match.id;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'session_id',v_session.id,
      'event_id',v_saved.event_id,
      'match_id',v_saved.match_id,
      'match_code',v_match.match_code,
      'snapshot_ready',true,
      'snapshot_model','team_verified_members_v1',
      'roster_basis','team_members_at_capture',
      'roster_snapshot_fingerprint',v_saved.snapshot_fingerprint,
      'roster_snapshot',v_saved.roster_snapshot,
      'snapshot_captured_at',v_saved.captured_at,
      'snapshot_reused',true
    );
  END IF;

  IF NOT v_snapshot_ready THEN
    RETURN jsonb_build_object(
      'session_id',v_session.id,
      'event_id',v_match.event_id,
      'match_id',v_match.id,
      'match_code',v_match.match_code,
      'snapshot_ready',false,
      'snapshot_model','team_verified_members_v1',
      'roster_basis','team_members_at_capture',
      'roster_snapshot_fingerprint',null,
      'roster_snapshot',v_roster,
      'snapshot_captured_at',null,
      'snapshot_reused',false
    );
  END IF;

  v_fingerprint := md5(v_match.id::text || ':' || v_roster::text);

  INSERT INTO public.liveops_match_roster_snapshots(
    session_id,event_id,match_id,captured_by,
    roster_snapshot,snapshot_fingerprint,captured_at
  ) VALUES (
    v_session.id,v_match.event_id,v_match.id,v_uid,
    v_roster,v_fingerprint,v_snapshot_at
  )
  ON CONFLICT (match_id) DO NOTHING
  RETURNING * INTO v_saved;

  IF NOT FOUND THEN
    SELECT * INTO v_saved
    FROM public.liveops_match_roster_snapshots s
    WHERE s.match_id = v_match.id;
    v_reused := true;
  END IF;

  RETURN jsonb_build_object(
    'session_id',v_session.id,
    'event_id',v_saved.event_id,
    'match_id',v_saved.match_id,
    'match_code',v_match.match_code,
    'snapshot_ready',true,
    'snapshot_model','team_verified_members_v1',
    'roster_basis','team_members_at_capture',
    'roster_snapshot_fingerprint',v_saved.snapshot_fingerprint,
    'roster_snapshot',v_saved.roster_snapshot,
    'snapshot_captured_at',v_saved.captured_at,
    'snapshot_reused',v_reused
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_liveops_match_roster_snapshot(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_liveops_match_roster_snapshot(uuid)
  TO authenticated;

COMMENT ON FUNCTION public.get_liveops_match_roster_snapshot(uuid) IS
  'Creates one immutable per-Match snapshot of every current Team member. Only verified game accounts expose matchable identity; no Organizer roster lock or registration_players list is used.';

-- Replace the old Organizer-only roster-lock gates in the existing published
-- roadmap, generated-match and direct-entry routines. Registration approval is
-- the acceptance gate; roster composition remains owned by each Team.
DO $unlocked$
DECLARE
  v_function regprocedure;
  v_definition text;
  v_unlocked_definition text;
  v_functions regprocedure[] := ARRAY[
    'public.generate_event_roadmap(uuid,integer,integer)'::regprocedure,
    'app_private.generate_event_stage_matches(uuid,integer,integer,timestamp with time zone)'::regprocedure,
    'public.advance_event_stage_from_roadmap(uuid,integer,integer,timestamp with time zone)'::regprocedure
  ];
BEGIN
  FOREACH v_function IN ARRAY v_functions LOOP
    v_definition := pg_get_functiondef(v_function);
    v_unlocked_definition := regexp_replace(
      v_definition,
      '(?i)\s+AND\s+[a-z_][a-z0-9_]*\.roster_locked\y',
      '',
      'g'
    );
    IF v_unlocked_definition = v_definition
       OR position('roster_locked' IN v_unlocked_definition) > 0 THEN
      RAISE EXCEPTION 'Could not safely remove every roster-lock gate from %', v_function;
    END IF;
    EXECUTE v_unlocked_definition;
  END LOOP;
END;
$unlocked$;

-- Disable the obsolete Organizer RPC so clients cannot reintroduce lineup locks.
CREATE OR REPLACE FUNCTION app_private.lock_event_rosters(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  RAISE EXCEPTION 'Organizer roster locking is disabled. Approved Team registration is accepted as-is; LiveOps snapshots current verified Team members automatically.'
    USING ERRCODE = '0A000';
END;
$function$;

REVOKE ALL ON FUNCTION public.lock_event_rosters(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION app_private.lock_event_rosters(uuid)
  FROM PUBLIC, anon, authenticated;
