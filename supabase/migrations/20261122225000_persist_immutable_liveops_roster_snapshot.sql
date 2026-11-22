-- Persist the first complete, explicitly locked player/slot identity snapshot
-- for each LiveOps Match session. Subsequent reads return the saved copy even
-- if a later profile refresh or Match participant slot edit occurs.

CREATE TABLE IF NOT EXISTS public.liveops_match_roster_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL
    REFERENCES public.liveops_sessions(id) ON DELETE RESTRICT,
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE RESTRICT,
  match_id uuid NOT NULL UNIQUE REFERENCES public.matches(id) ON DELETE RESTRICT,
  captured_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  roster_snapshot jsonb NOT NULL,
  snapshot_fingerprint text NOT NULL,
  captured_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS liveops_match_roster_snapshots_match_idx
  ON public.liveops_match_roster_snapshots(match_id,captured_at DESC);

ALTER TABLE public.liveops_match_roster_snapshots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.liveops_match_roster_snapshots FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.liveops_match_roster_snapshots TO service_role;

CREATE OR REPLACE FUNCTION app_private.prevent_liveops_roster_snapshot_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  RAISE EXCEPTION 'A captured LiveOps Match roster snapshot is immutable';
END;
$function$;

DROP TRIGGER IF EXISTS liveops_match_roster_snapshots_immutable
  ON public.liveops_match_roster_snapshots;
CREATE TRIGGER liveops_match_roster_snapshots_immutable
BEFORE UPDATE OR DELETE ON public.liveops_match_roster_snapshots
FOR EACH ROW EXECUTE FUNCTION app_private.prevent_liveops_roster_snapshot_mutation();

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
  v_saved public.liveops_match_roster_snapshots%ROWTYPE;
  v_fingerprint text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_session_id IS NULL THEN
    RAISE EXCEPTION 'LiveOps session ID is required';
  END IF;

  -- Serialise snapshot creation per session. A second read reuses the first
  -- captured snapshot, never rebuilding it from mutable participant/profile rows.
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

  SELECT * INTO v_saved
  FROM public.liveops_match_roster_snapshots s
  WHERE s.match_id = v_session.match_id;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'session_id',v_session.id,
      'event_id',v_saved.event_id,
      'match_id',v_saved.match_id,
      'match_code',(SELECT m.match_code FROM public.matches m WHERE m.id=v_saved.match_id),
      'roster_locked',true,
      'roster_snapshot_fingerprint',v_saved.snapshot_fingerprint,
      'roster_snapshot',v_saved.roster_snapshot,
      'snapshot_captured_at',v_saved.captured_at,
      'snapshot_reused',true
    );
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
      'players', CASE WHEN v_roster_locked THEN COALESCE((
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
              WHEN ga.ownership_status = 'verified' THEN
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
              WHEN ga.ownership_status = 'verified' THEN
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
            'profile_snapshot_id', snap.id,
            'profile_snapshot_at', COALESCE(
              snap.captured_at,
              CASE WHEN ga.last_synced_at IS NOT NULL
                AND ga.last_synced_at <= r.roster_locked_at
                THEN ga.last_synced_at ELSE NULL END
            ),
            'identity_snapshot_available',
              ga.ownership_status = 'verified'
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
            AND gps.captured_at <= r.roster_locked_at
          ORDER BY gps.captured_at DESC, gps.id DESC
          LIMIT 1
        ) snap ON true
        WHERE rp.registration_id = mp.registration_id
      ), '[]'::jsonb) ELSE '[]'::jsonb END
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

  IF NOT v_roster_locked THEN
    RETURN jsonb_build_object(
      'session_id',v_session.id,
      'event_id',v_match.event_id,
      'match_id',v_match.id,
      'match_code',v_match.match_code,
      'roster_locked',false,
      'roster_snapshot_fingerprint',null,
      'roster_snapshot',v_roster,
      'snapshot_captured_at',null,
      'snapshot_reused',false
    );
  END IF;

  v_fingerprint := md5(v_match.id::text || ':' || v_roster::text);

  INSERT INTO public.liveops_match_roster_snapshots(
    session_id,event_id,match_id,captured_by,
    roster_snapshot,snapshot_fingerprint
  ) VALUES (
    v_session.id,v_match.event_id,v_match.id,v_uid,
    v_roster,v_fingerprint
  )
  ON CONFLICT (match_id) DO NOTHING
  RETURNING * INTO v_saved;

  IF NOT FOUND THEN
    SELECT * INTO v_saved
    FROM public.liveops_match_roster_snapshots s
    WHERE s.match_id = v_session.match_id;
  END IF;

  RETURN jsonb_build_object(
    'session_id',v_session.id,
    'event_id',v_saved.event_id,
    'match_id',v_saved.match_id,
    'match_code',v_match.match_code,
    'roster_locked',true,
    'roster_snapshot_fingerprint',v_saved.snapshot_fingerprint,
    'roster_snapshot',v_saved.roster_snapshot,
    'snapshot_captured_at',v_saved.captured_at,
    'snapshot_reused',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_liveops_match_roster_snapshot(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_liveops_match_roster_snapshot(uuid)
  TO authenticated;

COMMENT ON TABLE public.liveops_match_roster_snapshots IS
  'Immutable first-read player identity and slot snapshot for each LiveOps session/Match, captured only after every assigned registration has an explicit roster lock.';

COMMENT ON FUNCTION public.get_liveops_match_roster_snapshot(uuid) IS
  'Creates once and reuses an immutable operator-scoped Match roster snapshot after explicit lock. Frozen slots, verified UIDs and profile values never change on later reads for the same LiveOps session.';
