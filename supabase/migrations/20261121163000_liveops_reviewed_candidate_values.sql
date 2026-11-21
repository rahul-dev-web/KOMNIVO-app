-- Reviewer-confirmed values are stored separately from provisional OCR/operator values.
ALTER TABLE public.result_candidates
  ADD COLUMN IF NOT EXISTS reviewed_placement integer,
  ADD COLUMN IF NOT EXISTS reviewed_kills integer;

ALTER TABLE public.result_candidates
  DROP CONSTRAINT IF EXISTS result_candidates_reviewed_placement_check,
  ADD CONSTRAINT result_candidates_reviewed_placement_check
    CHECK (reviewed_placement IS NULL OR reviewed_placement BETWEEN 1 AND 1000),
  DROP CONSTRAINT IF EXISTS result_candidates_reviewed_kills_check,
  ADD CONSTRAINT result_candidates_reviewed_kills_check
    CHECK (reviewed_kills IS NULL OR reviewed_kills BETWEEN 0 AND 999);

DROP FUNCTION IF EXISTS public.review_liveops_team_candidate(uuid,text,text);
DROP FUNCTION IF EXISTS app_private.review_liveops_team_candidate(uuid,text,text);

CREATE OR REPLACE FUNCTION app_private.review_liveops_team_candidate(
  p_candidate_id uuid,
  p_decision text,
  p_note text,
  p_reviewed_placement integer,
  p_reviewed_kills integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_candidate public.result_candidates%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_event public.events%ROWTYPE;
  v_evidence_count integer;
  v_conflict_count integer;
  v_participant_count integer;
  v_final_placement integer;
  v_final_kills integer;
  v_note text := left(coalesce(trim(p_note),''),2000);
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_candidate_id IS NULL OR p_decision IS NULL OR p_decision NOT IN ('accepted','rejected') THEN
    RAISE EXCEPTION 'Candidate ID and an accepted/rejected decision are required';
  END IF;

  SELECT * INTO v_candidate
  FROM public.result_candidates rc
  WHERE rc.id=p_candidate_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'OCR candidate not found'; END IF;

  SELECT * INTO v_match FROM public.matches m WHERE m.id=v_candidate.match_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Candidate Match ID no longer exists'; END IF;
  SELECT * INTO v_event FROM public.events e WHERE e.id=v_match.event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Candidate tournament no longer exists'; END IF;

  IF NOT app_private.resolve_permission('match.results.review','match',v_match.id,NULL,NULL) THEN
    RAISE EXCEPTION 'You are not authorised to review OCR candidates for this Match ID' USING errcode='42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.match_participants mp
    WHERE mp.match_id=v_match.id AND mp.team_id=v_candidate.team_id
  ) THEN
    RAISE EXCEPTION 'Candidate team is not a participant in this Match ID';
  END IF;

  SELECT count(*) INTO v_evidence_count
  FROM public.result_candidate_evidence e
  WHERE e.candidate_id=v_candidate.id
    AND e.match_id=v_match.id
    AND e.team_id=v_candidate.team_id;

  IF v_evidence_count < 1 OR v_candidate.candidate_placement IS NULL
     OR v_candidate.candidate_kills IS NULL THEN
    RAISE EXCEPTION 'A candidate needs at least one linked screenshot and complete placement/kills before review';
  END IF;

  SELECT count(*) INTO v_conflict_count
  FROM public.result_candidate_evidence e
  WHERE e.candidate_id=v_candidate.id
    AND (
      e.reported_placement IS DISTINCT FROM v_candidate.candidate_placement
      OR e.reported_kills IS DISTINCT FROM v_candidate.candidate_kills
    );

  IF v_candidate.review_status IN ('accepted','rejected') THEN
    IF v_candidate.review_status=p_decision
       AND (
         p_decision='rejected'
         OR (
           v_candidate.reviewed_placement=coalesce(p_reviewed_placement,v_candidate.reviewed_placement)
           AND v_candidate.reviewed_kills=coalesce(p_reviewed_kills,v_candidate.reviewed_kills)
         )
       ) THEN
      RETURN jsonb_build_object(
        'candidate_id',v_candidate.id,'match_id',v_match.id,'team_id',v_candidate.team_id,
        'review_status',v_candidate.review_status,'reviewed_by',v_candidate.reviewed_by,
        'reviewed_at',v_candidate.reviewed_at,'reviewed_placement',v_candidate.reviewed_placement,
        'reviewed_kills',v_candidate.reviewed_kills,'evidence_count',v_evidence_count,
        'conflict_count',v_conflict_count,'already_reviewed',true,'official_result_created',false
      );
    END IF;
    RAISE EXCEPTION 'This candidate has already been reviewed. Reopening it requires a separate audited correction workflow';
  END IF;

  IF v_candidate.review_status NOT IN ('provisional','needs_review') THEN
    RAISE EXCEPTION 'Candidate is not awaiting human review';
  END IF;

  v_final_placement := NULL;
  v_final_kills := NULL;
  IF p_decision='accepted' THEN
    IF v_conflict_count > 0 AND (p_reviewed_placement IS NULL OR p_reviewed_kills IS NULL) THEN
      RAISE EXCEPTION 'Screenshots disagree. Reviewer must confirm final placement and kills explicitly';
    END IF;
    v_final_placement := coalesce(p_reviewed_placement,v_candidate.candidate_placement);
    v_final_kills := coalesce(p_reviewed_kills,v_candidate.candidate_kills);

    SELECT count(*) INTO v_participant_count
    FROM public.match_participants mp WHERE mp.match_id=v_match.id;
    IF v_final_placement < 1 OR v_final_placement > v_participant_count
       OR v_final_kills < 0 OR v_final_kills > 999 THEN
      RAISE EXCEPTION 'Reviewer-confirmed placement or kills are outside the Match limits';
    END IF;
  END IF;

  UPDATE public.result_candidates
  SET review_status=p_decision,
      reviewed_by=v_uid,
      reviewed_at=now(),
      reviewed_placement=v_final_placement,
      reviewed_kills=v_final_kills,
      review_note=v_note,
      updated_at=now()
  WHERE id=p_candidate_id
  RETURNING * INTO v_candidate;

  INSERT INTO public.audit_logs(
    actor_id,community_id,event_id,entity_type,entity_id,action,reason,metadata
  ) VALUES (
    v_uid,v_event.community_id,v_event.id,'result_candidate',v_candidate.id,
    'liveops_team_candidate_'||p_decision,
    nullif(v_note,''),
    jsonb_build_object(
      'match_id',v_match.id,
      'team_id',v_candidate.team_id,
      'provisional_placement',v_candidate.candidate_placement,
      'provisional_kills',v_candidate.candidate_kills,
      'reviewed_placement',v_candidate.reviewed_placement,
      'reviewed_kills',v_candidate.reviewed_kills,
      'evidence_count',v_evidence_count,
      'evidence_conflict_count',v_conflict_count,
      'review_status',p_decision,
      'official_result_created',false
    )
  );

  RETURN jsonb_build_object(
    'candidate_id',v_candidate.id,'match_id',v_match.id,'team_id',v_candidate.team_id,
    'placement',v_candidate.candidate_placement,'kills',v_candidate.candidate_kills,
    'reviewed_placement',v_candidate.reviewed_placement,'reviewed_kills',v_candidate.reviewed_kills,
    'review_status',v_candidate.review_status,'reviewed_by',v_uid,
    'reviewed_at',v_candidate.reviewed_at,'evidence_count',v_evidence_count,
    'conflict_count',v_conflict_count,'already_reviewed',false,'official_result_created',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION app_private.review_liveops_team_candidate(uuid,text,text,integer,integer)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.review_liveops_team_candidate(uuid,text,text,integer,integer)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.review_liveops_team_candidate(
  p_candidate_id uuid,
  p_decision text,
  p_note text,
  p_reviewed_placement integer,
  p_reviewed_kills integer
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $function$
  SELECT app_private.review_liveops_team_candidate(
    p_candidate_id,p_decision,p_note,p_reviewed_placement,p_reviewed_kills
  );
$function$;

REVOKE ALL ON FUNCTION public.review_liveops_team_candidate(uuid,text,text,integer,integer)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.review_liveops_team_candidate(uuid,text,text,integer,integer)
  TO authenticated;

COMMENT ON COLUMN public.result_candidates.reviewed_placement IS
  'Reviewer-confirmed final placement. Separate from provisional operator/OCR transcription; intended input for future official result submission.';
COMMENT ON COLUMN public.result_candidates.reviewed_kills IS
  'Reviewer-confirmed final kills. Separate from provisional operator/OCR transcription; intended input for future official result submission.';
