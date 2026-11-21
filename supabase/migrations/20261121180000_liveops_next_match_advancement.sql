-- Sequential, idempotent multi-Match LiveOps progression within one Lobby.

ALTER TABLE public.liveops_sessions
  ADD COLUMN IF NOT EXISTS previous_session_id uuid
    REFERENCES public.liveops_sessions(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS liveops_sessions_one_successor_per_session_uidx
  ON public.liveops_sessions(previous_session_id)
  WHERE previous_session_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS liveops_sessions_lobby_operator_state_idx
  ON public.liveops_sessions(lobby_id,operator_id,state,started_at DESC);

-- Extend the session guard so a successor must remain inside the exact Lobby,
-- event and operator scope, and must follow a fully submitted previous Match.
CREATE OR REPLACE FUNCTION app_private.guard_liveops_session_scope()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_match_event uuid;
  v_previous public.liveops_sessions%ROWTYPE;
  v_previous_sequence integer;
  v_new_sequence integer;
  v_previous_participants integer;
  v_previous_results integer;
BEGIN
  IF TG_OP='INSERT' THEN
    IF NEW.match_id IS NULL THEN
      RAISE EXCEPTION 'LiveOps sessions must be bound to a platform match ID';
    END IF;
    SELECT m.event_id INTO v_match_event
    FROM public.matches m WHERE m.id=NEW.match_id;
    IF NOT FOUND OR v_match_event IS DISTINCT FROM NEW.event_id THEN
      RAISE EXCEPTION 'LiveOps session event and match scope do not match';
    END IF;
    IF NEW.lobby_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.event_lobby_matches lm
      WHERE lm.lobby_id=NEW.lobby_id AND lm.match_id=NEW.match_id
    ) THEN
      RAISE EXCEPTION 'LiveOps session match does not belong to its Lobby ID';
    END IF;

    IF NEW.previous_session_id IS NOT NULL THEN
      SELECT * INTO v_previous
      FROM public.liveops_sessions s
      WHERE s.id=NEW.previous_session_id
      FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Previous LiveOps session not found';
      END IF;
      IF v_previous.operator_id IS DISTINCT FROM NEW.operator_id
         OR v_previous.event_id IS DISTINCT FROM NEW.event_id
         OR v_previous.lobby_id IS DISTINCT FROM NEW.lobby_id
         OR v_previous.state <> 'paused' THEN
        RAISE EXCEPTION 'Next Match session must follow the same operator Lobby session while it is paused';
      END IF;

      SELECT lm.sequence_no INTO v_previous_sequence
      FROM public.event_lobby_matches lm
      WHERE lm.lobby_id=v_previous.lobby_id AND lm.match_id=v_previous.match_id;
      SELECT lm.sequence_no INTO v_new_sequence
      FROM public.event_lobby_matches lm
      WHERE lm.lobby_id=NEW.lobby_id AND lm.match_id=NEW.match_id;
      IF v_previous_sequence IS NULL OR v_new_sequence IS NULL
         OR v_new_sequence <= v_previous_sequence THEN
        RAISE EXCEPTION 'A successor session must point to a later Match in the same Lobby order';
      END IF;

      SELECT count(*) INTO v_previous_participants
      FROM public.match_participants mp WHERE mp.match_id=v_previous.match_id;
      SELECT count(*) INTO v_previous_results
      FROM public.match_results mr
      WHERE mr.match_id=v_previous.match_id
        AND mr.result_json->>'source'='liveops_reviewed_candidates'
        AND mr.result_json->>'liveops_session_id'=v_previous.id::text
        AND mr.status IN ('submitted','under_review','disputed','approved');
      IF v_previous_participants < 2
         OR v_previous_results <> v_previous_participants THEN
        RAISE EXCEPTION 'The previous Match must have a complete reviewed-result submission before advancing';
      END IF;
    END IF;

    IF auth.uid() IS NOT NULL THEN
      IF NEW.operator_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'LiveOps operator must be the authenticated user';
      END IF;
      IF NOT app_private.resolve_permission('liveops.session.manage','match',NEW.match_id,NULL,NULL) THEN
        RAISE EXCEPTION 'You are not authorised to operate this match';
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.operator_id IS DISTINCT FROM OLD.operator_id
     OR NEW.match_id IS DISTINCT FROM OLD.match_id
     OR NEW.lobby_id IS DISTINCT FROM OLD.lobby_id
     OR NEW.event_id IS DISTINCT FROM OLD.event_id
     OR NEW.started_at IS DISTINCT FROM OLD.started_at
     OR NEW.previous_session_id IS DISTINCT FROM OLD.previous_session_id THEN
    RAISE EXCEPTION 'LiveOps session identity, predecessor, Lobby ID and Match binding are immutable';
  END IF;
  IF auth.uid() IS NOT NULL AND OLD.operator_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Only the LiveOps session operator may update it';
  END IF;
  IF NEW.state IS DISTINCT FROM OLD.state AND NOT (
    (OLD.state='created' AND NEW.state IN ('capturing','failed'))
    OR (OLD.state='capturing' AND NEW.state IN ('paused','stopped','failed'))
    OR (OLD.state='paused' AND NEW.state IN ('capturing','stopped','failed'))
  ) THEN
    RAISE EXCEPTION 'Invalid LiveOps session state transition';
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.guard_liveops_session_scope()
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.guard_liveops_session_scope()
  TO service_role;

-- Reuse an active session for its actual Match ID and sequence. When there is
-- no active session, recover to the first ordered Match without existing results.
CREATE OR REPLACE FUNCTION app_private.start_liveops_lobby_session(
  p_lobby_id uuid,
  p_device_info jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_lobby public.event_lobbies%ROWTYPE;
  v_event public.events%ROWTYPE;
  v_match_id uuid;
  v_sequence integer;
  v_session public.liveops_sessions%ROWTYPE;
  v_match_code text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_lobby_id IS NULL THEN RAISE EXCEPTION 'Select a platform Lobby ID before starting LiveOps'; END IF;

  SELECT * INTO v_lobby
  FROM public.event_lobbies
  WHERE id=p_lobby_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Lobby not found'; END IF;
  SELECT * INTO v_event FROM public.events WHERE id=v_lobby.event_id;
  IF NOT FOUND OR v_lobby.status IN ('completed','cancelled') THEN
    RAISE EXCEPTION 'This lobby is no longer available';
  END IF;
  IF NOT app_private.resolve_permission('event.matches.operate','event',v_lobby.event_id,NULL,NULL) THEN
    RAISE EXCEPTION 'You are not authorised to start LiveOps for this lobby' USING errcode='42501';
  END IF;

  SELECT * INTO v_session
  FROM public.liveops_sessions s
  WHERE s.lobby_id=v_lobby.id
    AND s.operator_id=auth.uid()
    AND s.state IN ('created','capturing','paused')
  ORDER BY s.started_at DESC
  LIMIT 1;
  IF FOUND THEN
    SELECT lm.sequence_no,m.match_code
      INTO v_sequence,v_match_code
    FROM public.event_lobby_matches lm
    JOIN public.matches m ON m.id=lm.match_id
    WHERE lm.lobby_id=v_lobby.id AND lm.match_id=v_session.match_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'The active LiveOps Match is no longer part of this Lobby';
    END IF;
    RETURN jsonb_build_object(
      'session_id',v_session.id,'lobby_id',v_lobby.id,'lobby_code',v_lobby.lobby_code,
      'event_id',v_lobby.event_id,'match_id',v_session.match_id,
      'match_code',v_match_code,'match_sequence',v_sequence,'state',v_session.state,
      'previous_session_id',v_session.previous_session_id,'already_active',true
    );
  END IF;

  SELECT lm.match_id,lm.sequence_no,m.match_code
    INTO v_match_id,v_sequence,v_match_code
  FROM public.event_lobby_matches lm
  JOIN public.matches m ON m.id=lm.match_id
  WHERE lm.lobby_id=v_lobby.id
    AND m.status NOT IN ('completed','cancelled','review')
    AND NOT EXISTS (
      SELECT 1 FROM public.match_results mr WHERE mr.match_id=m.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.liveops_sessions active
      WHERE active.match_id=m.id AND active.state IN ('created','capturing','paused')
    )
  ORDER BY lm.sequence_no
  LIMIT 1
  FOR UPDATE OF m;
  IF v_match_id IS NULL THEN
    RAISE EXCEPTION 'No unsubmitted Match remains in this Lobby';
  END IF;

  INSERT INTO public.liveops_sessions(
    operator_id,match_id,lobby_id,event_id,state,started_at,device_info
  ) VALUES (
    auth.uid(),v_match_id,v_lobby.id,v_lobby.event_id,'created',now(),
    coalesce(p_device_info,'{}'::jsonb)
  ) RETURNING * INTO v_session;

  UPDATE public.event_lobbies
  SET status='live',started_at=coalesce(started_at,now())
  WHERE id=v_lobby.id;

  INSERT INTO public.audit_logs(actor_id,community_id,event_id,entity_type,entity_id,action,metadata)
  VALUES (
    auth.uid(),v_event.community_id,v_event.id,'liveops_session',v_session.id,
    'liveops_lobby_session_started',
    jsonb_build_object(
      'lobby_id',v_lobby.id,'lobby_code',v_lobby.lobby_code,
      'match_id',v_match_id,'match_code',v_match_code,'match_sequence',v_sequence,
      'recovered_next_unsubmitted_match',true
    )
  );

  RETURN jsonb_build_object(
    'session_id',v_session.id,'lobby_id',v_lobby.id,'lobby_code',v_lobby.lobby_code,
    'event_id',v_lobby.event_id,'match_id',v_match_id,'match_code',v_match_code,
    'match_sequence',v_sequence,'state',v_session.state,
    'previous_session_id',null,'already_active',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION app_private.start_liveops_lobby_session(uuid,jsonb)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.start_liveops_lobby_session(uuid,jsonb)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.start_liveops_lobby_session(
  p_lobby_id uuid,
  p_device_info jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $function$
  SELECT app_private.start_liveops_lobby_session(p_lobby_id,p_device_info);
$function$;

REVOKE ALL ON FUNCTION public.start_liveops_lobby_session(uuid,jsonb)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.start_liveops_lobby_session(uuid,jsonb)
  TO authenticated;

CREATE OR REPLACE FUNCTION app_private.start_next_liveops_lobby_session(
  p_previous_session_id uuid,
  p_device_info jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_previous public.liveops_sessions%ROWTYPE;
  v_existing_next public.liveops_sessions%ROWTYPE;
  v_lobby public.event_lobbies%ROWTYPE;
  v_event public.events%ROWTYPE;
  v_previous_sequence integer;
  v_next_match_id uuid;
  v_next_sequence integer;
  v_next_match_code text;
  v_session public.liveops_sessions%ROWTYPE;
  v_participant_count integer;
  v_result_count integer;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_previous_session_id IS NULL THEN RAISE EXCEPTION 'Previous LiveOps session is required'; END IF;

  SELECT * INTO v_previous
  FROM public.liveops_sessions s
  WHERE s.id=p_previous_session_id AND s.operator_id=v_uid
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Previous LiveOps session not found for this operator'; END IF;

  -- A lost response must not create a second successor session.
  SELECT * INTO v_existing_next
  FROM public.liveops_sessions s
  WHERE s.previous_session_id=v_previous.id;
  IF FOUND THEN
    SELECT lm.sequence_no,m.match_code
      INTO v_next_sequence,v_next_match_code
    FROM public.event_lobby_matches lm
    JOIN public.matches m ON m.id=lm.match_id
    WHERE lm.lobby_id=v_existing_next.lobby_id
      AND lm.match_id=v_existing_next.match_id;
    RETURN jsonb_build_object(
      'session_id',v_existing_next.id,
      'previous_session_id',v_previous.id,
      'lobby_id',v_existing_next.lobby_id,
      'lobby_code',(SELECT l.lobby_code FROM public.event_lobbies l WHERE l.id=v_existing_next.lobby_id),
      'event_id',v_existing_next.event_id,
      'match_id',v_existing_next.match_id,
      'match_code',v_next_match_code,
      'match_sequence',v_next_sequence,
      'state',v_existing_next.state,
      'already_advanced',true
    );
  END IF;

  IF v_previous.state <> 'paused' THEN
    RAISE EXCEPTION 'Pause and submit the current Match before advancing to the next one';
  END IF;
  IF NOT app_private.resolve_permission('liveops.session.manage','match',v_previous.match_id,NULL,NULL) THEN
    RAISE EXCEPTION 'You are no longer authorised to operate the current Match' USING errcode='42501';
  END IF;

  SELECT * INTO v_lobby
  FROM public.event_lobbies l
  WHERE l.id=v_previous.lobby_id
  FOR UPDATE;
  IF NOT FOUND OR v_lobby.event_id IS DISTINCT FROM v_previous.event_id
     OR v_lobby.status IN ('completed','cancelled') THEN
    RAISE EXCEPTION 'Previous LiveOps Lobby is no longer available';
  END IF;
  SELECT * INTO v_event FROM public.events e WHERE e.id=v_previous.event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tournament no longer exists'; END IF;

  SELECT lm.sequence_no INTO v_previous_sequence
  FROM public.event_lobby_matches lm
  WHERE lm.lobby_id=v_previous.lobby_id AND lm.match_id=v_previous.match_id;
  IF v_previous_sequence IS NULL THEN
    RAISE EXCEPTION 'Previous Match is no longer part of this Lobby';
  END IF;

  SELECT count(*) INTO v_participant_count
  FROM public.match_participants mp
  WHERE mp.match_id=v_previous.match_id;
  SELECT count(*) INTO v_result_count
  FROM public.match_results mr
  WHERE mr.match_id=v_previous.match_id
    AND mr.result_json->>'source'='liveops_reviewed_candidates'
    AND mr.result_json->>'liveops_session_id'=v_previous.id::text
    AND mr.status IN ('submitted','under_review','disputed','approved');
  IF v_participant_count < 2 OR v_result_count <> v_participant_count THEN
    RAISE EXCEPTION 'Submit every reviewer-accepted team result before advancing to the next Match';
  END IF;

  SELECT lm.match_id,lm.sequence_no,m.match_code
    INTO v_next_match_id,v_next_sequence,v_next_match_code
  FROM public.event_lobby_matches lm
  JOIN public.matches m ON m.id=lm.match_id
  WHERE lm.lobby_id=v_previous.lobby_id
    AND lm.sequence_no > v_previous_sequence
    AND m.status NOT IN ('completed','cancelled','review')
    AND NOT EXISTS (
      SELECT 1 FROM public.match_results mr WHERE mr.match_id=m.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.liveops_sessions active
      WHERE active.match_id=m.id AND active.state IN ('created','capturing','paused')
    )
  ORDER BY lm.sequence_no
  LIMIT 1
  FOR UPDATE OF m;
  IF v_next_match_id IS NULL THEN
    RAISE EXCEPTION 'No remaining unsubmitted Match is scheduled in this Lobby';
  END IF;
  IF NOT app_private.resolve_permission('liveops.session.manage','match',v_next_match_id,NULL,NULL) THEN
    RAISE EXCEPTION 'You are not authorised to operate the next Match in this Lobby' USING errcode='42501';
  END IF;

  INSERT INTO public.liveops_sessions(
    operator_id,match_id,lobby_id,event_id,state,started_at,device_info,previous_session_id
  ) VALUES (
    v_uid,v_next_match_id,v_previous.lobby_id,v_previous.event_id,
    'created',now(),coalesce(p_device_info,'{}'::jsonb),v_previous.id
  ) RETURNING * INTO v_session;

  UPDATE public.liveops_sessions
  SET state='stopped',ended_at=now()
  WHERE id=v_previous.id;

  UPDATE public.event_lobbies
  SET status='live'
  WHERE id=v_previous.lobby_id;

  INSERT INTO public.audit_logs(actor_id,community_id,event_id,entity_type,entity_id,action,metadata)
  VALUES (
    v_uid,v_event.community_id,v_event.id,'liveops_session',v_session.id,
    'liveops_lobby_advanced_to_next_match',
    jsonb_build_object(
      'previous_session_id',v_previous.id,
      'previous_match_id',v_previous.match_id,
      'previous_match_sequence',v_previous_sequence,
      'next_session_id',v_session.id,
      'next_match_id',v_next_match_id,
      'next_match_code',v_next_match_code,
      'next_match_sequence',v_next_sequence
    )
  );

  RETURN jsonb_build_object(
    'session_id',v_session.id,'previous_session_id',v_previous.id,
    'lobby_id',v_previous.lobby_id,'lobby_code',v_lobby.lobby_code,
    'event_id',v_previous.event_id,'match_id',v_next_match_id,
    'match_code',v_next_match_code,'match_sequence',v_next_sequence,
    'state','created','already_advanced',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION app_private.start_next_liveops_lobby_session(uuid,jsonb)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION app_private.start_next_liveops_lobby_session(uuid,jsonb)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.start_next_liveops_lobby_session(
  p_previous_session_id uuid,
  p_device_info jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $function$
  SELECT app_private.start_next_liveops_lobby_session(
    p_previous_session_id,p_device_info
  );
$function$;

REVOKE ALL ON FUNCTION public.start_next_liveops_lobby_session(uuid,jsonb)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.start_next_liveops_lobby_session(uuid,jsonb)
  TO authenticated;

COMMENT ON COLUMN public.liveops_sessions.previous_session_id IS
  'The previous paused LiveOps session in the same Lobby. One successor per prior session makes Next Match retry-safe.';
