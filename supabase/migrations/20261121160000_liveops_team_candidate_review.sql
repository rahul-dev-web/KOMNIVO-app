-- Authorised human review for provisional OCR team candidates.
-- Accepting a candidate does not create a match_result or update standings.

CREATE OR REPLACE FUNCTION app_private.review_liveops_team_candidate(
  p_candidate_id uuid,
  p_decision text,
  p_note text DEFAULT NULL
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
  v_note text := left(coalesce(trim(p_note),''),2000);
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_candidate_id IS NULL OR p_decision NOT IN ('accepted','rejected') THEN
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

  IF v_candidate.review_status IN ('accepted','rejected') THEN
    IF v_candidate.review_status=p_decision THEN
      RETURN jsonb_build_object(
        'candidate_id',v_candidate.id,'match_id',v_match.id,'team_id',v_candidate.team_id,
        'review_status',v_candidate.review_status,'reviewed_by',v_candidate.reviewed_by,
        'reviewed_at',v_candidate.reviewed_at,'evidence_count',v_evidence_count,
        'already_reviewed',true,'official_result_created',false
      );
    END IF;
    RAISE EXCEPTION 'This candidate has already been reviewed. Reopening it requires a separate audited correction workflow';
  END IF;

  IF v_candidate.review_status NOT IN ('provisional','needs_review') THEN
    RAISE EXCEPTION 'Candidate is not awaiting human review';
  END IF;

  UPDATE public.result_candidates
  SET review_status=p_decision,
      reviewed_by=v_uid,
      reviewed_at=now(),
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
      'placement',v_candidate.candidate_placement,
      'kills',v_candidate.candidate_kills,
      'evidence_count',v_evidence_count,
      'review_status',p_decision,
      'official_result_created',false
    )
  );

  RETURN jsonb_build_object(
    'candidate_id',v_candidate.id,'match_id',v_match.id,'team_id',v_candidate.team_id,
    'placement',v_candidate.candidate_placement,'kills',v_candidate.candidate_kills,
    'review_status',v_candidate.review_status,'reviewed_by',v_uid,
    'reviewed_at',v_candidate.reviewed_at,'evidence_count',v_evidence_count,
    'already_reviewed',false,'official_result_created',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION app_private.review_liveops_team_candidate(uuid,text,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.review_liveops_team_candidate(uuid,text,text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.review_liveops_team_candidate(
  p_candidate_id uuid,
  p_decision text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $function$
  SELECT app_private.review_liveops_team_candidate(p_candidate_id,p_decision,p_note);
$function$;

REVOKE ALL ON FUNCTION public.review_liveops_team_candidate(uuid,text,text)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.review_liveops_team_candidate(uuid,text,text)
  TO authenticated;

COMMENT ON FUNCTION public.review_liveops_team_candidate(uuid,text,text) IS
  'Human-accept or reject a provisional Match-ID + Team-ID candidate. Does not create official match_results or update standings.';
