-- Structured tournament configuration, source-linked rulebooks and approval workflow.
-- LLM inference is deliberately excluded from the structured tournament write path.

ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS registration_opens_at timestamptz,
  ADD COLUMN IF NOT EXISTS event_config jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS banner_path text;

CREATE TABLE IF NOT EXISTS public.tournament_rulebooks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id uuid NOT NULL REFERENCES public.games(id) ON DELETE CASCADE,
  title text NOT NULL CHECK (char_length(title) BETWEEN 3 AND 180),
  version text NOT NULL CHECK (char_length(version) BETWEEN 1 AND 40),
  region text NOT NULL DEFAULT 'IN' CHECK (char_length(region) BETWEEN 2 AND 12),
  mode_scope text[] NOT NULL DEFAULT ARRAY['solo','duo','squad','custom']::text[],
  scope text NOT NULL CHECK (scope IN ('general','competition_specific')),
  source_title text NOT NULL CHECK (char_length(source_title) BETWEEN 3 AND 180),
  source_url text NOT NULL CHECK (source_url ~ '^https://'),
  storage_path text,
  rules_config jsonb NOT NULL DEFAULT '{}'::jsonb,
  scoring_config jsonb NOT NULL DEFAULT '{}'::jsonb,
  notes text NOT NULL DEFAULT '',
  effective_date date,
  source_checked_at timestamptz NOT NULL DEFAULT now(),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (game_id, title, version),
  CHECK (cardinality(mode_scope) > 0),
  CHECK (mode_scope <@ ARRAY['solo','duo','squad','custom']::text[])
);

CREATE INDEX IF NOT EXISTS tournament_rulebooks_game_active_idx
  ON public.tournament_rulebooks(game_id, is_active, title);

CREATE TABLE IF NOT EXISTS public.tournament_proposals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid REFERENCES public.ai_conversations(id) ON DELETE SET NULL,
  owner_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  community_id uuid NOT NULL REFERENCES public.communities(id) ON DELETE CASCADE,
  idempotency_key text NOT NULL CHECK (char_length(idempotency_key) BETWEEN 8 AND 120),
  payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  source_refs jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL DEFAULT 'pending_approval'
    CHECK (status IN ('pending_approval','approved','rejected','expired','failed')),
  event_id uuid REFERENCES public.events(id) ON DELETE SET NULL,
  approved_by uuid REFERENCES auth.users(id),
  approved_at timestamptz,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (owner_user_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS tournament_proposals_conversation_idx
  ON public.tournament_proposals(conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS tournament_proposals_owner_idx
  ON public.tournament_proposals(owner_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS tournament_proposals_community_idx
  ON public.tournament_proposals(community_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS public.tournament_config_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  version integer NOT NULL CHECK (version > 0),
  owner_user_id uuid NOT NULL REFERENCES auth.users(id),
  community_id uuid REFERENCES public.communities(id) ON DELETE SET NULL,
  config jsonb NOT NULL CHECK (jsonb_typeof(config) = 'object'),
  change_reason text NOT NULL DEFAULT 'Tournament configuration saved',
  changed_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, version)
);

CREATE INDEX IF NOT EXISTS tournament_config_versions_event_idx
  ON public.tournament_config_versions(event_id, version DESC);

ALTER TABLE public.tournament_rulebooks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_proposals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tournament_config_versions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tournament_rulebooks_read_active ON public.tournament_rulebooks;
CREATE POLICY tournament_rulebooks_read_active
  ON public.tournament_rulebooks FOR SELECT TO anon, authenticated
  USING (is_active = true);

DROP POLICY IF EXISTS tournament_proposals_read_owner_scope ON public.tournament_proposals;
CREATE POLICY tournament_proposals_read_owner_scope
  ON public.tournament_proposals FOR SELECT TO authenticated
  USING (
    owner_user_id = (SELECT auth.uid())
    AND app_private.can_access_ai_scope('organizer', community_id, NULL)
  );

DROP POLICY IF EXISTS tournament_config_versions_read_scope ON public.tournament_config_versions;
CREATE POLICY tournament_config_versions_read_scope
  ON public.tournament_config_versions FOR SELECT TO authenticated
  USING (
    owner_user_id = (SELECT auth.uid())
    OR app_private.can_access_ai_scope('organizer', community_id, NULL)
  );

REVOKE ALL ON public.tournament_rulebooks FROM anon, authenticated;
GRANT SELECT ON public.tournament_rulebooks TO anon, authenticated;
REVOKE ALL ON public.tournament_proposals FROM anon, authenticated;
GRANT SELECT ON public.tournament_proposals TO authenticated;
REVOKE ALL ON public.tournament_config_versions FROM anon, authenticated;
GRANT SELECT ON public.tournament_config_versions TO authenticated;
GRANT ALL ON public.tournament_rulebooks, public.tournament_proposals,
  public.tournament_config_versions TO service_role;

DROP TRIGGER IF EXISTS tournament_rulebooks_set_updated_at ON public.tournament_rulebooks;
CREATE TRIGGER tournament_rulebooks_set_updated_at
  BEFORE UPDATE ON public.tournament_rulebooks
  FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();

DROP TRIGGER IF EXISTS tournament_proposals_set_updated_at ON public.tournament_proposals;
CREATE TRIGGER tournament_proposals_set_updated_at
  BEFORE UPDATE ON public.tournament_proposals
  FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();

INSERT INTO public.games (code, name, publisher, platform, is_active)
VALUES ('bgmi', 'Battlegrounds Mobile India', 'KRAFTON', 'mobile', true)
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name,
  publisher = EXCLUDED.publisher,
  platform = EXCLUDED.platform,
  is_active = true;

-- BMIC 2025's official KRAFTON rulebook is a competition-specific document,
-- not a universal/current BGMI rulebook.
INSERT INTO public.tournament_rulebooks (
  game_id, title, version, region, mode_scope, scope, source_title, source_url,
  rules_config, scoring_config, notes, effective_date, is_active
)
SELECT
  g.id,
  'BATTLEGROUNDS MOBILE INDIA International Cup 2025 — Official Competition Rulebook',
  '1.0.0 · 29 Oct 2025',
  'IN',
  ARRAY['squad']::text[],
  'competition_specific',
  'KRAFTON India Esports — BMIC 2025 Official Competition Rulebook',
  'https://esports.battlegroundsmobileindia.com/bmic_rulebook.pdf',
  jsonb_build_object(
    'source', 'official_competition_rulebook',
    'version', '1.0.0',
    'sections', jsonb_build_array(
      'General terms and acceptance',
      'Player eligibility and registration',
      'Team roster requirements',
      'Equipment, apparel and sponsorship restrictions',
      'Code of conduct and disciplinary actions',
      'Match procedures, technical issues and evidence',
      'Competition-specific format and prizes'
    ),
    'competition_format', jsonb_build_object(
      'event', 'BMIC 2025',
      'team_count', 16,
      'matches', 18,
      'days', 3,
      'matches_per_day', 6,
      'maps', jsonb_build_array('Rondo','Erangel','Miramar'),
      'mode', 'TPP'
    )
  ),
  jsonb_build_object(
    'scheme', 'placement_plus_finishes',
    'placement_points', jsonb_build_object(
      '1',10,'2',6,'3',5,'4',4,'5',3,'6',2,
      '7',1,'8',1,'9',0,'10',0,'11',0,'12',0,
      '13',0,'14',0,'15',0,'16',0
    ),
    'finish_point', 1,
    'tiebreakers', jsonb_build_array(
      'total_first_places',
      'total_placement_points',
      'total_finishes',
      'most_recent_match_placement'
    ),
    'scope_warning', 'This scoring preset is specific to the BMIC 2025 competition rulebook and must not be assumed to be the current or universal BGMI scoring format.'
  ),
  'Competition-specific BMIC 2025 rules. KRAFTON may issue separate event-specific rules and update requirements. Organisers must verify applicability before using this preset.',
  DATE '2025-10-29',
  true
FROM public.games g
WHERE g.code = 'bgmi'
ON CONFLICT (game_id, title, version) DO UPDATE SET
  source_url = EXCLUDED.source_url,
  rules_config = EXCLUDED.rules_config,
  scoring_config = EXCLUDED.scoring_config,
  notes = EXCLUDED.notes,
  source_checked_at = now(),
  is_active = true;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'tournament-banners',
  'tournament-banners',
  false,
  10485760,
  ARRAY['image/jpeg','image/png','image/webp']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = 10485760,
  allowed_mime_types = ARRAY['image/jpeg','image/png','image/webp']::text[];

DROP POLICY IF EXISTS tournament_banners_upload_manager ON storage.objects;
CREATE POLICY tournament_banners_upload_manager
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'tournament-banners'
    AND (storage.foldername(name))[2] = (SELECT auth.uid()::text)
    AND app_private.can_manage_community_structure(((storage.foldername(name))[1])::uuid)
  );

DROP POLICY IF EXISTS tournament_banners_read_manager ON storage.objects;
CREATE POLICY tournament_banners_read_manager
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'tournament-banners'
    AND (storage.foldername(name))[2] = (SELECT auth.uid()::text)
    AND app_private.can_manage_community_structure(((storage.foldername(name))[1])::uuid)
  );

CREATE OR REPLACE FUNCTION public.resolve_tournament_proposal(
  p_proposal_id uuid, p_user_id uuid, p_decision text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_proposal public.tournament_proposals%rowtype;
  v_payload jsonb;
  v_event_config jsonb;
  v_rules jsonb;
  v_scoring jsonb;
  v_name text;
  v_description text;
  v_format text;
  v_capacity integer;
  v_game_id uuid;
  v_community_id uuid;
  v_starts_at timestamptz;
  v_registration_opens_at timestamptz;
  v_registration_closes_at timestamptz;
  v_banner_path text;
  v_event_id uuid;
  v_event_status text;
  v_result jsonb;
BEGIN
  IF (SELECT auth.role()) <> 'service_role' THEN
    RAISE EXCEPTION 'service role required' USING errcode = '42501';
  END IF;
  IF p_proposal_id IS NULL OR p_user_id IS NULL OR p_decision NOT IN ('approve','reject') THEN
    RAISE EXCEPTION 'invalid tournament proposal resolution input' USING errcode = '22023';
  END IF;

  SELECT * INTO v_proposal
  FROM public.tournament_proposals
  WHERE id = p_proposal_id AND owner_user_id = p_user_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'tournament proposal not found' USING errcode = 'P0002'; END IF;

  IF v_proposal.status = 'approved' AND p_decision = 'approve' AND v_proposal.event_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'event_id', v_proposal.event_id, 'proposal_id', p_proposal_id,
      'status', 'draft', 'already_executed', true, 'published', false
    );
  END IF;
  IF v_proposal.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'tournament proposal is not awaiting approval' USING errcode = '55000';
  END IF;
  IF v_proposal.expires_at <= now() THEN
    UPDATE public.tournament_proposals SET status = 'expired' WHERE id = p_proposal_id;
    RAISE EXCEPTION 'tournament proposal expired' USING errcode = '55000';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.community_members cm
    WHERE cm.community_id = v_proposal.community_id
      AND cm.user_id = p_user_id AND cm.role IN ('owner','admin','organiser')
  ) AND NOT EXISTS (
    SELECT 1 FROM public.communities c
    WHERE c.id = v_proposal.community_id AND c.owner_user_id = p_user_id
  ) THEN
    RAISE EXCEPTION 'organizer permissions changed; tournament proposal cannot be approved' USING errcode = '42501';
  END IF;

  IF p_decision = 'reject' THEN
    UPDATE public.tournament_proposals
    SET status = 'rejected', approved_by = p_user_id, approved_at = now()
    WHERE id = p_proposal_id;
    RETURN jsonb_build_object('status','rejected','proposal_id',p_proposal_id);
  END IF;

  v_payload := v_proposal.payload;
  v_event_config := COALESCE(v_payload->'event_config','{}'::jsonb);
  v_rules := COALESCE(v_payload->'rules_json','{}'::jsonb);
  v_scoring := COALESCE(v_payload->'scoring_config','{}'::jsonb);
  v_name := btrim(COALESCE(v_payload->>'name',''));
  v_description := left(COALESCE(v_payload->>'description',''),2000);
  v_format := COALESCE(v_payload->>'format','');
  v_banner_path := NULLIF(v_payload->>'banner_path','');

  BEGIN
    v_capacity := (v_payload->>'capacity')::integer;
    v_game_id := NULLIF(v_payload->>'game_id','')::uuid;
    v_starts_at := (v_payload->>'starts_at')::timestamptz;
    v_registration_opens_at := (v_payload->>'registration_opens_at')::timestamptz;
    v_registration_closes_at := (v_payload->>'registration_closes_at')::timestamptz;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'tournament proposal contains invalid field types' USING errcode = '22023';
  END;

  IF char_length(v_name) < 3 OR char_length(v_name) > 100 THEN
    RAISE EXCEPTION 'tournament name must be 3 to 100 characters' USING errcode = '22023';
  END IF;
  IF v_format NOT IN ('solo','duo','squad','custom') THEN
    RAISE EXCEPTION 'invalid tournament mode' USING errcode = '22023';
  END IF;
  IF v_capacity IS NULL OR v_capacity < 1 OR v_capacity > 1000 THEN
    RAISE EXCEPTION 'slot capacity must be between 1 and 1000' USING errcode = '22023';
  END IF;
  IF v_game_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.games g WHERE g.id = v_game_id AND g.is_active = true
  ) THEN
    RAISE EXCEPTION 'active game is required' USING errcode = '22023';
  END IF;
  IF v_registration_opens_at IS NULL OR v_registration_closes_at IS NULL OR v_starts_at IS NULL
    OR v_registration_opens_at <= now()
    OR v_registration_closes_at <= v_registration_opens_at
    OR v_starts_at <= v_registration_closes_at THEN
    RAISE EXCEPTION 'registration start, registration close and tournament start must be future and in chronological order' USING errcode = '22023';
  END IF;
  IF jsonb_typeof(v_event_config) <> 'object'
    OR jsonb_typeof(v_rules) <> 'object'
    OR jsonb_typeof(v_scoring) <> 'object' THEN
    RAISE EXCEPTION 'event rules, scoring and configuration must be JSON objects' USING errcode = '22023';
  END IF;
  IF v_event_config->>'entry_type' = 'paid'
    AND COALESCE((v_event_config->>'entry_fee')::numeric, 0) <= 0 THEN
    RAISE EXCEPTION 'paid entry requires a positive entry fee' USING errcode = '22023';
  END IF;
  IF v_event_config->>'entry_type' NOT IN ('free','paid') THEN
    RAISE EXCEPTION 'entry type must be free or paid' USING errcode = '22023';
  END IF;
  IF v_banner_path IS NOT NULL AND v_banner_path NOT LIKE v_community_id::text || '/' || p_user_id::text || '/%' THEN
    RAISE EXCEPTION 'banner path is outside the organiser upload scope' USING errcode = '42501';
  END IF;
  IF NULLIF(v_event_config->'rulebook'->>'id','') IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.tournament_rulebooks rb
    WHERE rb.id = (v_event_config->'rulebook'->>'id')::uuid
      AND rb.game_id = v_game_id AND rb.is_active = true AND v_format = ANY(rb.mode_scope)
  ) THEN
    RAISE EXCEPTION 'selected rulebook is no longer active for this game and mode' USING errcode = '22023';
  END IF;

  INSERT INTO public.events (
    community_id, game_id, organizer_id, name, description, format, status,
    starts_at, registration_opens_at, registration_closes_at, capacity,
    rules_json, scoring_config, event_config, banner_path
  ) VALUES (
    v_proposal.community_id, v_game_id, p_user_id, v_name, v_description, v_format, 'draft',
    v_starts_at, v_registration_opens_at, v_registration_closes_at, v_capacity,
    v_rules, v_scoring, v_event_config, v_banner_path
  ) RETURNING id, status INTO v_event_id, v_event_status;

  INSERT INTO public.tournament_config_versions (
    event_id, version, owner_user_id, community_id, config, change_reason, changed_by
  ) VALUES (
    v_event_id, 1, p_user_id, v_proposal.community_id,
    jsonb_build_object(
      'name', v_name, 'format', v_format, 'capacity', v_capacity,
      'game_id', v_game_id, 'starts_at', v_starts_at,
      'registration_opens_at', v_registration_opens_at,
      'registration_closes_at', v_registration_closes_at,
      'rules_json', v_rules, 'scoring_config', v_scoring,
      'event_config', v_event_config, 'banner_path', v_banner_path
    ),
    'Initial organiser-approved tournament draft', p_user_id
  );

  UPDATE public.tournament_proposals
  SET status = 'approved', event_id = v_event_id, approved_by = p_user_id, approved_at = now()
  WHERE id = p_proposal_id;

  INSERT INTO public.audit_logs (
    actor_id, community_id, event_id, entity_type, entity_id, action, reason, metadata
  ) VALUES (
    p_user_id, v_proposal.community_id, v_event_id, 'event', v_event_id,
    'tournament_draft_created',
    'Organiser explicitly approved structured tournament proposal',
    jsonb_build_object('proposal_id', p_proposal_id, 'published', false)
  );

  v_result := jsonb_build_object(
    'event_id', v_event_id, 'proposal_id', p_proposal_id,
    'name', v_name, 'status', v_event_status, 'approved', true, 'published', false
  );
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.resolve_tournament_proposal(uuid,uuid,text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_tournament_proposal(uuid,uuid,text) TO service_role;
COMMENT ON FUNCTION public.resolve_tournament_proposal(uuid,uuid,text) IS
  'Service-role-only atomic tournament proposal resolver. Rechecks current community organiser authority; creates DRAFT only and never publishes.';

CREATE OR REPLACE FUNCTION public.update_tournament_draft(
  p_event_id uuid, p_user_id uuid, p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event public.events%rowtype;
  v_event_config jsonb;
  v_rules jsonb;
  v_scoring jsonb;
  v_name text;
  v_description text;
  v_format text;
  v_capacity integer;
  v_game_id uuid;
  v_starts_at timestamptz;
  v_registration_opens_at timestamptz;
  v_registration_closes_at timestamptz;
  v_banner_path text;
  v_version integer;
BEGIN
  IF (SELECT auth.role()) <> 'service_role' THEN
    RAISE EXCEPTION 'service role required' USING errcode = '42501';
  END IF;
  IF p_event_id IS NULL OR p_user_id IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'invalid tournament update input' USING errcode = '22023';
  END IF;

  SELECT * INTO v_event FROM public.events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'tournament not found' USING errcode = 'P0002'; END IF;
  IF v_event.status <> 'draft' THEN
    RAISE EXCEPTION 'only draft tournaments can be edited; publish or active events are locked' USING errcode = '55000';
  END IF;
  IF EXISTS (SELECT 1 FROM public.event_registrations er WHERE er.event_id = p_event_id)
     OR EXISTS (SELECT 1 FROM public.matches m WHERE m.event_id = p_event_id) THEN
    RAISE EXCEPTION 'tournament configuration is locked after registrations or matches exist' USING errcode = '55000';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.community_members cm
    WHERE cm.community_id = v_event.community_id
      AND cm.user_id = p_user_id AND cm.role IN ('owner','admin','organiser')
  ) AND NOT EXISTS (
    SELECT 1 FROM public.communities c
    WHERE c.id = v_event.community_id AND c.owner_user_id = p_user_id
  ) THEN
    RAISE EXCEPTION 'organizer permissions changed; tournament cannot be edited' USING errcode = '42501';
  END IF;

  v_event_config := COALESCE(p_payload->'event_config','{}'::jsonb);
  v_rules := COALESCE(p_payload->'rules_json','{}'::jsonb);
  v_scoring := COALESCE(p_payload->'scoring_config','{}'::jsonb);
  v_name := btrim(COALESCE(p_payload->>'name',''));
  v_description := left(COALESCE(p_payload->>'description',''),2000);
  v_format := COALESCE(p_payload->>'format','');
  v_banner_path := NULLIF(p_payload->>'banner_path','');

  BEGIN
    v_capacity := (p_payload->>'capacity')::integer;
    v_game_id := NULLIF(p_payload->>'game_id','')::uuid;
    v_starts_at := (p_payload->>'starts_at')::timestamptz;
    v_registration_opens_at := (p_payload->>'registration_opens_at')::timestamptz;
    v_registration_closes_at := (p_payload->>'registration_closes_at')::timestamptz;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'tournament update contains invalid field types' USING errcode = '22023';
  END;

  IF char_length(v_name) < 3 OR char_length(v_name) > 100
     OR v_format NOT IN ('solo','duo','squad','custom')
     OR v_capacity IS NULL OR v_capacity < 1 OR v_capacity > 1000 THEN
    RAISE EXCEPTION 'tournament name, mode or slot capacity is invalid' USING errcode = '22023';
  END IF;
  IF v_game_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.games g WHERE g.id = v_game_id AND g.is_active = true
  ) THEN
    RAISE EXCEPTION 'active game is required' USING errcode = '22023';
  END IF;
  IF v_registration_opens_at IS NULL OR v_registration_closes_at IS NULL OR v_starts_at IS NULL
    OR v_registration_opens_at <= now()
    OR v_registration_closes_at <= v_registration_opens_at
    OR v_starts_at <= v_registration_closes_at THEN
    RAISE EXCEPTION 'registration start, registration close and tournament start must be future and in chronological order' USING errcode = '22023';
  END IF;
  IF v_event_config->>'entry_type' = 'paid'
    AND COALESCE((v_event_config->>'entry_fee')::numeric, 0) <= 0 THEN
    RAISE EXCEPTION 'paid entry requires a positive entry fee' USING errcode = '22023';
  END IF;
  IF v_event_config->>'entry_type' NOT IN ('free','paid') THEN
    RAISE EXCEPTION 'entry type must be free or paid' USING errcode = '22023';
  END IF;
  IF v_banner_path IS NOT NULL AND v_banner_path NOT LIKE v_event.community_id::text || '/' || p_user_id::text || '/%' THEN
    RAISE EXCEPTION 'banner path is outside the organiser upload scope' USING errcode = '42501';
  END IF;
  IF NULLIF(v_event_config->'rulebook'->>'id','') IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.tournament_rulebooks rb
    WHERE rb.id = (v_event_config->'rulebook'->>'id')::uuid
      AND rb.game_id = v_game_id AND rb.is_active = true AND v_format = ANY(rb.mode_scope)
  ) THEN
    RAISE EXCEPTION 'selected rulebook is no longer active for this game and mode' USING errcode = '22023';
  END IF;

  UPDATE public.events SET
    name = v_name, description = v_description, format = v_format,
    game_id = v_game_id, capacity = v_capacity, starts_at = v_starts_at,
    registration_opens_at = v_registration_opens_at,
    registration_closes_at = v_registration_closes_at,
    rules_json = v_rules, scoring_config = v_scoring,
    event_config = v_event_config, banner_path = v_banner_path, updated_at = now()
  WHERE id = p_event_id;

  SELECT COALESCE(max(version),0) + 1 INTO v_version
  FROM public.tournament_config_versions WHERE event_id = p_event_id;

  INSERT INTO public.tournament_config_versions (
    event_id, version, owner_user_id, community_id, config, change_reason, changed_by
  ) VALUES (
    p_event_id, v_version, p_user_id, v_event.community_id,
    jsonb_build_object(
      'name', v_name, 'format', v_format, 'capacity', v_capacity,
      'game_id', v_game_id, 'starts_at', v_starts_at,
      'registration_opens_at', v_registration_opens_at,
      'registration_closes_at', v_registration_closes_at,
      'rules_json', v_rules, 'scoring_config', v_scoring,
      'event_config', v_event_config, 'banner_path', v_banner_path
    ),
    'Organiser edited draft tournament configuration', p_user_id
  );

  INSERT INTO public.audit_logs (
    actor_id, community_id, event_id, entity_type, entity_id, action, reason, metadata
  ) VALUES (
    p_user_id, v_event.community_id, p_event_id, 'event', p_event_id,
    'tournament_draft_updated',
    'Organiser edited draft tournament configuration',
    jsonb_build_object('config_version', v_version)
  );

  RETURN jsonb_build_object('event_id', p_event_id, 'version', v_version, 'status', 'draft', 'published', false);
END;
$function$;

REVOKE ALL ON FUNCTION public.update_tournament_draft(uuid,uuid,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_tournament_draft(uuid,uuid,jsonb) TO service_role;
COMMENT ON FUNCTION public.update_tournament_draft(uuid,uuid,jsonb) IS
  'Service-role-only draft editor. Restricts changes to authorised organisers before registrations or matches exist and appends a version snapshot.';
