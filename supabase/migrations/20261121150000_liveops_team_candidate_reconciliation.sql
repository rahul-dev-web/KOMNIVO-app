-- Canonical Team-ID result candidates and many-to-many screenshot provenance.
-- One candidate per Match ID + Team ID; multiple overlapping screenshot observations
-- are retained as separate evidence links and never create duplicate score rows.

ALTER TABLE public.result_candidates
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS reviewed_by uuid REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS review_note text NOT NULL DEFAULT '';

CREATE UNIQUE INDEX IF NOT EXISTS result_candidates_match_team_uidx
  ON public.result_candidates(match_id,team_id)
  WHERE team_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS result_candidates_team_match_status_idx
  ON public.result_candidates(team_id,match_id,review_status)
  WHERE team_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.result_candidate_evidence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_id uuid NOT NULL REFERENCES public.result_candidates(id) ON DELETE CASCADE,
  match_id uuid NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  team_id uuid NOT NULL REFERENCES public.teams(id),
  source_observation_id uuid NOT NULL REFERENCES public.screen_observations(id) ON DELETE CASCADE,
  capture_id uuid NOT NULL REFERENCES public.liveops_captures(id) ON DELETE CASCADE,
  evidence_batch_id uuid NOT NULL REFERENCES public.liveops_evidence_batches(id) ON DELETE CASCADE,
  reported_placement integer NOT NULL CHECK (reported_placement BETWEEN 1 AND 1000),
  reported_kills integer NOT NULL CHECK (reported_kills BETWEEN 0 AND 999),
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(candidate_id,source_observation_id),
  UNIQUE(match_id,team_id,source_observation_id)
);

CREATE INDEX IF NOT EXISTS result_candidate_evidence_batch_idx
  ON public.result_candidate_evidence(evidence_batch_id);
CREATE INDEX IF NOT EXISTS result_candidate_evidence_capture_idx
  ON public.result_candidate_evidence(capture_id);
CREATE INDEX IF NOT EXISTS result_candidate_evidence_observation_idx
  ON public.result_candidate_evidence(source_observation_id);

ALTER TABLE public.result_candidate_evidence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.result_candidate_evidence FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.result_candidate_evidence TO authenticated;
GRANT ALL ON public.result_candidate_evidence TO service_role;

DROP POLICY IF EXISTS result_candidates_read_team_or_staff
  ON public.result_candidates;
CREATE POLICY result_candidates_read_team_or_staff
  ON public.result_candidates FOR SELECT TO authenticated
  USING (
    (team_id IS NOT NULL AND app_private.is_team_member(team_id))
    OR EXISTS (
      SELECT 1 FROM public.matches m
      WHERE m.id=result_candidates.match_id
        AND (
          app_private.is_event_staff(m.event_id)
          OR app_private.resolve_permission('liveops.capture.submit','match',m.id,NULL,NULL)
        )
    )
  );

DROP POLICY IF EXISTS result_candidate_evidence_read_operator_or_reviewer
  ON public.result_candidate_evidence;
CREATE POLICY result_candidate_evidence_read_operator_or_reviewer
  ON public.result_candidate_evidence FOR SELECT TO authenticated
  USING (
    app_private.resolve_permission('liveops.capture.submit','match',match_id,NULL,NULL)
    OR app_private.resolve_permission('match.results.review','match',match_id,NULL,NULL)
  );

CREATE OR REPLACE FUNCTION app_private.save_liveops_team_candidate(
  p_session_id uuid,
  p_team_id uuid,
  p_placement integer,
  p_kills integer,
  p_source_observation_ids uuid[]
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
  v_candidate public.result_candidates%ROWTYPE;
  v_participant_count integer;
  v_source_count integer;
  v_source_ids uuid[];
  v_added integer := 0;
  v_before_status text;
  v_conflict boolean := false;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_session_id IS NULL OR p_team_id IS NULL THEN
    RAISE EXCEPTION 'LiveOps session and canonical Team ID are required';
  END IF;
  IF p_placement IS NULL OR p_placement < 1 OR p_kills IS NULL OR p_kills < 0 OR p_kills > 999 THEN
    RAISE EXCEPTION 'Enter a valid placement and kill count';
  END IF;
  IF p_source_observation_ids IS NULL OR cardinality(p_source_observation_ids) NOT BETWEEN 1 AND 8 THEN
    RAISE EXCEPTION 'Select between one and eight source screenshots';
  END IF;
  IF (SELECT count(DISTINCT x) FROM unnest(p_source_observation_ids) AS x)
     <> cardinality(p_source_observation_ids) THEN
    RAISE EXCEPTION 'A screenshot can be selected only once for a candidate';
  END IF;

  SELECT * INTO v_session
  FROM public.liveops_sessions s
  WHERE s.id=p_session_id AND s.operator_id=v_uid
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'LiveOps session not found'; END IF;
  IF v_session.state <> 'paused' THEN
    RAISE EXCEPTION 'Pause LiveOps observation before transcribing Match results';
  END IF;
  IF v_session.match_id IS NULL OR v_session.lobby_id IS NULL THEN
    RAISE EXCEPTION 'This LiveOps session is not bound to a platform Lobby and Match';
  END IF;
  IF NOT app_private.resolve_permission('liveops.capture.submit','match',v_session.match_id,NULL,NULL) THEN
    RAISE EXCEPTION 'You are not authorised to transcribe results for this Match ID' USING errcode='42501';
  END IF;

  SELECT * INTO v_match
  FROM public.matches m WHERE m.id=v_session.match_id;
  IF NOT FOUND OR v_match.event_id IS DISTINCT FROM v_session.event_id THEN
    RAISE EXCEPTION 'LiveOps session and Match ID do not match';
  END IF;
  SELECT * INTO v_event FROM public.events e WHERE e.id=v_match.event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tournament not found'; END IF;

  SELECT count(*) INTO v_participant_count
  FROM public.match_participants mp WHERE mp.match_id=v_match.id;
  IF p_placement > v_participant_count THEN
    RAISE EXCEPTION 'Placement cannot exceed the number of teams in this Match';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.match_participants mp
    WHERE mp.match_id=v_match.id AND mp.team_id=p_team_id
  ) THEN
    RAISE EXCEPTION 'The selected Team ID is not registered in this Match';
  END IF;

  SELECT count(DISTINCT o.id),array_agg(DISTINCT o.id) INTO v_source_count,v_source_ids
  FROM public.screen_observations o
  JOIN public.liveops_captures c ON c.id=o.liveops_capture_id
  JOIN public.liveops_evidence_batches b ON b.id=o.evidence_batch_id
  WHERE o.id=ANY(p_source_observation_ids)
    AND o.session_id=v_session.id
    AND o.evidence_batch_id IS NOT NULL
    AND c.session_id=v_session.id
    AND c.match_id=v_match.id
    AND c.event_id=v_event.id
    AND c.operator_id=v_uid
    AND c.review_status <> 'rejected'
    AND b.id=o.evidence_batch_id
    AND b.session_id=v_session.id
    AND b.lobby_id=v_session.lobby_id
    AND b.event_id=v_event.id
    AND b.match_id=v_match.id
    AND b.operator_id=v_uid
    AND b.status IN ('uploaded','submitted');
  IF v_source_count <> cardinality(p_source_observation_ids) THEN
    RAISE EXCEPTION 'Every selected screenshot must belong to this operator, Lobby ID, session and Match ID';
  END IF;

  SELECT * INTO v_candidate
  FROM public.result_candidates rc
  WHERE rc.match_id=v_match.id AND rc.team_id=p_team_id
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.result_candidates(
      match_id,source_observation_id,team_id,candidate_placement,candidate_kills,
      confidence,review_status,updated_at,review_note
    ) VALUES (
      v_match.id,v_source_ids[1],p_team_id,p_placement,p_kills,
      0.50,'needs_review',now(),
      'Manually transcribed from selected screenshot OCR. Awaiting authorised result review.'
    )
    ON CONFLICT (match_id,team_id) WHERE team_id IS NOT NULL DO NOTHING
    RETURNING * INTO v_candidate;

    IF NOT FOUND THEN
      SELECT * INTO v_candidate
      FROM public.result_candidates rc
      WHERE rc.match_id=v_match.id AND rc.team_id=p_team_id
      FOR UPDATE;
    END IF;
  END IF;

  IF v_candidate.id IS NOT NULL THEN
    v_before_status := v_candidate.review_status;
    IF v_candidate.review_status='accepted' THEN
      v_conflict := v_candidate.candidate_placement IS DISTINCT FROM p_placement
        OR v_candidate.candidate_kills IS DISTINCT FROM p_kills;
      IF v_conflict THEN
        UPDATE public.result_candidates
        SET review_status='needs_review',
            review_note='New overlapping screenshot evidence disagrees with the previously accepted values. Re-review required.',
            reviewed_by=NULL,reviewed_at=NULL,updated_at=now()
        WHERE id=v_candidate.id
        RETURNING * INTO v_candidate;
      END IF;
    ELSE
      UPDATE public.result_candidates
      SET source_observation_id=coalesce(source_observation_id,v_source_ids[1]),
          candidate_placement=p_placement,
          candidate_kills=p_kills,
          confidence=greatest(confidence,0.50),
          review_status='needs_review',
          review_note='Manually transcribed from selected screenshot OCR. Awaiting authorised result review.',
          reviewed_by=NULL,reviewed_at=NULL,updated_at=now()
      WHERE id=v_candidate.id
      RETURNING * INTO v_candidate;
    END IF;
  END IF;

  INSERT INTO public.result_candidate_evidence(
    candidate_id,match_id,team_id,source_observation_id,capture_id,evidence_batch_id,
    reported_placement,reported_kills,created_by
  )
  SELECT
    v_candidate.id,v_match.id,p_team_id,o.id,c.id,b.id,p_placement,p_kills,v_uid
  FROM public.screen_observations o
  JOIN public.liveops_captures c ON c.id=o.liveops_capture_id
  JOIN public.liveops_evidence_batches b ON b.id=o.evidence_batch_id
  WHERE o.id=ANY(v_source_ids)
  ON CONFLICT (match_id,team_id,source_observation_id) DO NOTHING;
  GET DIAGNOSTICS v_added = ROW_COUNT;

  INSERT INTO public.audit_logs(
    actor_id,community_id,event_id,entity_type,entity_id,action,reason,metadata
  ) VALUES (
    v_uid,v_event.community_id,v_event.id,'result_candidate',v_candidate.id,
    'liveops_team_candidate_saved',
    'Manual OCR transcription from selected evidence observations',
    jsonb_build_object(
      'session_id',v_session.id,
      'lobby_id',v_session.lobby_id,
      'match_id',v_match.id,
      'team_id',p_team_id,
      'placement',p_placement,
      'kills',p_kills,
      'observation_ids',v_source_ids,
      'new_source_links',v_added,
      'conflict_with_accepted_values',v_conflict,
      'previous_review_status',v_before_status,
      'review_status',v_candidate.review_status
    )
  );

  RETURN jsonb_build_object(
    'candidate_id',v_candidate.id,
    'match_id',v_match.id,
    'team_id',p_team_id,
    'placement',v_candidate.candidate_placement,
    'kills',v_candidate.candidate_kills,
    'review_status',v_candidate.review_status,
    'evidence_count',(SELECT count(*) FROM public.result_candidate_evidence e WHERE e.candidate_id=v_candidate.id),
    'new_source_links',v_added,
    'conflict_with_accepted_values',v_conflict
  );
END;
$function$;

REVOKE ALL ON FUNCTION app_private.save_liveops_team_candidate(uuid,uuid,integer,integer,uuid[])
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.save_liveops_team_candidate(uuid,uuid,integer,integer,uuid[])
  TO authenticated;

CREATE OR REPLACE FUNCTION public.save_liveops_team_candidate(
  p_session_id uuid,
  p_team_id uuid,
  p_placement integer,
  p_kills integer,
  p_source_observation_ids uuid[]
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $function$
  SELECT app_private.save_liveops_team_candidate(
    p_session_id,p_team_id,p_placement,p_kills,p_source_observation_ids
  );
$function$;

REVOKE ALL ON FUNCTION public.save_liveops_team_candidate(uuid,uuid,integer,integer,uuid[])
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_liveops_team_candidate(uuid,uuid,integer,integer,uuid[])
  TO authenticated;

COMMENT ON TABLE public.result_candidate_evidence IS
  'Many-to-many provenance: multiple overlapping screenshots can support one canonical Match ID + Team ID candidate without creating duplicate score rows.';
COMMENT ON COLUMN public.result_candidate_evidence.reported_placement IS
  'Placement transcribed from this specific screenshot source; kept separately to expose conflicts against other screenshots or accepted values.';
COMMENT ON COLUMN public.result_candidate_evidence.reported_kills IS
  'Kills transcribed from this specific screenshot source.';
