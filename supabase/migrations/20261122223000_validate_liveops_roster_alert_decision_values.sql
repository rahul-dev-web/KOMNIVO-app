-- Reject NULL as well as unsupported values in explicit roster-alert host decisions.
CREATE OR REPLACE FUNCTION public.record_liveops_roster_alert_decision(
  p_session_id uuid,
  p_alert_type text,
  p_decision text
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
  v_action text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_session_id IS NULL
     OR coalesce(p_alert_type,'') NOT IN ('slot','duplicate','ambiguous','unknown','not-seen','coverage','empty-slot')
     OR coalesce(p_decision,'') NOT IN ('adjusted_in_game','kept_as_is') THEN
    RAISE EXCEPTION 'A valid LiveOps session, alert type and host decision are required';
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

  IF NOT app_private.resolve_permission(
    'event.matches.operate','event',v_event.id,NULL,NULL
  ) THEN
    RAISE EXCEPTION 'You are not authorised to review this Match lobby'
      USING errcode='42501';
  END IF;

  v_action := CASE p_decision
    WHEN 'adjusted_in_game' THEN 'liveops_roster_alert_adjusted_in_game'
    ELSE 'liveops_roster_alert_kept_as_is'
  END;

  INSERT INTO public.audit_logs(
    actor_id,community_id,event_id,entity_type,entity_id,action,reason,metadata
  ) VALUES (
    v_uid,v_event.community_id,v_event.id,
    'liveops_roster_alert',v_session.id,v_action,
    'Host decision for a provisional OCR Lobby alert',
    jsonb_build_object(
      'session_id',v_session.id,
      'lobby_id',v_session.lobby_id,
      'match_id',v_match.id,
      'alert_type',p_alert_type,
      'decision',p_decision,
      'roster_changed',false,
      'game_action_performed_by_komnivo',false
    )
  );

  RETURN jsonb_build_object(
    'recorded',true,
    'session_id',v_session.id,
    'match_id',v_match.id,
    'alert_type',p_alert_type,
    'decision',p_decision,
    'roster_changed',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.record_liveops_roster_alert_decision(uuid,text,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_liveops_roster_alert_decision(uuid,text,text)
  TO authenticated;
