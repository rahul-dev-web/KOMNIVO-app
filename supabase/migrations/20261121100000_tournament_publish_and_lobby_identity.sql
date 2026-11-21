-- Tournament publication orchestration and distinct Lobby/Match identity.
-- This migration deliberately keeps event publication separate from registration opening.

CREATE TABLE IF NOT EXISTS public.event_publications (
  event_id uuid PRIMARY KEY REFERENCES public.events(id) ON DELETE CASCADE,
  community_id uuid NOT NULL REFERENCES public.communities(id) ON DELETE CASCADE,
  category_id uuid NOT NULL REFERENCES public.channel_categories(id) ON DELETE RESTRICT,
  published_by uuid NOT NULL REFERENCES public.profiles(id),
  published_at timestamptz NOT NULL DEFAULT now(),
  channels jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(channels) = 'array')
);

ALTER TABLE public.event_publications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.event_publications FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.event_publications TO authenticated;
GRANT ALL ON public.event_publications TO service_role;
DROP POLICY IF EXISTS event_publications_read_scope ON public.event_publications;
CREATE POLICY event_publications_read_scope
  ON public.event_publications FOR SELECT TO authenticated
  USING (
    app_private.resolve_permission('event.view','event',event_id,NULL,NULL)
    OR app_private.resolve_permission('event.manage','event',event_id,NULL,NULL)
  );

-- A root event category is visible to event viewers. Stage/group categories keep
-- their narrower scopes; this avoids treating a category UUID as a channel UUID.
DROP POLICY IF EXISTS channel_categories_read_member ON public.channel_categories;
CREATE POLICY channel_categories_read_member
  ON public.channel_categories FOR SELECT TO authenticated
  USING (
    (event_id IS NULL AND app_private.is_community_member(community_id))
    OR (
      event_id IS NOT NULL
      AND CASE
        WHEN stage_id IS NOT NULL THEN
          app_private.resolve_permission('stage.view','stage',stage_id,NULL,NULL)
        WHEN group_id IS NOT NULL THEN
          app_private.resolve_permission('group.view','group',group_id,NULL,NULL)
        ELSE
          app_private.resolve_permission('event.view','event',event_id,NULL,NULL)
      END
    )
  );

CREATE OR REPLACE FUNCTION public.publish_tournament_proposal(
  p_proposal_id uuid,
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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
      (5,'registration','Registration instructions and status.','announcement',false,true),
      (6,'registration-confirmation','Registration confirmation notices.','announcement',false,true),
      (7,'test-registration','Registration-system test notices. Test entries must never count as real registrations.','text',false,true),
      (8,'help-desk','Participant questions and support.','text',false,false),
      (9,'help-desk-voice','Voice support for tournament participants.','voice',false,false),
      (10,'results','Official published match results and standings.','announcement',false,true),
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
$function$;

REVOKE ALL ON FUNCTION public.publish_tournament_proposal(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.publish_tournament_proposal(uuid,uuid) TO service_role;

CREATE TABLE IF NOT EXISTS public.event_lobbies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  lobby_number integer NOT NULL CHECK (lobby_number > 0),
  lobby_code text NOT NULL,
  status text NOT NULL DEFAULT 'scheduled'
    CHECK (status IN ('scheduled','live','completed','cancelled')),
  idempotency_key text NOT NULL CHECK (char_length(idempotency_key) BETWEEN 8 AND 120),
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  completed_at timestamptz,
  UNIQUE(event_id,lobby_number),
  UNIQUE(event_id,idempotency_key),
  UNIQUE(event_id,lobby_code)
);

CREATE TABLE IF NOT EXISTS public.event_lobby_matches (
  lobby_id uuid NOT NULL REFERENCES public.event_lobbies(id) ON DELETE CASCADE,
  match_id uuid NOT NULL UNIQUE REFERENCES public.matches(id) ON DELETE CASCADE,
  sequence_no integer NOT NULL CHECK (sequence_no > 0),
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(lobby_id,match_id),
  UNIQUE(lobby_id,sequence_no)
);

CREATE INDEX IF NOT EXISTS event_lobbies_event_status_idx
  ON public.event_lobbies(event_id,status,lobby_number);
CREATE INDEX IF NOT EXISTS event_lobby_matches_sequence_idx
  ON public.event_lobby_matches(lobby_id,sequence_no);

ALTER TABLE public.event_lobbies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_lobby_matches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.event_lobbies,public.event_lobby_matches FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.event_lobbies,public.event_lobby_matches TO authenticated;
GRANT ALL ON public.event_lobbies,public.event_lobby_matches TO service_role;

DROP POLICY IF EXISTS event_lobbies_read_scope ON public.event_lobbies;
CREATE POLICY event_lobbies_read_scope
  ON public.event_lobbies FOR SELECT TO authenticated
  USING (
    app_private.resolve_permission('event.view','event',event_id,NULL,NULL)
    OR app_private.resolve_permission('event.matches.operate','event',event_id,NULL,NULL)
  );

DROP POLICY IF EXISTS event_lobby_matches_read_scope ON public.event_lobby_matches;
CREATE POLICY event_lobby_matches_read_scope
  ON public.event_lobby_matches FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.event_lobbies l
      WHERE l.id = lobby_id
        AND (
          app_private.resolve_permission('event.view','event',l.event_id,NULL,NULL)
          OR app_private.resolve_permission('event.matches.operate','event',l.event_id,NULL,NULL)
        )
    )
  );

CREATE OR REPLACE FUNCTION app_private.create_event_lobby(
  p_event_id uuid,
  p_match_ids uuid[],
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event public.events%ROWTYPE;
  v_lobby public.event_lobbies%ROWTYPE;
  v_match_count integer;
  v_number integer;
  v_match_ids uuid[];
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_event_id IS NULL OR p_match_ids IS NULL
     OR cardinality(p_match_ids) < 1 OR cardinality(p_match_ids) > 24 THEN
    RAISE EXCEPTION 'Choose between one and 24 matches for this lobby';
  END IF;
  IF p_idempotency_key IS NULL OR char_length(p_idempotency_key) < 8
     OR char_length(p_idempotency_key) > 120 THEN
    RAISE EXCEPTION 'A valid lobby request id is required';
  END IF;
  IF (SELECT count(DISTINCT x) FROM unnest(p_match_ids) AS x) <> cardinality(p_match_ids) THEN
    RAISE EXCEPTION 'A match can appear only once in a lobby';
  END IF;
  IF NOT app_private.resolve_permission('event.matches.operate','event',p_event_id,NULL,NULL) THEN
    RAISE EXCEPTION 'You are not authorised to configure lobbies for this tournament' USING errcode = '42501';
  END IF;

  SELECT * INTO v_event FROM public.events WHERE id=p_event_id FOR UPDATE;
  IF NOT FOUND OR v_event.status NOT IN ('published','registration_open','registration_closed','live') THEN
    RAISE EXCEPTION 'Only a published tournament can have lobbies configured';
  END IF;

  SELECT * INTO v_lobby
  FROM public.event_lobbies
  WHERE event_id=p_event_id AND idempotency_key=p_idempotency_key;
  IF FOUND THEN
    SELECT array_agg(m.match_id ORDER BY m.sequence_no) INTO v_match_ids
    FROM public.event_lobby_matches m WHERE m.lobby_id=v_lobby.id;
    RETURN jsonb_build_object(
      'lobby_id',v_lobby.id,'lobby_code',v_lobby.lobby_code,'event_id',p_event_id,
      'status',v_lobby.status,'match_ids',to_jsonb(coalesce(v_match_ids,ARRAY[]::uuid[])),
      'already_created',true
    );
  END IF;

  SELECT count(*) INTO v_match_count
  FROM public.matches m
  WHERE m.event_id=p_event_id AND m.id=ANY(p_match_ids) AND m.status='scheduled';
  IF v_match_count <> cardinality(p_match_ids) THEN
    RAISE EXCEPTION 'Every selected match must belong to this event and still be scheduled';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.event_lobby_matches lm
    WHERE lm.match_id=ANY(p_match_ids)
  ) THEN
    RAISE EXCEPTION 'One or more matches already belong to another lobby';
  END IF;

  SELECT coalesce(max(lobby_number),0)+1 INTO v_number
  FROM public.event_lobbies WHERE event_id=p_event_id;
  INSERT INTO public.event_lobbies(
    event_id,lobby_number,lobby_code,status,idempotency_key,created_by
  ) VALUES (
    p_event_id,v_number,'L-'||lpad(v_number::text,3,'0'),'scheduled',
    p_idempotency_key,auth.uid()
  ) RETURNING * INTO v_lobby;

  INSERT INTO public.event_lobby_matches(lobby_id,match_id,sequence_no,created_by)
  SELECT v_lobby.id,selected.match_id,selected.ordinality::integer,auth.uid()
  FROM unnest(p_match_ids) WITH ORDINALITY AS selected(match_id,ordinality);

  INSERT INTO public.audit_logs(actor_id,community_id,event_id,entity_type,entity_id,action,metadata)
  VALUES (
    auth.uid(),v_event.community_id,p_event_id,'event_lobby',v_lobby.id,
    'event_lobby_created',
    jsonb_build_object('lobby_code',v_lobby.lobby_code,'match_ids',p_match_ids)
  );

  RETURN jsonb_build_object(
    'lobby_id',v_lobby.id,'lobby_code',v_lobby.lobby_code,'event_id',p_event_id,
    'status',v_lobby.status,'match_ids',to_jsonb(p_match_ids),'already_created',false
  );
END;
$function$;

REVOKE ALL ON FUNCTION app_private.create_event_lobby(uuid,uuid[],text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.create_event_lobby(uuid,uuid[],text) TO authenticated;

CREATE OR REPLACE FUNCTION public.create_event_lobby(
  p_event_id uuid,
  p_match_ids uuid[],
  p_idempotency_key text
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $function$
  SELECT app_private.create_event_lobby(p_event_id,p_match_ids,p_idempotency_key);
$function$;
REVOKE ALL ON FUNCTION public.create_event_lobby(uuid,uuid[],text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_event_lobby(uuid,uuid[],text) TO authenticated;

ALTER TABLE public.liveops_sessions
  ADD COLUMN IF NOT EXISTS lobby_id uuid REFERENCES public.event_lobbies(id) ON DELETE CASCADE;

DROP POLICY IF EXISTS liveops_sessions_insert_self ON public.liveops_sessions;
CREATE POLICY liveops_sessions_insert_self
  ON public.liveops_sessions FOR INSERT TO authenticated
  WITH CHECK (
    operator_id=(SELECT auth.uid())
    AND (
      (
        lobby_id IS NULL AND match_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM public.matches m
          WHERE m.id=liveops_sessions.match_id
            AND m.event_id=liveops_sessions.event_id
            AND app_private.resolve_permission('liveops.session.manage','match',m.id,NULL,NULL)
        )
      )
      OR
      (
        lobby_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM public.event_lobbies l
          WHERE l.id=liveops_sessions.lobby_id
            AND l.event_id=liveops_sessions.event_id
            AND app_private.resolve_permission('event.matches.operate','event',l.event_id,NULL,NULL)
        )
      )
    )
  );

DROP POLICY IF EXISTS liveops_sessions_read_owner_or_staff ON public.liveops_sessions;
CREATE POLICY liveops_sessions_read_owner_or_staff
  ON public.liveops_sessions FOR SELECT TO authenticated
  USING (
    operator_id=(SELECT auth.uid())
    OR (match_id IS NOT NULL AND app_private.resolve_permission('liveops.capture.read','match',match_id,NULL,NULL))
    OR (lobby_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.event_lobbies l
      WHERE l.id=liveops_sessions.lobby_id
        AND app_private.resolve_permission('event.matches.operate','event',l.event_id,NULL,NULL)
    ))
  );

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
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_lobby_id IS NULL THEN RAISE EXCEPTION 'Select a platform Lobby ID before starting LiveOps'; END IF;

  SELECT * INTO v_lobby FROM public.event_lobbies WHERE id=p_lobby_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Lobby not found'; END IF;
  SELECT * INTO v_event FROM public.events WHERE id=v_lobby.event_id;
  IF NOT FOUND OR v_lobby.status IN ('completed','cancelled') THEN
    RAISE EXCEPTION 'This lobby is no longer available';
  END IF;
  IF NOT app_private.resolve_permission('event.matches.operate','event',v_lobby.event_id,NULL,NULL) THEN
    RAISE EXCEPTION 'You are not authorised to start LiveOps for this lobby' USING errcode = '42501';
  END IF;

  SELECT lm.match_id,lm.sequence_no INTO v_match_id,v_sequence
  FROM public.event_lobby_matches lm
  WHERE lm.lobby_id=v_lobby.id
  ORDER BY lm.sequence_no LIMIT 1;
  IF v_match_id IS NULL THEN RAISE EXCEPTION 'This lobby has no scheduled matches'; END IF;

  SELECT * INTO v_session FROM public.liveops_sessions s
  WHERE s.lobby_id=v_lobby.id
    AND s.operator_id=auth.uid()
    AND s.state IN ('created','capturing','paused')
  ORDER BY s.started_at DESC LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'session_id',v_session.id,'lobby_id',v_lobby.id,'lobby_code',v_lobby.lobby_code,
      'event_id',v_lobby.event_id,'match_id',v_session.match_id,
      'match_sequence',v_sequence,'state',v_session.state,'already_active',true
    );
  END IF;

  INSERT INTO public.liveops_sessions(
    operator_id,match_id,lobby_id,event_id,state,started_at,device_info
  ) VALUES (
    auth.uid(),v_match_id,v_lobby.id,v_lobby.event_id,'created',now(),
    coalesce(p_device_info,'{}'::jsonb)
  ) RETURNING * INTO v_session;

  UPDATE public.event_lobbies SET status='live',started_at=coalesce(started_at,now())
  WHERE id=v_lobby.id;

  INSERT INTO public.audit_logs(actor_id,community_id,event_id,entity_type,entity_id,action,metadata)
  VALUES (
    auth.uid(),v_event.community_id,v_event.id,'liveops_session',v_session.id,
    'liveops_lobby_session_started',
    jsonb_build_object('lobby_id',v_lobby.id,'lobby_code',v_lobby.lobby_code,'initial_match_id',v_match_id)
  );

  RETURN jsonb_build_object(
    'session_id',v_session.id,'lobby_id',v_lobby.id,'lobby_code',v_lobby.lobby_code,
    'event_id',v_lobby.event_id,'match_id',v_match_id,
    'match_sequence',v_sequence,'state',v_session.state,'already_active',false
  );
END;
$function$;
REVOKE ALL ON FUNCTION app_private.start_liveops_lobby_session(uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.start_liveops_lobby_session(uuid,jsonb) TO authenticated;

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
REVOKE ALL ON FUNCTION public.start_liveops_lobby_session(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.start_liveops_lobby_session(uuid,jsonb) TO authenticated;

COMMENT ON TABLE public.event_lobbies IS
  'A generated Lobby ID groups one or more ordered matches and is used to start a LiveOps session.';
COMMENT ON TABLE public.event_lobby_matches IS
  'Ordered one-to-many Lobby ID to Match ID mapping. Match IDs remain the scoring and result identity.';
COMMENT ON COLUMN public.liveops_sessions.lobby_id IS
  'The Lobby ID used to launch this LiveOps session; match_id identifies the current individual match.';
