
GRANT EXECUTE ON FUNCTION app_private.skip_liveops_match_evidence(uuid,text) TO authenticated;
REVOKE EXECUTE ON FUNCTION app_private.skip_liveops_match_evidence(uuid,text) FROM anon;

DO $patch$
DECLARE
  v_def text;
  v_old text;
BEGIN
  -- A skipped evidence step is a terminal state for this LiveOps session.
  -- Prevent the legacy result submit endpoint from bypassing the skip decision.
  v_def := pg_get_functiondef(
    'app_private.submit_liveops_match_results(uuid,uuid,text[],jsonb)'::regprocedure
  );
  v_old := $old$if not found then raise exception 'LiveOps session not found'; end if;$old$;
  IF position(v_old in v_def)=0 THEN
    RAISE EXCEPTION 'Could not locate the legacy result submit session guard';
  END IF;
  v_def := replace(v_def,v_old,$new$if not found then raise exception 'LiveOps session not found'; end if;
  if v_session.evidence_skipped_at is not null then
    raise exception 'This Match evidence step was skipped; result submission is blocked';
  end if;$new$);
  EXECUTE v_def;

  -- A skipped Match is labelled awaiting_result, never completed or scored.
  v_def := pg_get_functiondef(
    'app_private.skip_liveops_match_evidence(uuid,text)'::regprocedure
  );
  v_old := $old$  UPDATE public.liveops_sessions
  SET evidence_skipped_at=now(),evidence_skip_reason=v_reason
  WHERE id=v_session.id;$old$;
  IF position(v_old in v_def)=0 THEN
    RAISE EXCEPTION 'Could not locate the evidence skip write block';
  END IF;
  v_def := replace(v_def,v_old,$new$  UPDATE public.liveops_sessions
  SET evidence_skipped_at=now(),evidence_skip_reason=v_reason
  WHERE id=v_session.id;

  UPDATE public.matches
  SET status='awaiting_result'
  WHERE id=v_match.id AND status NOT IN ('completed','cancelled','review');$new$);
  EXECUTE v_def;

  -- When restarting or advancing, do not select a Match that has already
  -- been explicitly skipped in this Lobby.
  v_def := pg_get_functiondef(
    'app_private.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure
  );
  v_old := $old$AND NOT EXISTS (
      SELECT 1 FROM public.liveops_sessions active
      WHERE active.match_id=m.id AND active.state IN ('created','capturing','paused')
    )$old$;
  IF position(v_old in v_def)=0 THEN
    RAISE EXCEPTION 'Could not locate Next Match active-session filter';
  END IF;
  v_def := replace(v_def,v_old,$new$AND NOT EXISTS (
      SELECT 1 FROM public.liveops_sessions active
      WHERE active.match_id=m.id AND active.state IN ('created','capturing','paused')
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.liveops_sessions skipped
      WHERE skipped.lobby_id=v_previous.lobby_id
        AND skipped.match_id=m.id
        AND skipped.evidence_skipped_at IS NOT NULL
    )$new$);
  EXECUTE v_def;

  -- Do not mistake an empty exact-session result count for a clean skip if
  -- unrelated/legacy result rows exist for the same Match ID.
  v_def := pg_get_functiondef(
    'app_private.start_next_liveops_lobby_session(uuid,jsonb)'::regprocedure
  );
  v_old := $old$AND v_previous.evidence_skipped_at IS NOT NULL
      AND char_length(btrim(v_previous.evidence_skip_reason)) BETWEEN 10 AND 500$old$;
  IF position(v_old in v_def)=0 THEN
    RAISE EXCEPTION 'Could not locate Next Match skip acceptance guard';
  END IF;
  v_def := replace(v_def,v_old,$new$AND v_previous.evidence_skipped_at IS NOT NULL
      AND char_length(btrim(v_previous.evidence_skip_reason)) BETWEEN 10 AND 500
      AND NOT EXISTS (
        SELECT 1 FROM public.match_results any_result
        WHERE any_result.match_id=v_previous.match_id
      )$new$);
  EXECUTE v_def;
END;
$patch$;
