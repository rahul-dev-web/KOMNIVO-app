-- Use the explicit verified actor ID in service-role approval context.
CREATE OR REPLACE FUNCTION public.resolve_organizer_ai_proposal(
  p_proposal_id uuid, p_user_id uuid, p_decision text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_proposal public.ai_proposals%rowtype;
  v_conversation public.ai_conversations%rowtype;
  v_payload jsonb;
  v_event_id uuid;
  v_event_name text;
  v_description text;
  v_format text;
  v_capacity integer;
  v_starts_at timestamptz;
  v_registration_closes_at timestamptz;
  v_game_id uuid;
  v_community_id uuid;
  v_event_community uuid;
  v_event_organizer uuid;
  v_existing jsonb;
  v_result jsonb;
BEGIN
  IF (SELECT auth.role()) <> 'service_role' THEN
    RAISE EXCEPTION 'service role required' USING errcode = '42501';
  END IF;
  IF p_user_id IS NULL OR p_proposal_id IS NULL OR p_decision NOT IN ('approve','reject') THEN
    RAISE EXCEPTION 'invalid proposal resolution input' USING errcode = '22023';
  END IF;
  SELECT a.result INTO v_existing
  FROM public.ai_actions a
  WHERE a.idempotency_key = 'ai-proposal:' || p_proposal_id::text AND a.status = 'succeeded';
  IF FOUND THEN
    RETURN COALESCE(v_existing, '{}'::jsonb) || jsonb_build_object('already_executed', true);
  END IF;

  SELECT * INTO v_proposal FROM public.ai_proposals
  WHERE id = p_proposal_id AND owner_user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'proposal not found' USING errcode = 'P0002'; END IF;
  IF v_proposal.status <> 'pending_approval' THEN RAISE EXCEPTION 'proposal is not awaiting approval' USING errcode = '55000'; END IF;
  IF v_proposal.expires_at IS NOT NULL AND v_proposal.expires_at <= now() THEN
    UPDATE public.ai_proposals SET status = 'expired' WHERE id = p_proposal_id;
    RAISE EXCEPTION 'proposal expired' USING errcode = '55000';
  END IF;

  SELECT * INTO v_conversation FROM public.ai_conversations
  WHERE id = v_proposal.conversation_id AND owner_user_id = p_user_id;
  IF NOT FOUND OR v_conversation.mode <> 'organizer' THEN
    RAISE EXCEPTION 'organizer conversation required' USING errcode = '42501';
  END IF;

  IF v_conversation.community_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.community_members cm
      WHERE cm.community_id = v_conversation.community_id AND cm.user_id = p_user_id
        AND cm.role IN ('owner','admin','organiser')
    ) AND NOT EXISTS (
      SELECT 1 FROM public.communities c
      WHERE c.id = v_conversation.community_id AND c.owner_user_id = p_user_id
    ) THEN RAISE EXCEPTION 'organizer community permissions changed' USING errcode = '42501'; END IF;
  END IF;

  IF v_conversation.event_id IS NOT NULL THEN
    SELECT e.community_id,e.organizer_id INTO v_event_community,v_event_organizer
    FROM public.events e WHERE e.id = v_conversation.event_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'conversation event no longer exists' USING errcode = '42501'; END IF;
    IF v_conversation.community_id IS NOT NULL AND v_event_community IS DISTINCT FROM v_conversation.community_id THEN
      RAISE EXCEPTION 'event/community scope mismatch' USING errcode = '42501';
    END IF;
    IF v_event_organizer IS DISTINCT FROM p_user_id AND NOT (
      v_event_community IS NOT NULL AND (
        EXISTS (
          SELECT 1 FROM public.community_members cm
          WHERE cm.community_id = v_event_community AND cm.user_id = p_user_id
            AND cm.role IN ('owner','admin','organiser')
        )
        OR EXISTS (
          SELECT 1 FROM public.communities c
          WHERE c.id = v_event_community AND c.owner_user_id = p_user_id
        )
      )
    ) THEN RAISE EXCEPTION 'event organiser permission required' USING errcode = '42501'; END IF;
  END IF;

  IF p_decision = 'reject' THEN
    UPDATE public.ai_proposals SET status='rejected',approved_by=p_user_id,approved_at=now()
    WHERE id=p_proposal_id;
    RETURN jsonb_build_object('status','rejected','proposal_id',p_proposal_id);
  END IF;
  IF v_proposal.action_type <> 'create_event_draft' THEN
    RAISE EXCEPTION 'unsupported proposal action' USING errcode = '22023';
  END IF;

  v_payload := v_proposal.proposal;
  v_event_name := btrim(COALESCE(v_payload->>'name',''));
  v_description := left(COALESCE(v_payload->>'description',''),2000);
  v_format := COALESCE(v_payload->>'format','squad');
  BEGIN
    v_capacity := (v_payload->>'capacity')::integer;
    v_starts_at := (v_payload->>'starts_at')::timestamptz;
    v_registration_closes_at := NULLIF(v_payload->>'registration_closes_at','')::timestamptz;
    v_game_id := NULLIF(v_payload->>'game_id','')::uuid;
    v_community_id := NULLIF(v_payload->>'community_id','')::uuid;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'proposal contains invalid field types' USING errcode = '22023';
  END;

  IF char_length(v_event_name) < 3 OR char_length(v_event_name) > 100 THEN RAISE EXCEPTION 'event name must be 3 to 100 characters' USING errcode = '22023'; END IF;
  IF v_format NOT IN ('solo','duo','squad','custom') THEN RAISE EXCEPTION 'invalid tournament format' USING errcode = '22023'; END IF;
  IF v_capacity IS NULL OR v_capacity < 1 OR v_capacity > 1000 THEN RAISE EXCEPTION 'team capacity must be between 1 and 1000' USING errcode = '22023'; END IF;
  IF v_starts_at IS NULL OR v_starts_at <= now() THEN RAISE EXCEPTION 'event start time must be in the future' USING errcode = '22023'; END IF;
  IF v_registration_closes_at IS NOT NULL AND v_registration_closes_at >= v_starts_at THEN RAISE EXCEPTION 'registration close must be before event start' USING errcode = '22023'; END IF;
  IF v_game_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.games g WHERE g.id=v_game_id AND g.is_active) THEN
    RAISE EXCEPTION 'active game is required' USING errcode = '22023';
  END IF;

  IF v_conversation.community_id IS NOT NULL THEN
    IF v_community_id IS DISTINCT FROM v_conversation.community_id THEN
      RAISE EXCEPTION 'proposal community scope mismatch' USING errcode = '42501';
    END IF;
  ELSIF v_conversation.event_id IS NOT NULL THEN
    v_community_id := v_event_community;
  END IF;

  IF v_community_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.community_members cm
    WHERE cm.community_id=v_community_id AND cm.user_id=p_user_id AND cm.role IN ('owner','admin','organiser')
  ) AND NOT EXISTS (
    SELECT 1 FROM public.communities c WHERE c.id=v_community_id AND c.owner_user_id=p_user_id
  ) THEN RAISE EXCEPTION 'community organiser permission required' USING errcode = '42501'; END IF;

  INSERT INTO public.events (
    community_id,game_id,organizer_id,name,description,format,status,starts_at,
    registration_closes_at,capacity,rules_json,scoring_config
  ) VALUES (
    v_community_id,v_game_id,p_user_id,v_event_name,v_description,v_format,'draft',v_starts_at,
    v_registration_closes_at,v_capacity,COALESCE(v_payload->'rules_json','{}'::jsonb),
    COALESCE(v_payload->'scoring_config','{}'::jsonb)
  ) RETURNING id INTO v_event_id;

  v_result := jsonb_build_object(
    'event_id',v_event_id,'name',v_event_name,'status','draft','community_id',v_community_id,
    'proposal_id',p_proposal_id,'approved',true,'published',false
  );
  UPDATE public.ai_proposals SET status='executed',approved_by=p_user_id,approved_at=now(),executed_at=now()
  WHERE id=p_proposal_id;
  INSERT INTO public.ai_actions (
    run_id,conversation_id,owner_user_id,tool_name,arguments,result,status,requires_approval,idempotency_key,completed_at
  ) VALUES (
    v_proposal.run_id,v_proposal.conversation_id,p_user_id,'create_event_draft',
    jsonb_build_object('proposal_id',p_proposal_id),v_result,'succeeded',true,
    'ai-proposal:'||p_proposal_id::text,now()
  );
  INSERT INTO public.audit_logs (
    actor_id,community_id,entity_type,entity_id,action,reason,metadata
  ) VALUES (
    p_user_id,v_community_id,'event',v_event_id,'ai_event_draft_created',
    'Organizer explicitly approved AI event draft proposal',
    jsonb_build_object('proposal_id',p_proposal_id,'ai_run_id',v_proposal.run_id)
  );
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.resolve_organizer_ai_proposal(uuid,uuid,text) FROM public,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_organizer_ai_proposal(uuid,uuid,text) TO service_role;
