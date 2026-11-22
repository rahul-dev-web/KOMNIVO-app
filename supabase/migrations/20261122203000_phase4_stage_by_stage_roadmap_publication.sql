
CREATE OR REPLACE FUNCTION public.publish_event_stage_roadmap(
  p_event_id uuid,
  p_stage_config jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  e public.events%ROWTYPE;
  r integer;
  n integer;
  nm text;
  stype text;
  gs integer;
  q integer;
  qualified integer;
  direct_n integer;
  assigned integer;
  invalid_direct integer;
  next_direct integer := 0;
  matches_n integer;
  interval_n integer;
  first_at timestamptz;
  previous_at timestamptz;
  next_at timestamptz;
  version_n integer;
  roadmap_ch uuid;
  all_published boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF NOT app_private.is_event_staff(p_event_id) THEN
    RAISE EXCEPTION 'Only authorised event staff can publish a stage roadmap';
  END IF;
  IF jsonb_typeof(p_stage_config) <> 'object' THEN
    RAISE EXCEPTION 'Submit one stage roadmap configuration object';
  END IF;

  SELECT * INTO e FROM public.events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tournament not found'; END IF;

  n := COALESCE(NULLIF(e.event_config->>'stage_count','')::integer,0);
  r := NULLIF(p_stage_config->>'round_number','')::integer;
  nm := NULLIF(trim(p_stage_config->>'stage_name'),'');
  stype := COALESCE(NULLIF(trim(p_stage_config->>'stage_type'),''),'custom');
  gs := NULLIF(p_stage_config->>'group_size','')::integer;
  q := NULLIF(p_stage_config->>'qualifiers_per_group','')::integer;
  qualified := NULLIF(p_stage_config->>'qualified_team_count','')::integer;
  direct_n := COALESCE(NULLIF(p_stage_config->>'direct_entry_count','')::integer,0);
  matches_n := NULLIF(p_stage_config->>'matches_per_group','')::integer;
  interval_n := NULLIF(p_stage_config->>'interval_minutes','')::integer;
  first_at := NULLIF(p_stage_config->>'first_match_at','')::timestamptz;

  IF n < 1 OR n > 16 OR r IS NULL OR r < 1 OR r > n THEN
    RAISE EXCEPTION 'Choose a stage between 1 and the configured stage count (%)',n;
  END IF;
  IF nm IS NULL OR char_length(nm) NOT BETWEEN 2 AND 80
     OR stype NOT IN ('qualifier','quarter_final','semi_final','final','grand_final','custom')
     OR gs IS NULL OR gs NOT BETWEEN 2 AND 24
     OR q IS NULL OR q NOT BETWEEN 0 AND gs
     OR qualified IS NULL OR qualified < 0
     OR matches_n IS NULL OR matches_n NOT BETWEEN 1 AND 20
     OR interval_n IS NULL OR interval_n NOT BETWEEN 1 AND 240
     OR first_at IS NULL OR first_at <= now() THEN
    RAISE EXCEPTION 'Stage % has missing or invalid roadmap settings',r;
  END IF;
  IF r < n AND q < 1 THEN
    RAISE EXCEPTION 'Every non-final stage needs at least one qualifier per group';
  END IF;
  IF r = n AND (q <> 0 OR qualified <> 0) THEN
    RAISE EXCEPTION 'The final stage must have zero outgoing qualifiers and zero expected qualified teams';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.event_rounds er
    WHERE er.event_id = p_event_id AND er.round_number = r
  ) THEN
    RAISE EXCEPTION 'Stage % has already been generated. Its published roadmap is locked to protect existing groups and matches.',r;
  END IF;

  SELECT count(*)::integer INTO assigned
  FROM public.event_stage_direct_invites
  WHERE event_id = p_event_id AND target_round_number = r;
  IF assigned <> direct_n THEN
    RAISE EXCEPTION 'Stage % expects % direct-entry teams, but % are currently assigned',r,direct_n,assigned;
  END IF;

  SELECT count(*)::integer INTO invalid_direct
  FROM public.event_stage_direct_invites di
  WHERE di.event_id = p_event_id AND di.target_round_number = r
    AND NOT EXISTS (
      SELECT 1
      FROM public.event_registrations er
      JOIN public.teams t ON t.id = er.team_id
      WHERE er.event_id = p_event_id
        AND er.team_id = di.team_id
        AND er.status IN ('approved','checked_in')
        AND er.roster_locked
        AND t.game_id = e.game_id
    );
  IF invalid_direct > 0 THEN
    RAISE EXCEPTION 'One or more direct-entry teams no longer have an approved, roster-locked registration for this event and game';
  END IF;

  IF r < n THEN
    SELECT count(*)::integer INTO next_direct
    FROM public.event_stage_direct_invites
    WHERE event_id = p_event_id AND target_round_number = r + 1;
  END IF;

  SELECT (configuration->>'first_match_at')::timestamptz INTO previous_at
  FROM public.event_stage_roadmaps
  WHERE event_id = p_event_id AND round_number = r - 1 AND published_at IS NOT NULL;
  SELECT (configuration->>'first_match_at')::timestamptz INTO next_at
  FROM public.event_stage_roadmaps
  WHERE event_id = p_event_id AND round_number = r + 1 AND published_at IS NOT NULL;
  IF previous_at IS NOT NULL AND first_at <= previous_at THEN
    RAISE EXCEPTION 'Stage % must start after the published Stage % start time',r,r-1;
  END IF;
  IF next_at IS NOT NULL AND first_at >= next_at THEN
    RAISE EXCEPTION 'Stage % must start before the already-published Stage % start time',r,r+1;
  END IF;

  version_n := COALESCE(e.roadmap_version,0) + 1;
  INSERT INTO public.event_stage_roadmaps(
    event_id,round_number,configuration,version,published_at,published_by
  )
  VALUES (
    p_event_id,r,
    jsonb_build_object(
      'round_number',r,
      'stage_name',nm,
      'stage_type',stype,
      'group_size',gs,
      'qualifiers_per_group',q,
      'qualified_team_count',qualified,
      'direct_entry_count',direct_n,
      'matches_per_group',matches_n,
      'interval_minutes',interval_n,
      'first_match_at',first_at,
      'direct_invites',next_direct,
      'next_round_team_count',qualified + next_direct
    ),
    version_n,now(),auth.uid()
  )
  ON CONFLICT (event_id,round_number) DO UPDATE
    SET configuration = EXCLUDED.configuration,
        version = EXCLUDED.version,
        published_at = EXCLUDED.published_at,
        published_by = EXCLUDED.published_by;

  SELECT count(*) = n INTO all_published
  FROM public.event_stage_roadmaps
  WHERE event_id = p_event_id AND published_at IS NOT NULL;
  UPDATE public.events
  SET roadmap_version = version_n,
      roadmap_published_at = CASE WHEN all_published THEN now() ELSE NULL END,
      roadmap_published_by = CASE WHEN all_published THEN auth.uid() ELSE NULL END
  WHERE id = p_event_id;

  SELECT id INTO roadmap_ch
  FROM public.channels
  WHERE event_id = p_event_id AND name = 'roadmap'
    AND stage_id IS NULL AND group_id IS NULL
  ORDER BY created_at LIMIT 1;
  IF roadmap_ch IS NOT NULL THEN
    INSERT INTO public.messages(channel_id,sender_id,body)
    VALUES (
      roadmap_ch,auth.uid(),
      format('Stage %s roadmap published · v%s · %s · %s teams/group · %s matches/group · %s qualifiers/group · %s direct-entry teams',
        r,version_n,nm,gs,matches_n,q,direct_n)
    );
  END IF;

  INSERT INTO public.audit_logs(actor_id,event_id,entity_type,entity_id,action,reason,metadata)
  VALUES (
    auth.uid(),p_event_id,'event_stage',p_event_id,'event_stage_roadmap_published',
    'Published one stage roadmap independently; other stages may be published later',
    jsonb_build_object(
      'round_number',r,'stage_name',nm,'stage_type',stype,'group_size',gs,
      'qualifiers_per_group',q,'qualified_team_count',qualified,
      'direct_entry_count',direct_n,'matches_per_group',matches_n,
      'interval_minutes',interval_n,'first_match_at',first_at,
      'roadmap_version',version_n,'all_stages_published',all_published
    )
  );

  RETURN jsonb_build_object(
    'event_id',p_event_id,'round_number',r,'roadmap_version',version_n,
    'stage_published',true,'all_stages_published',all_published,
    'stage_count',n
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.publish_event_stage_roadmap(uuid,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.publish_event_stage_roadmap(uuid,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION app_private.require_published_event_stage_roadmap()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  p jsonb;
  v_plan_version integer;
BEGIN
  SELECT configuration,version INTO p,v_plan_version
  FROM public.event_stage_roadmaps
  WHERE event_id = NEW.event_id
    AND round_number = NEW.round_number
    AND published_at IS NOT NULL;

  IF p IS NULL THEN
    RAISE EXCEPTION 'Stage % has no published roadmap. Publish this stage roadmap before generating or advancing into it.',NEW.round_number;
  END IF;

  NEW.name := p->>'stage_name';
  NEW.stage_type := COALESCE(p->>'stage_type','custom');
  NEW.group_size := (p->>'group_size')::integer;
  NEW.matches_per_group := (p->>'matches_per_group')::integer;
  NEW.starts_at := (p->>'first_match_at')::timestamptz;
  NEW.advancement_rules := jsonb_build_object(
    'mode','top_per_group',
    'qualify_per_group',(p->>'qualifiers_per_group')::integer,
    'qualified_team_count',(p->>'qualified_team_count')::integer,
    'direct_entry_count',(p->>'direct_entry_count')::integer
  );
  NEW.configuration := COALESCE(NEW.configuration,'{}'::jsonb)
    || jsonb_build_object('roadmap_version',v_plan_version);
  RETURN NEW;
END;
$function$;

DO $migration$
DECLARE
  v_def text;
  v_old text;
BEGIN
  -- The internal advance helper must enforce only the source and target stage plans,
  -- not a tournament-wide "all stages published" marker.
  v_def := pg_get_functiondef(
    'app_private.advance_event_stage(uuid,text,text,integer,integer)'::regprocedure
  );
  v_old := $old$     or (select roadmap_published_at from public.events where id=v_source.event_id) is null then$old$;
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate the global roadmap gate in app_private.advance_event_stage';
  END IF;
  v_def := replace(v_def,v_old,$new$ then$new$);
  EXECUTE v_def;

  -- Advancing to Stage N requires that exact target stage to be published.
  -- It does not require every later stage in the tournament to be published.
  v_def := pg_get_functiondef(
    'public.advance_event_stage_from_roadmap(uuid,integer,integer,timestamptz)'::regprocedure
  );
  v_old := $old$SELECT count(*)::integer INTO v_stage_count FROM public.event_stage_roadmaps
   WHERE event_id=v_event.id AND published_at IS NOT NULL;
  IF v_stage_count<1 OR v_next_round>v_stage_count THEN
    RAISE EXCEPTION 'The complete published roadmap has no next stage after %',v_source.name;
  END IF;$old$;
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate the full-roadmap stage-count gate in advance_event_stage_from_roadmap';
  END IF;
  v_def := replace(v_def,v_old,$new$IF NOT EXISTS (
    SELECT 1 FROM public.event_stage_roadmaps
    WHERE event_id=v_event.id AND round_number=v_next_round AND published_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Stage % roadmap is not published. Publish that target stage before qualifying teams.',v_next_round;
  END IF;$new$);

  v_old := $old$IF v_source_roadmap IS NULL OR v_roadmap IS NULL OR v_event.roadmap_published_at IS NULL THEN$old$;
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate the global timestamp gate in advance_event_stage_from_roadmap';
  END IF;
  v_def := replace(v_def,v_old,$new$IF v_source_roadmap IS NULL OR v_roadmap IS NULL THEN$new$);
  EXECUTE v_def;

  -- Stage 1 is independently publishable. Its generation no longer waits for
  -- the global marker and includes Stage 1 direct-entry teams in Stage 1 groups.
  v_def := pg_get_functiondef(
    'public.generate_event_roadmap(uuid,integer,integer)'::regprocedure
  );
  v_old := $old$IF v_roadmap IS NULL OR v_event.roadmap_published_at IS NULL THEN$old$;
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate the global roadmap gate in generate_event_roadmap';
  END IF;
  v_def := replace(v_def,v_old,$new$IF v_roadmap IS NULL THEN$new$);

  v_old := $old$ OR COALESCE(NULLIF(v_roadmap->>'next_round_team_count','')::integer,-1) <> v_expected_qualified + v_direct_invites$old$;
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate the stale next-stage direct-entry count check in generate_event_roadmap';
  END IF;
  v_def := replace(v_def,v_old,'');

  v_old := $old$WHERE di.event_id = p_event_id AND di.team_id = er.team_id
      )
  ) ranked$old$;
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate the Stage 1 direct-entry exclusion in generate_event_roadmap';
  END IF;
  v_def := replace(v_def,v_old,$new$WHERE di.event_id = p_event_id
          AND di.team_id = er.team_id
          AND di.target_round_number > 1
      )
  ) ranked$new$);
  EXECUTE v_def;

  -- Live-stage reminders are based on the *next* stage's publication state.
  -- The final stage has no next-stage roadmap requirement.
  v_def := pg_get_functiondef(
    'app_private.dispatch_unpublished_roadmap_live_match_alerts()'::regprocedure
  );
  v_old := $old$WHERE e.roadmap_published_at IS NULL OR rm.event_id IS NULL$old$;
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate the live-match full-roadmap alert predicate';
  END IF;
  v_def := replace(v_def,v_old,$new$WHERE rm.event_id IS NULL
    OR (
      s.round_number < COALESCE(NULLIF(e.event_config->>'stage_count','')::integer,0)
      AND NOT EXISTS (
        SELECT 1 FROM public.event_stage_roadmaps next_rm
        WHERE next_rm.event_id=e.id
          AND next_rm.round_number=s.round_number+1
          AND next_rm.published_at IS NOT NULL
      )
    )$new$);

  v_old := $old$' has a live match, but the complete stage-to-stage roadmap is not published. Publish the full roadmap now.'$old$;
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate the full-roadmap live-alert copy';
  END IF;
  v_def := replace(v_def,v_old,$new$' has a live match, but the next stage roadmap is missing or unpublished. Publish that target stage roadmap before qualification.'$new$);
  EXECUTE v_def;
END;
$migration$;
