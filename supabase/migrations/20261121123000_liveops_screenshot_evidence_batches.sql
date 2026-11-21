-- Private, Match-bound batches for manually selected LiveOps screenshots.
-- The client uploads each file to the private match-evidence bucket, then registers
-- the complete batch in one transaction. OCR is run locally on each selected image.

CREATE TABLE IF NOT EXISTS public.liveops_evidence_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES public.liveops_sessions(id) ON DELETE CASCADE,
  lobby_id uuid NOT NULL REFERENCES public.event_lobbies(id) ON DELETE CASCADE,
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  match_id uuid NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  operator_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  capture_kind text NOT NULL DEFAULT 'result'
    CHECK (capture_kind IN ('lobby','result','other')),
  idempotency_key text NOT NULL
    CHECK (char_length(idempotency_key) BETWEEN 8 AND 120),
  request_fingerprint text NOT NULL
    CHECK (request_fingerprint ~ '^[0-9a-f]{64}$'),
  screenshot_count integer NOT NULL
    CHECK (screenshot_count BETWEEN 1 AND 8),
  status text NOT NULL DEFAULT 'uploaded'
    CHECK (status IN ('uploaded','submitted','rejected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(session_id,match_id,idempotency_key)
);

ALTER TABLE public.liveops_evidence_batches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.liveops_evidence_batches FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.liveops_evidence_batches TO authenticated;
GRANT ALL ON public.liveops_evidence_batches TO service_role;

DROP POLICY IF EXISTS liveops_evidence_batches_read_operator_or_reviewer
  ON public.liveops_evidence_batches;
CREATE POLICY liveops_evidence_batches_read_operator_or_reviewer
  ON public.liveops_evidence_batches
  FOR SELECT TO authenticated
  USING (
    operator_id=(SELECT auth.uid())
    OR app_private.resolve_permission('event.results.review','event',event_id,NULL,NULL)
    OR app_private.resolve_permission('event.matches.operate','event',event_id,NULL,NULL)
  );

ALTER TABLE public.liveops_captures
  ADD COLUMN IF NOT EXISTS evidence_batch_id uuid
    REFERENCES public.liveops_evidence_batches(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS sequence_no integer,
  ADD COLUMN IF NOT EXISTS content_type text,
  ADD COLUMN IF NOT EXISTS file_size bigint,
  ADD COLUMN IF NOT EXISTS content_sha256 text;

ALTER TABLE public.liveops_captures
  DROP CONSTRAINT IF EXISTS liveops_captures_sequence_no_check,
  ADD CONSTRAINT liveops_captures_sequence_no_check
    CHECK (sequence_no IS NULL OR sequence_no BETWEEN 1 AND 8),
  DROP CONSTRAINT IF EXISTS liveops_captures_content_type_check,
  ADD CONSTRAINT liveops_captures_content_type_check
    CHECK (content_type IS NULL OR content_type IN ('image/jpeg','image/png','image/webp')),
  DROP CONSTRAINT IF EXISTS liveops_captures_file_size_check,
  ADD CONSTRAINT liveops_captures_file_size_check
    CHECK (file_size IS NULL OR file_size BETWEEN 1 AND 10485760),
  DROP CONSTRAINT IF EXISTS liveops_captures_sha256_check,
  ADD CONSTRAINT liveops_captures_sha256_check
    CHECK (content_sha256 IS NULL OR content_sha256 ~ '^[0-9a-f]{64}$');

CREATE UNIQUE INDEX IF NOT EXISTS liveops_captures_batch_sequence_uidx
  ON public.liveops_captures(evidence_batch_id,sequence_no)
  WHERE evidence_batch_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS liveops_captures_match_content_hash_uidx
  ON public.liveops_captures(match_id,content_sha256)
  WHERE content_sha256 IS NOT NULL;
CREATE INDEX IF NOT EXISTS liveops_captures_batch_idx
  ON public.liveops_captures(evidence_batch_id)
  WHERE evidence_batch_id IS NOT NULL;

ALTER TABLE public.screen_observations
  ADD COLUMN IF NOT EXISTS liveops_capture_id uuid
    REFERENCES public.liveops_captures(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS evidence_batch_id uuid
    REFERENCES public.liveops_evidence_batches(id) ON DELETE CASCADE;

CREATE UNIQUE INDEX IF NOT EXISTS screen_observations_capture_uidx
  ON public.screen_observations(liveops_capture_id)
  WHERE liveops_capture_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS screen_observations_evidence_batch_idx
  ON public.screen_observations(evidence_batch_id)
  WHERE evidence_batch_id IS NOT NULL;

-- Keep the lobby binding immutable for the entire lifetime of a LiveOps session.
CREATE OR REPLACE FUNCTION app_private.guard_liveops_session_scope()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_match_event uuid;
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
     OR NEW.started_at IS DISTINCT FROM OLD.started_at THEN
    RAISE EXCEPTION 'LiveOps session identity, Lobby ID and match binding are immutable';
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

REVOKE ALL ON FUNCTION app_private.guard_liveops_session_scope() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.guard_liveops_session_scope() TO service_role;

-- Bind each screenshot row to the exact batch that owns its session, lobby, event and match.
CREATE OR REPLACE FUNCTION app_private.guard_liveops_capture_scope()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_match_event uuid;
  v_session_operator uuid;
  v_session_match uuid;
  v_session_event uuid;
  v_batch public.liveops_evidence_batches%ROWTYPE;
BEGIN
  IF TG_OP='INSERT' THEN
    SELECT s.operator_id,s.match_id,s.event_id,m.event_id
      INTO v_session_operator,v_session_match,v_session_event,v_match_event
    FROM public.liveops_sessions s
    JOIN public.matches m ON m.id=s.match_id
    WHERE s.id=NEW.session_id;
    IF NOT FOUND
       OR v_session_operator IS DISTINCT FROM NEW.operator_id
       OR v_session_match IS DISTINCT FROM NEW.match_id
       OR v_session_event IS DISTINCT FROM NEW.event_id
       OR v_match_event IS DISTINCT FROM NEW.event_id THEN
      RAISE EXCEPTION 'Capture must be bound to its operator session, match and event';
    END IF;

    IF NEW.evidence_batch_id IS NOT NULL THEN
      SELECT * INTO v_batch
      FROM public.liveops_evidence_batches b
      WHERE b.id=NEW.evidence_batch_id;
      IF NOT FOUND
         OR v_batch.session_id IS DISTINCT FROM NEW.session_id
         OR v_batch.event_id IS DISTINCT FROM NEW.event_id
         OR v_batch.match_id IS DISTINCT FROM NEW.match_id
         OR v_batch.operator_id IS DISTINCT FROM NEW.operator_id THEN
        RAISE EXCEPTION 'Screenshot does not belong to this evidence batch and Match ID';
      END IF;
    END IF;

    IF auth.uid() IS NOT NULL THEN
      IF NEW.operator_id IS DISTINCT FROM auth.uid()
         OR NOT app_private.resolve_permission('liveops.capture.submit','match',NEW.match_id,NULL,NULL) THEN
        RAISE EXCEPTION 'You are not authorised to attach evidence to this match';
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.session_id IS DISTINCT FROM OLD.session_id
     OR NEW.event_id IS DISTINCT FROM OLD.event_id
     OR NEW.match_id IS DISTINCT FROM OLD.match_id
     OR NEW.operator_id IS DISTINCT FROM OLD.operator_id
     OR NEW.evidence_path IS DISTINCT FROM OLD.evidence_path
     OR NEW.ocr_text IS DISTINCT FROM OLD.ocr_text
     OR NEW.capture_kind IS DISTINCT FROM OLD.capture_kind
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.evidence_batch_id IS DISTINCT FROM OLD.evidence_batch_id
     OR NEW.sequence_no IS DISTINCT FROM OLD.sequence_no
     OR NEW.content_type IS DISTINCT FROM OLD.content_type
     OR NEW.file_size IS DISTINCT FROM OLD.file_size
     OR NEW.content_sha256 IS DISTINCT FROM OLD.content_sha256 THEN
    RAISE EXCEPTION 'Capture identity, batch, evidence and source cannot be edited after upload';
  END IF;
  IF auth.uid() IS NOT NULL
     AND NOT app_private.resolve_permission('liveops.capture.review','liveops_session',OLD.session_id,NULL,NULL) THEN
    RAISE EXCEPTION 'Only an authorised reviewer may review a capture';
  END IF;
  IF NEW.review_status NOT IN ('pending','submitted','accepted','rejected') THEN
    RAISE EXCEPTION 'Invalid capture review status';
  END IF;
  IF NEW.review_status IS DISTINCT FROM OLD.review_status
     OR NEW.reviewed_by IS DISTINCT FROM OLD.reviewed_by
     OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at
     OR NEW.review_note IS DISTINCT FROM OLD.review_note THEN
    IF NEW.reviewed_by IS DISTINCT FROM auth.uid() AND auth.uid() IS NOT NULL THEN
      RAISE EXCEPTION 'Capture reviewer must match the authenticated user';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.guard_liveops_capture_scope() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.guard_liveops_capture_scope() TO service_role;

CREATE OR REPLACE FUNCTION app_private.register_liveops_evidence_batch(
  p_session_id uuid,
  p_lobby_id uuid,
  p_match_id uuid,
  p_idempotency_key text,
  p_capture_kind text,
  p_items jsonb
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
  v_batch public.liveops_evidence_batches%ROWTYPE;
  v_item jsonb;
  v_path text;
  v_type text;
  v_size bigint;
  v_sha text;
  v_ocr text;
  v_observed_at timestamptz;
  v_fingerprint text;
  v_capture_id uuid;
  v_observation_id uuid;
  v_sequence integer := 0;
  v_capture_ids uuid[] := ARRAY[]::uuid[];
  v_observation_ids uuid[] := ARRAY[]::uuid[];
  v_items_result jsonb := '[]'::jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF p_session_id IS NULL OR p_lobby_id IS NULL OR p_match_id IS NULL THEN
    RAISE EXCEPTION 'LiveOps session, Lobby ID and Match ID are required';
  END IF;
  IF p_idempotency_key IS NULL OR char_length(p_idempotency_key) NOT BETWEEN 8 AND 120 THEN
    RAISE EXCEPTION 'A valid evidence batch request ID is required';
  END IF;
  IF p_capture_kind NOT IN ('lobby','result','other') THEN
    RAISE EXCEPTION 'Choose a valid screenshot capture type';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 8 THEN
    RAISE EXCEPTION 'Choose between one and eight screenshots for this Match ID';
  END IF;

  SELECT * INTO v_session
  FROM public.liveops_sessions s
  WHERE s.id=p_session_id AND s.operator_id=v_uid
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'LiveOps session not found'; END IF;
  IF v_session.lobby_id IS DISTINCT FROM p_lobby_id
     OR v_session.match_id IS DISTINCT FROM p_match_id THEN
    RAISE EXCEPTION 'Evidence must use the active Lobby ID and its current Match ID';
  END IF;
  IF v_session.state NOT IN ('created','capturing','paused') THEN
    RAISE EXCEPTION 'Pause or resume the LiveOps session before uploading screenshots';
  END IF;
  IF NOT app_private.resolve_permission('liveops.capture.submit','match',p_match_id,NULL,NULL) THEN
    RAISE EXCEPTION 'You are not authorised to attach evidence to this Match ID' USING errcode='42501';
  END IF;

  SELECT * INTO v_match FROM public.matches m WHERE m.id=p_match_id FOR UPDATE;
  IF NOT FOUND OR v_match.event_id IS DISTINCT FROM v_session.event_id
     OR v_match.status IN ('completed','cancelled') THEN
    RAISE EXCEPTION 'This Match ID is unavailable or closed';
  END IF;
  SELECT * INTO v_event FROM public.events e WHERE e.id=v_match.event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tournament not found'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.event_lobby_matches lm
    WHERE lm.lobby_id=p_lobby_id AND lm.match_id=p_match_id
  ) THEN
    RAISE EXCEPTION 'The selected Match ID is not assigned to this Lobby ID';
  END IF;

  SELECT string_agg(lower(item->>'sha256'),':' ORDER BY ordinality)
    INTO v_fingerprint
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS input(item,ordinality);
  IF v_fingerprint IS NULL OR v_fingerprint !~ '^[0-9a-f]{64}(:[0-9a-f]{64}){0,7}$' THEN
    RAISE EXCEPTION 'Every screenshot must include a valid SHA-256 digest';
  END IF;
  IF (
    SELECT count(DISTINCT lower(item->>'sha256'))
    FROM jsonb_array_elements(p_items) AS input(item)
  ) <> jsonb_array_length(p_items) THEN
    RAISE EXCEPTION 'The same screenshot was selected more than once in this batch';
  END IF;

  SELECT * INTO v_batch
  FROM public.liveops_evidence_batches b
  WHERE b.session_id=p_session_id
    AND b.match_id=p_match_id
    AND b.idempotency_key=p_idempotency_key
  FOR UPDATE;
  IF FOUND THEN
    IF v_batch.request_fingerprint IS DISTINCT FROM encode(
      extensions.digest(convert_to(v_fingerprint,'UTF8'),'sha256'),'hex'
    ) THEN
      RAISE EXCEPTION 'This evidence request ID was already used for different screenshots';
    END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'capture_id',c.id,'sequence_no',c.sequence_no,
      'observation_id',o.id,'content_sha256',c.content_sha256
    ) ORDER BY c.sequence_no),'[]'::jsonb)
    INTO v_items_result
    FROM public.liveops_captures c
    LEFT JOIN public.screen_observations o ON o.liveops_capture_id=c.id
    WHERE c.evidence_batch_id=v_batch.id;
    RETURN jsonb_build_object(
      'batch_id',v_batch.id,'session_id',p_session_id,'lobby_id',p_lobby_id,
      'match_id',p_match_id,'status',v_batch.status,
      'screenshot_count',v_batch.screenshot_count,'already_registered',true,
      'items',v_items_result
    );
  END IF;

  -- Validate all object paths and metadata before creating any database rows.
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_path := coalesce(v_item->>'path','');
    v_type := lower(coalesce(v_item->>'content_type',''));
    v_size := nullif(v_item->>'file_size','')::bigint;
    v_sha := lower(coalesce(v_item->>'sha256',''));
    v_ocr := coalesce(v_item->>'ocr_text','');
    IF v_path = '' OR left(v_path,
      char_length(v_uid::text||'/'||v_session.event_id::text||'/'||p_match_id::text||'/'||p_session_id::text||'/')
    ) <> v_uid::text||'/'||v_session.event_id::text||'/'||p_match_id::text||'/'||p_session_id::text||'/' THEN
      RAISE EXCEPTION 'Screenshot storage path does not match the signed-in user, event, match and session';
    END IF;
    IF v_type NOT IN ('image/jpeg','image/png','image/webp')
       OR v_size IS NULL OR v_size NOT BETWEEN 1 AND 10485760
       OR v_sha !~ '^[0-9a-f]{64}$' OR char_length(v_ocr)>20000 THEN
      RAISE EXCEPTION 'Screenshot type, size, digest or OCR text is outside the allowed limits';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM storage.objects o
      WHERE o.bucket_id='match-evidence' AND o.name=v_path
    ) THEN
      RAISE EXCEPTION 'Screenshot file is missing from private Match Evidence storage';
    END IF;
  END LOOP;

  INSERT INTO public.liveops_evidence_batches(
    session_id,lobby_id,event_id,match_id,operator_id,capture_kind,
    idempotency_key,request_fingerprint,screenshot_count,status
  ) VALUES (
    p_session_id,p_lobby_id,v_session.event_id,p_match_id,v_uid,p_capture_kind,
    p_idempotency_key,
    encode(extensions.digest(convert_to(v_fingerprint,'UTF8'),'sha256'),'hex'),
    jsonb_array_length(p_items),'uploaded'
  ) RETURNING * INTO v_batch;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_sequence := v_sequence + 1;
    v_path := v_item->>'path';
    v_type := lower(v_item->>'content_type');
    v_size := (v_item->>'file_size')::bigint;
    v_sha := lower(v_item->>'sha256');
    v_ocr := coalesce(v_item->>'ocr_text','');
    v_observed_at := coalesce(nullif(v_item->>'observed_at','')::timestamptz,now());

    INSERT INTO public.liveops_captures(
      session_id,event_id,match_id,operator_id,evidence_path,ocr_text,capture_kind,
      evidence_batch_id,sequence_no,content_type,file_size,content_sha256
    ) VALUES (
      p_session_id,v_session.event_id,p_match_id,v_uid,v_path,v_ocr,p_capture_kind,
      v_batch.id,v_sequence,v_type,v_size,v_sha
    ) RETURNING id INTO v_capture_id;

    INSERT INTO public.screen_observations(
      session_id,screen_state,confidence,extracted_text,extracted_fields,observed_at,
      liveops_capture_id,evidence_batch_id
    ) VALUES (
      p_session_id,'result',0,v_ocr,
      jsonb_build_object(
        'classification_status','unclassified',
        'source','on_device_mlkit_selected_screenshot',
        'capture_id',v_capture_id,
        'batch_id',v_batch.id,
        'sequence_no',v_sequence,
        'content_sha256',v_sha
      ),
      v_observed_at,v_capture_id,v_batch.id
    ) RETURNING id INTO v_observation_id;

    v_capture_ids := array_append(v_capture_ids,v_capture_id);
    v_observation_ids := array_append(v_observation_ids,v_observation_id);
    v_items_result := v_items_result || jsonb_build_array(jsonb_build_object(
      'capture_id',v_capture_id,'sequence_no',v_sequence,
      'observation_id',v_observation_id,'content_sha256',v_sha
    ));
  END LOOP;

  INSERT INTO public.audit_logs(
    actor_id,community_id,event_id,entity_type,entity_id,action,metadata
  ) VALUES (
    v_uid,v_event.community_id,v_event.id,'liveops_evidence_batch',v_batch.id,
    'liveops_evidence_batch_uploaded',
    jsonb_build_object(
      'session_id',p_session_id,'lobby_id',p_lobby_id,'match_id',p_match_id,
      'capture_kind',p_capture_kind,'screenshot_count',v_batch.screenshot_count,
      'capture_ids',v_capture_ids,'observation_ids',v_observation_ids
    )
  );

  RETURN jsonb_build_object(
    'batch_id',v_batch.id,'session_id',p_session_id,'lobby_id',p_lobby_id,
    'match_id',p_match_id,'status','uploaded',
    'screenshot_count',v_batch.screenshot_count,'already_registered',false,
    'items',v_items_result
  );
END;
$function$;

REVOKE ALL ON FUNCTION app_private.register_liveops_evidence_batch(uuid,uuid,uuid,text,text,jsonb)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.register_liveops_evidence_batch(uuid,uuid,uuid,text,text,jsonb)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.register_liveops_evidence_batch(
  p_session_id uuid,
  p_lobby_id uuid,
  p_match_id uuid,
  p_idempotency_key text,
  p_capture_kind text,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $function$
  SELECT app_private.register_liveops_evidence_batch(
    p_session_id,p_lobby_id,p_match_id,p_idempotency_key,p_capture_kind,p_items
  );
$function$;

REVOKE ALL ON FUNCTION public.register_liveops_evidence_batch(uuid,uuid,uuid,text,text,jsonb)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.register_liveops_evidence_batch(uuid,uuid,uuid,text,text,jsonb)
  TO authenticated;

-- Allow the uploader to clean up an orphaned file when batch registration fails,
-- but never delete an object once it is referenced by a registered capture.
DROP POLICY IF EXISTS match_evidence_delete_unregistered_own ON storage.objects;
CREATE POLICY match_evidence_delete_unregistered_own
  ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id='match-evidence'
    AND (storage.foldername(name))[1]=(SELECT auth.uid())::text
    AND NOT EXISTS (
      SELECT 1 FROM public.liveops_captures c WHERE c.evidence_path=objects.name
    )
  );

COMMENT ON TABLE public.liveops_evidence_batches IS
  'A variable-size (1-8) collection of selected screenshot evidence for one LiveOps session, Lobby ID and Match ID.';
COMMENT ON COLUMN public.liveops_captures.content_sha256 IS
  'Exact file hash. Uniqueness is scoped to session + Match ID, so identical screenshots in a different Match ID remain valid.';
COMMENT ON COLUMN public.screen_observations.liveops_capture_id IS
  'The exact selected screenshot from which this on-device OCR observation was produced.';
