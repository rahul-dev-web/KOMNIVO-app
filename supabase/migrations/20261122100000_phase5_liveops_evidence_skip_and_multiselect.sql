
ALTER TABLE public.liveops_sessions
  ADD COLUMN IF NOT EXISTS evidence_skipped_at timestamptz,
  ADD COLUMN IF NOT EXISTS evidence_skip_reason text NOT NULL DEFAULT '';

DO $constraints$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.liveops_sessions'::regclass
      AND conname='liveops_sessions_evidence_skip_contract'
  ) THEN
    ALTER TABLE public.liveops_sessions
      ADD CONSTRAINT liveops_sessions_evidence_skip_contract
      CHECK (
        (evidence_skipped_at IS NULL AND evidence_skip_reason = '')
        OR (
          evidence_skipped_at IS NOT NULL
          AND char_length(btrim(evidence_skip_reason)) BETWEEN 10 AND 500
        )
      );
  END IF;
END;
$constraints$;

CREATE OR REPLACE FUNCTION app_private.skip_liveops_match_evidence(
  p_session_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_session public.liveops_sessions%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_event public.events%ROWTYPE;
  v_reason text := btrim(coalesce(p_reason,''));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_session_id IS NULL THEN
    RAISE EXCEPTION 'LiveOps session is required';
  END IF;
  IF char_length(v_reason) NOT BETWEEN 10 AND 500 THEN
    RAISE EXCEPTION 'Explain why this Match evidence step is skipped (10–500 characters)';
  END IF;

  SELECT * INTO v_session
  FROM public.liveops_sessions
  WHERE id=p_session_id AND operator_id=v_uid
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'LiveOps session not found for this operator';
  END IF;
  IF v_session.match_id IS NULL OR v_session.lobby_id IS NULL THEN
    RAISE EXCEPTION 'This session is not bound to an active Lobby and Match';
  END IF;
  IF v_session.state <> 'paused' THEN
    RAISE EXCEPTION 'Pause LiveOps before skipping the Match evidence step';
  END IF;
  IF NOT app_private.resolve_permission('liveops.session.manage','match',v_session.match_id,NULL,NULL) THEN
    RAISE EXCEPTION 'You are no longer authorised to manage this Match session' USING errcode='42501';
  END IF;

  IF v_session.evidence_skipped_at IS NOT NULL THEN
    IF v_session.evidence_skip_reason = v_reason THEN
      RETURN jsonb_build_object(
        'session_id',v_session.id,'match_id',v_session.match_id,
        'evidence_skipped',true,'already_skipped',true,
        'reason',v_session.evidence_skip_reason
      );
    END IF;
    RAISE EXCEPTION 'The evidence step was already skipped for this session; its reason is immutable';
  END IF;

  SELECT * INTO v_match FROM public.matches WHERE id=v_session.match_id FOR UPDATE;
  IF NOT FOUND OR v_match.event_id IS DISTINCT FROM v_session.event_id THEN
    RAISE EXCEPTION 'LiveOps session and Match ID do not match';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.event_lobby_matches lm
    WHERE lm.lobby_id=v_session.lobby_id AND lm.match_id=v_session.match_id
  ) THEN
    RAISE EXCEPTION 'This Match is not part of the selected Lobby';
  END IF;
  IF EXISTS (SELECT 1 FROM public.match_results WHERE match_id=v_session.match_id) THEN
    RAISE EXCEPTION 'Official result rows already exist; the evidence step cannot be skipped';
  END IF;

  SELECT * INTO v_event FROM public.events WHERE id=v_session.event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tournament no longer exists'; END IF;

  UPDATE public.liveops_sessions
  SET evidence_skipped_at=now(),evidence_skip_reason=v_reason
  WHERE id=v_session.id;

  INSERT INTO public.audit_logs(
    actor_id,community_id,event_id,entity_type,entity_id,action,reason,metadata
  ) VALUES (
    v_uid,v_event.community_id,v_event.id,'liveops_session',v_session.id,
    'liveops_evidence_step_skipped',v_reason,
    jsonb_build_object(
      'session_id',v_session.id,
      'lobby_id',v_session.lobby_id,
      'match_id',v_session.match_id,
      'match_code',v_match.match_code,
      'evidence_batch_count',(
        SELECT count(*) FROM public.liveops_evidence_batches
        WHERE session_id=v_session.id AND match_id=v_session.match_id
      ),
      'candidate_count',(
        SELECT count(*) FROM public.result_candidates
        WHERE match_id=v_session.match_id AND team_id IS NOT NULL
      ),
      'official_result_rows_created',false
    )
  );

  RETURN jsonb_build_object(
    'session_id',v_session.id,
    'lobby_id',v_session.lobby_id,
    'match_id',v_session.match_id,
    'evidence_skipped',true,
    'already_skipped',false,
    'reason',v_reason
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.skip_liveops_match_evidence(
  p_session_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE sql
SET search_path TO ''
AS $function$
  SELECT app_private.skip_liveops_match_evidence(p_session_id,p_reason);
$function$;

REVOKE ALL ON FUNCTION public.skip_liveops_match_evidence(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.skip_liveops_match_evidence(uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION app_private.skip_liveops_match_evidence(uuid,text) FROM PUBLIC, anon, authenticated;

DO $patch$
DECLARE
  v_def text;
  v_old text;
BEGIN
  -- Advancing is permitted after a complete official submission OR an explicit,
  -- reasoned skip. A skip never creates result rows or points.
  v_def := pg_get_functiondef(
    'app_private.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure
  );
  v_old := $old$IF v_participant_count < 2 OR v_result_count <> v_participant_count THEN
    RAISE EXCEPTION 'Submit every reviewer-accepted team result before advancing to the next Match';
  END IF;$old$;
  IF position(v_old in v_def)=0 THEN
    RAISE EXCEPTION 'Could not locate the current Next Match result gate';
  END IF;
  v_def := replace(v_def,v_old,$new$IF NOT (
    (v_participant_count >= 2 AND v_result_count = v_participant_count)
    OR (
      v_result_count = 0
      AND v_previous.evidence_skipped_at IS NOT NULL
      AND char_length(btrim(v_previous.evidence_skip_reason)) BETWEEN 10 AND 500
    )
  ) THEN
    RAISE EXCEPTION 'Submit every reviewer-accepted team result or explicitly skip the evidence step with a reason before advancing';
  END IF;$new$);
  EXECUTE v_def;

  -- A skipped Match remains skipped after an app restart; recovery selects the
  -- next eligible Match instead of reopening the skipped one.
  v_def := pg_get_functiondef(
    'app_private.start_liveops_lobby_session(uuid,jsonb)'::regprocedure
  );
  v_old := $old$AND NOT EXISTS (
      SELECT 1 FROM public.liveops_sessions active
      WHERE active.match_id=m.id AND active.state IN ('created','capturing','paused')
    )$old$;
  IF position(v_old in v_def)=0 THEN
    RAISE EXCEPTION 'Could not locate the Lobby recovery active-session filter';
  END IF;
  v_def := replace(v_def,v_old,$new$AND NOT EXISTS (
      SELECT 1 FROM public.liveops_sessions active
      WHERE active.match_id=m.id AND active.state IN ('created','capturing','paused')
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.liveops_sessions skipped
      WHERE skipped.lobby_id=v_lobby.id
        AND skipped.match_id=m.id
        AND skipped.evidence_skipped_at IS NOT NULL
    )$new$);
  EXECUTE v_def;

  -- An explicit skip closes this session's evidence/candidate write path.
  v_def := pg_get_functiondef(
    'app_private.register_liveops_evidence_batch(uuid,uuid,uuid,text,text,jsonb)'::regprocedure
  );
  v_old := $old$IF NOT FOUND THEN RAISE EXCEPTION 'LiveOps session not found'; END IF;$old$;
  IF position(v_old in v_def)=0 THEN
    RAISE EXCEPTION 'Could not locate the evidence upload session guard';
  END IF;
  v_def := replace(v_def,v_old,$new$IF NOT FOUND THEN RAISE EXCEPTION 'LiveOps session not found'; END IF;
  IF v_session.evidence_skipped_at IS NOT NULL THEN
    RAISE EXCEPTION 'This Match evidence step was skipped; start the next Match instead';
  END IF;$new$);
  EXECUTE v_def;

  v_def := pg_get_functiondef(
    'app_private.save_liveops_team_candidate(uuid,uuid,integer,integer,uuid[])'::regprocedure
  );
  v_old := $old$IF v_session.state <> 'paused' THEN
    RAISE EXCEPTION 'Pause LiveOps observation before transcribing Match results';
  END IF;$old$;
  IF position(v_old in v_def)=0 THEN
    RAISE EXCEPTION 'Could not locate the candidate write session guard';
  END IF;
  v_def := replace(v_def,v_old,$new$IF v_session.evidence_skipped_at IS NOT NULL THEN
    RAISE EXCEPTION 'This Match evidence step was skipped; candidate edits are locked';
  END IF;
  IF v_session.state <> 'paused' THEN
    RAISE EXCEPTION 'Pause LiveOps observation before transcribing Match results';
  END IF;$new$);
  EXECUTE v_def;

  v_def := pg_get_functiondef(
    'app_private.submit_reviewed_liveops_match_results(uuid,uuid)'::regprocedure
  );
  v_old := $old$IF v_session.state <> 'paused' THEN
    RAISE EXCEPTION 'Pause LiveOps observation before submitting reviewed results';
  END IF;$old$;
  IF position(v_old in v_def)=0 THEN
    RAISE EXCEPTION 'Could not locate the reviewed result submission session guard';
  END IF;
  v_def := replace(v_def,v_old,$new$IF v_session.evidence_skipped_at IS NOT NULL THEN
    RAISE EXCEPTION 'This Match evidence step was skipped; official result submission is blocked';
  END IF;
  IF v_session.state <> 'paused' THEN
    RAISE EXCEPTION 'Pause LiveOps observation before submitting reviewed results';
  END IF;$new$);
  EXECUTE v_def;
END;
$patch$;
