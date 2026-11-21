-- Submit only human-accepted LiveOps OCR candidates to the existing official
-- match_results review/scoring pipeline. This function does not approve or score results.

CREATE OR REPLACE FUNCTION app_private.guard_liveops_candidate_lock_after_submission()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_match_id uuid := NEW.match_id;
BEGIN
  IF TG_OP='UPDATE' AND (
    NEW.match_id IS DISTINCT FROM OLD.match_id
    OR NEW.team_id IS DISTINCT FROM OLD.team_id
  ) THEN
    RAISE EXCEPTION 'Canonical candidate Match ID and Team ID cannot be reassigned';
  END IF;

  PERFORM 1
  FROM public.matches m
  WHERE m.id=v_match_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Candidate Match ID no longer exists';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.match_results mr
    WHERE mr.match_id=v_match_id
  ) THEN
    RAISE EXCEPTION 'Official result submission already exists for this Match ID. Use the audited result correction/dispute workflow';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.guard_liveops_candidate_lock_after_submission()
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.guard_liveops_candidate_lock_after_submission()
  TO service_role;

DROP TRIGGER IF EXISTS result_candidates_lock_after_official_submission
  ON public.result_candidates;
CREATE TRIGGER result_candidates_lock_after_official_submission
  BEFORE INSERT OR UPDATE ON public.result_candidates
  FOR EACH ROW EXECUTE FUNCTION app_private.guard_liveops_candidate_lock_after_submission();

CREATE OR REPLACE FUNCTION app_private.submit_reviewed_liveops_match_results(
  p_session_id uuid,
  p_match_id uuid
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
  v_participant_count integer;
  v_accepted_count integer;
  v_evidence_count integer;
  v_invalid_evidence_count integer;
  v_existing_count integer;
  v_existing_exact_count integer;
  v_result_id uuid;
  v_result_ids uuid[] := ARRAY[]::uuid[];
  v_result_items jsonb := '[]'::jsonb;
  v_candidate record;
  v_evidence record;
  v_candidate_result_ids uuid[] := ARRAY[]::uuid[];
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_session_id IS NULL OR p_match_id IS NULL THEN
    RAISE EXCEPTION 'LiveOps session and Match ID are required';
  END IF;

  SELECT * INTO v_session
  FROM public.liveops_sessions s
  WHERE s.id=p_session_id AND s.operator_id=v_uid
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'LiveOps session not found for this operator';
  END IF;
  IF v_session.state <> 'paused' THEN
    RAISE EXCEPTION 'Pause LiveOps observation before submitting reviewed results';
  END IF;
  IF v_session.match_id IS DISTINCT FROM p_match_id
     OR v_session.lobby_id IS NULL THEN
    RAISE EXCEPTION 'LiveOps session is not bound to this exact Lobby and Match ID';
  END IF;
  IF NOT app_private.resolve_permission('liveops.capture.submit','match',p_match_id,NULL,NULL) THEN
    RAISE EXCEPTION 'You are not authorised to submit results for this Match ID' USING errcode='42501';
  END IF;

  -- Serialise submission with candidate saves/reviews using the Match row lock.
  SELECT * INTO v_match
  FROM public.matches m
  WHERE m.id=p_match_id
  FOR UPDATE;
  IF NOT FOUND OR v_match.event_id IS DISTINCT FROM v_session.event_id THEN
    RAISE EXCEPTION 'LiveOps session and Match ID do not match';
  END IF;
  IF v_match.status IN ('completed','cancelled') THEN
    RAISE EXCEPTION 'This Match ID is already closed';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.event_lobby_matches lm
    WHERE lm.lobby_id=v_session.lobby_id AND lm.match_id=p_match_id
  ) THEN
    RAISE EXCEPTION 'This Match ID is not assigned to the LiveOps Lobby';
  END IF;

  SELECT * INTO v_event
  FROM public.events e WHERE e.id=v_match.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tournament no longer exists';
  END IF;

  SELECT count(*) INTO v_participant_count
  FROM public.match_participants mp
  WHERE mp.match_id=p_match_id;
  IF v_participant_count < 2 OR v_participant_count > 24 THEN
    RAISE EXCEPTION 'This Match must have between 2 and 24 registered teams';
  END IF;

  -- A retry after a lost network response returns the same result IDs only if
  -- every official row is from this exact session and candidate revision.
  SELECT count(*) INTO v_existing_count
  FROM public.match_results mr
  WHERE mr.match_id=p_match_id;

  IF v_existing_count > 0 THEN
    SELECT count(*) INTO v_existing_exact_count
    FROM public.match_results mr
    JOIN public.result_candidates rc
      ON rc.id=nullif(mr.result_json->>'candidate_id','')::uuid
     AND rc.match_id=mr.match_id
     AND rc.team_id=mr.team_id
    WHERE mr.match_id=p_match_id
      AND mr.result_json->>'source'='liveops_reviewed_candidates'
      AND mr.result_json->>'liveops_session_id'=p_session_id::text
      AND mr.placement=rc.reviewed_placement
      AND mr.kills=rc.reviewed_kills
      AND rc.review_status='accepted'
      AND rc.reviewed_by IS NOT NULL;

    IF v_existing_count=v_participant_count
       AND v_existing_exact_count=v_participant_count THEN
      SELECT coalesce(array_agg(mr.id ORDER BY mr.placement),ARRAY[]::uuid[]),
             coalesce(jsonb_agg(jsonb_build_object(
               'result_id',mr.id,'team_id',mr.team_id,
               'placement',mr.placement,'kills',mr.kills,'status',mr.status
             ) ORDER BY mr.placement),'[]'::jsonb)
      INTO v_result_ids,v_result_items
      FROM public.match_results mr
      WHERE mr.match_id=p_match_id;
      RETURN jsonb_build_object(
        'match_id',p_match_id,'lobby_id',v_session.lobby_id,
        'result_ids',to_jsonb(v_result_ids),'results',v_result_items,
        'submitted_count',v_existing_count,'status','submitted_for_review',
        'already_submitted',true,'official_results_approved',false
      );
    END IF;
    RAISE EXCEPTION 'Official results already exist for this Match ID. Review or resolve them before another submission';
  END IF;

  -- Require exactly one accepted candidate with reviewer-confirmed values for
  -- every registered participant, with a complete and unique placement order.
  SELECT count(*) INTO v_accepted_count
  FROM public.match_participants mp
  JOIN public.result_candidates rc
    ON rc.match_id=mp.match_id AND rc.team_id=mp.team_id
  WHERE mp.match_id=p_match_id
    AND rc.review_status='accepted'
    AND rc.reviewed_by IS NOT NULL
    AND rc.reviewed_at IS NOT NULL
    AND rc.reviewed_placement BETWEEN 1 AND v_participant_count
    AND rc.reviewed_kills BETWEEN 0 AND 999;

  IF v_accepted_count <> v_participant_count THEN
    RAISE EXCEPTION 'Every Match participant needs one accepted OCR candidate with reviewer-confirmed placement and kills';
  END IF;

  IF (
    SELECT count(DISTINCT rc.reviewed_placement)
    FROM public.match_participants mp
    JOIN public.result_candidates rc
      ON rc.match_id=mp.match_id AND rc.team_id=mp.team_id
    WHERE mp.match_id=p_match_id
      AND rc.review_status='accepted'
  ) <> v_participant_count THEN
    RAISE EXCEPTION 'Reviewer-confirmed placements must be unique across all teams in this Match';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.result_candidates rc
    LEFT JOIN public.match_participants mp
      ON mp.match_id=rc.match_id AND mp.team_id=rc.team_id
    WHERE rc.match_id=p_match_id AND rc.team_id IS NOT NULL
      AND mp.team_id IS NULL
  ) THEN
    RAISE EXCEPTION 'A candidate is linked to a team outside this Match roster';
  END IF;

  -- Every accepted candidate must have at least one still-present screenshot.
  IF EXISTS (
    SELECT 1
    FROM public.match_participants mp
    JOIN public.result_candidates rc
      ON rc.match_id=mp.match_id AND rc.team_id=mp.team_id
    LEFT JOIN public.result_candidate_evidence e ON e.candidate_id=rc.id
    WHERE mp.match_id=p_match_id
    GROUP BY rc.id
    HAVING count(e.id)=0
  ) THEN
    RAISE EXCEPTION 'Every accepted team result needs at least one linked screenshot';
  END IF;

  SELECT count(*) INTO v_invalid_evidence_count
  FROM public.match_participants mp
  JOIN public.result_candidates rc
    ON rc.match_id=mp.match_id AND rc.team_id=mp.team_id
  JOIN public.result_candidate_evidence e ON e.candidate_id=rc.id
  LEFT JOIN public.liveops_captures c ON c.id=e.capture_id
  LEFT JOIN public.liveops_evidence_batches b ON b.id=e.evidence_batch_id
  WHERE mp.match_id=p_match_id
    AND (
      c.id IS NULL
      OR c.match_id IS DISTINCT FROM p_match_id
      OR c.event_id IS DISTINCT FROM v_match.event_id
      OR c.review_status='rejected'
      OR b.id IS NULL
      OR b.match_id IS DISTINCT FROM p_match_id
      OR b.event_id IS DISTINCT FROM v_match.event_id
      OR b.lobby_id IS DISTINCT FROM v_session.lobby_id
      OR NOT EXISTS (
        SELECT 1 FROM storage.objects o
        WHERE o.bucket_id='match-evidence' AND o.name=c.evidence_path
      )
    );
  IF v_invalid_evidence_count > 0 THEN
    RAISE EXCEPTION 'One or more candidate screenshot sources are missing, rejected or outside this Lobby/Match scope';
  END IF;

  FOR v_candidate IN
    SELECT rc.id,rc.team_id,rc.candidate_placement,rc.candidate_kills,
           rc.reviewed_placement,rc.reviewed_kills,rc.reviewed_by,rc.reviewed_at,
           rc.review_note
    FROM public.match_participants mp
    JOIN public.result_candidates rc
      ON rc.match_id=mp.match_id AND rc.team_id=mp.team_id
    WHERE mp.match_id=p_match_id
      AND rc.review_status='accepted'
    ORDER BY rc.reviewed_placement
  LOOP
    SELECT count(DISTINCT e.id) INTO v_evidence_count
    FROM public.result_candidate_evidence e
    WHERE e.candidate_id=v_candidate.id;

    INSERT INTO public.match_results(
      match_id,team_id,submitted_by,placement,kills,points,status,result_json
    ) VALUES (
      p_match_id,v_candidate.team_id,v_uid,
      v_candidate.reviewed_placement,v_candidate.reviewed_kills,0,'submitted',
      jsonb_build_object(
        'source','liveops_reviewed_candidates',
        'liveops_session_id',p_session_id,
        'lobby_id',v_session.lobby_id,
        'candidate_id',v_candidate.id,
        'provisional_placement',v_candidate.candidate_placement,
        'provisional_kills',v_candidate.candidate_kills,
        'reviewed_placement',v_candidate.reviewed_placement,
        'reviewed_kills',v_candidate.reviewed_kills,
        'candidate_reviewed_by',v_candidate.reviewed_by,
        'candidate_reviewed_at',v_candidate.reviewed_at,
        'candidate_review_note',v_candidate.review_note,
        'evidence_count',v_evidence_count
      )
    )
    RETURNING id INTO v_result_id;

    INSERT INTO public.result_evidence(
      result_id,uploaded_by,storage_path,content_type,file_size
    )
    SELECT DISTINCT
      v_result_id,c.operator_id,c.evidence_path,c.content_type,c.file_size
    FROM public.result_candidate_evidence e
    JOIN public.liveops_captures c ON c.id=e.capture_id
    WHERE e.candidate_id=v_candidate.id
    ORDER BY c.evidence_path;

    v_result_ids := array_append(v_result_ids,v_result_id);
    v_candidate_result_ids := array_append(v_candidate_result_ids,v_candidate.id);
    v_result_items := v_result_items || jsonb_build_array(jsonb_build_object(
      'result_id',v_result_id,
      'candidate_id',v_candidate.id,
      'team_id',v_candidate.team_id,
      'placement',v_candidate.reviewed_placement,
      'kills',v_candidate.reviewed_kills,
      'evidence_count',v_evidence_count,
      'status','submitted'
    ));
  END LOOP;

  UPDATE public.liveops_evidence_batches b
  SET status='submitted'
  WHERE b.id IN (
    SELECT DISTINCT e.evidence_batch_id
    FROM public.result_candidate_evidence e
    JOIN public.result_candidates rc ON rc.id=e.candidate_id
    WHERE rc.match_id=p_match_id
      AND rc.team_id IN (SELECT mp.team_id FROM public.match_participants mp WHERE mp.match_id=p_match_id)
  );

  UPDATE public.matches
  SET status='review'
  WHERE id=p_match_id;

  INSERT INTO public.audit_logs(
    actor_id,community_id,event_id,entity_type,entity_id,action,reason,metadata
  ) VALUES (
    v_uid,v_event.community_id,v_event.id,'match',p_match_id,
    'liveops_reviewed_results_submitted',
    'Every team candidate was accepted by an authorised reviewer before official result submission',
    jsonb_build_object(
      'session_id',p_session_id,
      'lobby_id',v_session.lobby_id,
      'candidate_ids',v_candidate_result_ids,
      'result_ids',v_result_ids,
      'team_count',v_participant_count,
      'status','submitted_for_review',
      'official_results_approved',false
    )
  );

  RETURN jsonb_build_object(
    'match_id',p_match_id,'lobby_id',v_session.lobby_id,
    'result_ids',to_jsonb(v_result_ids),'results',v_result_items,
    'submitted_count',cardinality(v_result_ids),
    'status','submitted_for_review',
    'already_submitted',false,
    'official_results_approved',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION app_private.submit_reviewed_liveops_match_results(uuid,uuid)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION app_private.submit_reviewed_liveops_match_results(uuid,uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.submit_reviewed_liveops_match_results(
  p_session_id uuid,
  p_match_id uuid
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $function$
  SELECT app_private.submit_reviewed_liveops_match_results(p_session_id,p_match_id);
$function$;

REVOKE ALL ON FUNCTION public.submit_reviewed_liveops_match_results(uuid,uuid)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.submit_reviewed_liveops_match_results(uuid,uuid)
  TO authenticated;

COMMENT ON FUNCTION public.submit_reviewed_liveops_match_results(uuid,uuid) IS
  'Materialises one reviewer-accepted candidate per Match participant into submitted match_results with candidate-specific screenshot evidence. Idempotent per LiveOps session and Match. Does not approve results, calculate points or publish standings.';
