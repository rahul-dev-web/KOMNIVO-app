CREATE OR REPLACE FUNCTION public.publish_tournament_proposal(p_proposal_id uuid, p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_proposal public.tournament_proposals%ROWTYPE;
  v_event public.events%ROWTYPE;
  v_publication public.event_publications%ROWTYPE;
  v_resolution jsonb;
  v_event_id uuid;
  v_category_id uuid;
  v_category_name text;
  v_channel record;
  v_channel_id uuid;
  v_channels jsonb := '[]'::jsonb;
  v_position integer;
BEGIN
  IF (SELECT auth.role()) <> 'service_role' THEN
    RAISE EXCEPTION 'service role required' USING errcode = '42501';
  END IF;
  IF p_proposal_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION 'proposal and organiser are required' USING errcode = '22023';
  END IF;

  SELECT * INTO v_proposal
  FROM public.tournament_proposals
  WHERE id = p_proposal_id AND owner_user_id = p_user_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'tournament proposal not found' USING errcode = 'P0002';
  END IF;

  -- Publishing always re-checks the current community role, including retries
  -- on a proposal that was approved and kept as a draft earlier.
  IF NOT EXISTS (
    SELECT 1 FROM public.communities c
    WHERE c.id = v_proposal.community_id AND c.owner_user_id = p_user_id
  ) AND NOT EXISTS (
    SELECT 1 FROM public.community_members cm
    WHERE cm.community_id = v_proposal.community_id
      AND cm.user_id = p_user_id
      AND cm.role IN ('owner','admin','organiser')
  ) THEN
    RAISE EXCEPTION 'organizer permissions changed; tournament cannot be published' USING errcode = '42501';
  END IF;

  IF v_proposal.status = 'pending_approval' THEN
    v_resolution := public.resolve_tournament_proposal(p_proposal_id,p_user_id,'approve');
    v_event_id := NULLIF(v_resolution->>'event_id','')::uuid;
  ELSIF v_proposal.status = 'approved' AND v_proposal.event_id IS NOT NULL THEN
    v_event_id := v_proposal.event_id;
  ELSE
    RAISE EXCEPTION 'tournament proposal is not publishable in its current state' USING errcode = '55000';
  END IF;

  IF v_event_id IS NULL THEN
    RAISE EXCEPTION 'draft event could not be resolved for publication';
  END IF;

  SELECT * INTO v_event FROM public.events WHERE id = v_event_id FOR UPDATE;
  IF NOT FOUND OR v_event.community_id IS DISTINCT FROM v_proposal.community_id
     OR v_event.organizer_id IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'event and proposal ownership do not match' USING errcode = '42501';
  END IF;

  SELECT * INTO v_publication
  FROM public.event_publications
  WHERE event_id = v_event_id;
  IF FOUND THEN
    IF v_event.status <> 'published' THEN
      RAISE EXCEPTION 'publication record exists but event is not published; manual review is required';
    END IF;
    RETURN jsonb_build_object(
      'event_id',v_event_id,'proposal_id',p_proposal_id,'name',v_event.name,
      'status',v_event.status,'published',true,'already_published',true,
      'category_id',v_publication.category_id,'channels',v_publication.channels
    );
  END IF;

  IF v_event.status <> 'draft' THEN
    RAISE EXCEPTION 'only a DRAFT tournament can be published';
  END IF;

  v_category_name := left(v_event.name,60);
  IF EXISTS (
    SELECT 1 FROM public.channel_categories cc
    WHERE cc.community_id = v_event.community_id
      AND lower(cc.name) = lower(v_category_name)
  ) THEN
    v_category_name := left(v_event.name,50) || ' · ' || right(v_event.id::text,6);
  END IF;

  SELECT coalesce(max(position),0) + 1 INTO v_position
  FROM public.channel_categories
  WHERE community_id = v_event.community_id;

  INSERT INTO public.channel_categories(
    community_id,name,description,position,created_by,event_id
  ) VALUES (
    v_event.community_id,v_category_name,
    'Tournament channels for ' || v_event.name,
    v_position,p_user_id,v_event_id
  )
  RETURNING id INTO v_category_id;

  FOR v_channel IN
    SELECT * FROM (VALUES
      (1,'info','Official tournament information.','announcement',false,true),
      (2,'updates','Official tournament updates.','announcement',false,true),
      (3,'roadmap','Tournament stages and progression.','announcement',false,true),
      (4,'schedule','Published tournament and match schedules.','announcement',false,true),
      (5,'results','Official published match results and standings.','announcement',false,true),
      (6,'registration','Registration instructions and status.','announcement',false,true),
      (7,'test-registration','Registration-system test notices. Test entries must never count as real registrations.','text',false,true),
      (8,'registration-confirmation','Registration confirmation notices.','announcement',false,true),
      (9,'help-desk','Participant questions and support.','text',false,false),
      (10,'help-desk-voice','Voice support for tournament participants.','voice',false,false),
      (11,'staff','Private tournament staff coordination.','text',true,false)
    ) AS configured(position,channel_name,description,kind,is_private,read_only)
    ORDER BY position
  LOOP
    INSERT INTO public.channels(
      community_id,name,description,kind,is_private,created_by,category_id,event_id,
      stage_id,group_id,match_id,is_temporary
    ) VALUES (
      v_event.community_id,v_channel.channel_name,v_channel.description,v_channel.kind,
      v_channel.is_private,p_user_id,v_category_id,v_event_id,
      NULL,NULL,NULL,false
    )
    RETURNING id INTO v_channel_id;

    INSERT INTO public.channel_settings(
      channel_id,community_id,read_only,announcement_publishers_only,
      allow_everyone_mention,allow_role_mentions,allow_user_mentions,updated_by
    ) VALUES (
      v_channel_id,v_event.community_id,v_channel.read_only,
      v_channel.kind='announcement',false,false,true,p_user_id
    );

    v_channels := v_channels || jsonb_build_array(jsonb_build_object(
      'key',v_channel.channel_name,'channel_id',v_channel_id,
      'kind',v_channel.kind,'private',v_channel.is_private
    ));
  END LOOP;

  INSERT INTO public.event_publications(
    event_id,community_id,category_id,published_by,published_at,channels
  ) VALUES (
    v_event_id,v_event.community_id,v_category_id,p_user_id,now(),v_channels
  );

  -- Publication does not open registration. That remains a separate event transition.
  UPDATE public.events SET status='published' WHERE id=v_event_id;

  INSERT INTO public.audit_logs(
    actor_id,community_id,event_id,entity_type,entity_id,action,reason,metadata
  ) VALUES (
    p_user_id,v_event.community_id,v_event_id,'event',v_event_id,
    'tournament_published',
    'Organiser explicitly published the tournament from the AI chat workflow',
    jsonb_build_object('proposal_id',p_proposal_id,'category_id',v_category_id,
      'channel_count',jsonb_array_length(v_channels),'registration_opened',false)
  );

  RETURN jsonb_build_object(
    'event_id',v_event_id,'proposal_id',p_proposal_id,'name',v_event.name,
    'status','published','published',true,'already_published',false,
    'registration_opened',false,'category_id',v_category_id,'category_name',v_category_name,
    'channels',v_channels
  );
END;
$function$

