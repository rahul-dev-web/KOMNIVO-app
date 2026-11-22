-- Phase 4 correction: prevent unplaced direct-entry assignments and
-- republish every existing schedule when the complete roadmap is republished.
CREATE OR REPLACE FUNCTION public.set_event_stage_direct_invites(p_event_id uuid, p_target_round_number integer, p_team_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 e public.events%rowtype; n integer; tid uuid; reg uuid; gid uuid; m record; slot_no integer; added integer:=0;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
 IF NOT app_private.is_event_staff(p_event_id) THEN RAISE EXCEPTION 'Only authorised event staff can assign direct-entry teams'; END IF;
 SELECT * INTO e FROM public.events WHERE id=p_event_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Tournament not found'; END IF;
 n:=COALESCE(NULLIF(e.event_config->>'stage_count','')::integer,0);
 IF p_target_round_number IS NULL OR p_target_round_number<1 OR p_target_round_number>n THEN RAISE EXCEPTION 'Choose a stage between 1 and %',n; END IF;
 IF COALESCE(cardinality(p_team_ids),0)=0 OR (SELECT count(DISTINCT x)::integer FROM unnest(p_team_ids) AS x)<>cardinality(p_team_ids) THEN RAISE EXCEPTION 'Select one or more unique teams'; END IF;
 IF EXISTS(SELECT 1 FROM public.matches WHERE event_id=p_event_id AND round_number=p_target_round_number
  AND status IN ('check_in','room_setup','lobby_review','live','awaiting_result','review','completed')) THEN
  RAISE EXCEPTION 'Target stage has started or has results; direct-entry changes are locked';
 END IF;
 FOREACH tid IN ARRAY p_team_ids LOOP
  SELECT er.id INTO reg FROM public.event_registrations er JOIN public.teams t ON t.id=er.team_id
   WHERE er.event_id=p_event_id AND er.team_id=tid AND er.status IN ('approved','checked_in')
    AND er.roster_locked AND t.game_id=e.game_id ORDER BY er.registered_at DESC LIMIT 1;
  IF reg IS NULL THEN RAISE EXCEPTION 'Direct-entry teams require approved, roster-locked registration for this event and game'; END IF;
  IF EXISTS(SELECT 1 FROM public.event_groups g JOIN public.event_rounds r ON r.id=g.round_id
    JOIN public.event_group_teams gt ON gt.group_id=g.id WHERE r.event_id=p_event_id
     AND r.round_number=p_target_round_number AND gt.team_id=tid) THEN
   RAISE EXCEPTION 'Team is already assigned to target stage';
  END IF;
  IF EXISTS(SELECT 1 FROM public.matches m JOIN public.match_participants mp ON mp.match_id=m.id
    WHERE m.event_id=p_event_id AND m.round_number<>p_target_round_number AND mp.team_id=tid
      AND m.status IN ('check_in','room_setup','lobby_review','live','awaiting_result','review','completed')) THEN
   RAISE EXCEPTION 'Team has entered match operations in another stage and cannot be moved';
  END IF;
  IF EXISTS(SELECT 1 FROM public.event_group_teams gt JOIN public.event_groups g ON g.id=gt.group_id
    JOIN public.event_rounds r ON r.id=g.round_id WHERE r.event_id=p_event_id
      AND r.round_number<>p_target_round_number AND gt.team_id=tid
      AND (SELECT count(*) FROM public.event_group_teams other WHERE other.group_id=g.id)<=2) THEN
   RAISE EXCEPTION 'Moving this team would leave an earlier group with fewer than two teams';
  END IF;

  DELETE FROM public.match_participants mp USING public.matches m
   WHERE m.id=mp.match_id AND m.event_id=p_event_id AND m.round_number<>p_target_round_number
    AND mp.team_id=tid AND m.status IN ('scheduled','cancelled');
  DELETE FROM public.channel_members cm USING public.channels c
   WHERE c.id=cm.channel_id AND c.event_id=p_event_id
    AND c.group_id IN (SELECT g.id FROM public.event_groups g JOIN public.event_rounds r ON r.id=g.round_id
      JOIN public.event_group_teams gt ON gt.group_id=g.id
      WHERE r.event_id=p_event_id AND r.round_number<>p_target_round_number AND gt.team_id=tid)
    AND cm.user_id IN (SELECT tm.user_id FROM public.team_members tm WHERE tm.team_id=tid
      UNION SELECT t.owner_user_id FROM public.teams t WHERE t.id=tid);
  DELETE FROM public.event_group_teams gt USING public.event_groups g,public.event_rounds r
   WHERE g.id=gt.group_id AND r.id=g.round_id AND r.event_id=p_event_id
    AND r.round_number<>p_target_round_number AND gt.team_id=tid;
  DELETE FROM public.event_stage_direct_invites WHERE event_id=p_event_id AND team_id=tid;
  INSERT INTO public.event_stage_direct_invites(event_id,team_id,target_round_number,assigned_by)
   VALUES(p_event_id,tid,p_target_round_number,auth.uid());

  SELECT g.id INTO gid FROM public.event_groups g JOIN public.event_rounds r ON r.id=g.round_id
   LEFT JOIN public.event_group_teams gt ON gt.group_id=g.id
   WHERE r.event_id=p_event_id AND r.round_number=p_target_round_number
   GROUP BY g.id,g.sort_order HAVING count(gt.team_id)<24 ORDER BY count(gt.team_id),g.sort_order LIMIT 1;
  IF gid IS NOT NULL THEN
   INSERT INTO public.event_group_teams(group_id,team_id,seeded_by) VALUES(gid,tid,auth.uid());
   FOR m IN SELECT id FROM public.matches WHERE event_id=p_event_id AND round_number=p_target_round_number
    AND group_id=gid AND status='scheduled'
   LOOP
    SELECT s INTO slot_no FROM generate_series(1,24)s
     WHERE NOT EXISTS(SELECT 1 FROM public.match_participants mp WHERE mp.match_id=m.id AND mp.slot_number=s)
     ORDER BY s LIMIT 1;
    IF slot_no IS NULL THEN RAISE EXCEPTION 'No free slot remains in target-stage match'; END IF;
    INSERT INTO public.match_participants(match_id,team_id,registration_id,slot_number) VALUES(m.id,tid,reg,slot_no);
   END LOOP;
  ELSIF EXISTS(SELECT 1 FROM public.event_rounds WHERE event_id=p_event_id AND round_number=p_target_round_number) THEN
   RAISE EXCEPTION 'Target stage groups are full; increase group capacity before assigning this team';
  END IF;
  added:=added+1;
 END LOOP;
 UPDATE public.events SET roadmap_published_at=NULL,roadmap_published_by=NULL WHERE id=p_event_id;
 UPDATE public.event_rounds SET schedule_published_at=NULL,schedule_published_by=NULL,status='draft'
  WHERE event_id=p_event_id AND round_number=p_target_round_number;
 INSERT INTO public.audit_logs(actor_id,event_id,entity_type,entity_id,action,reason,metadata)
 VALUES(auth.uid(),p_event_id,'event',p_event_id,'roadmap_direct_entry_assigned',
  'Organiser moved/assigned direct-entry teams to selected stage',
  jsonb_build_object('target_round_number',p_target_round_number,'team_ids',to_jsonb(p_team_ids),'team_count',added));
 RETURN jsonb_build_object('event_id',p_event_id,'target_round_number',p_target_round_number,
  'assigned_count',added,'team_ids',to_jsonb(p_team_ids),'republish_required',true);
END;$function$;

CREATE OR REPLACE FUNCTION public.publish_event_roadmap(p_event_id uuid, p_stage_configs jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE e public.events%rowtype; n integer; s jsonb; r integer; nm text; gs integer; q integer; qualified integer; direct_n integer; matches_n integer; interval_n integer; first_at timestamptz; previous_at timestamptz; assigned integer; version_n integer; summary text:=''; next_direct integer; roadmap_ch uuid; sid uuid;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
 IF NOT app_private.is_event_staff(p_event_id) THEN RAISE EXCEPTION 'Only event staff can publish the entire roadmap'; END IF;
 SELECT * INTO e FROM public.events WHERE id=p_event_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Tournament not found'; END IF;
 n:=COALESCE(NULLIF(e.event_config->>'stage_count','')::integer,0);
 IF n<1 OR n>16 OR jsonb_typeof(p_stage_configs)<>'array' OR jsonb_array_length(p_stage_configs)<>n THEN RAISE EXCEPTION 'Submit all % stages in order in one publication',n; END IF;
 IF EXISTS(SELECT 1 FROM public.matches WHERE event_id=p_event_id AND status IN ('live','awaiting_result','review','completed')) THEN RAISE EXCEPTION 'Cannot replace a roadmap after a stage match starts or results exist'; END IF;
 version_n:=e.roadmap_version+1; DELETE FROM public.event_stage_roadmaps WHERE event_id=p_event_id;
 FOR s IN SELECT value FROM jsonb_array_elements(p_stage_configs) LOOP
  r:=NULLIF(s->>'round_number','')::integer; nm:=NULLIF(trim(s->>'stage_name'),''); gs:=NULLIF(s->>'group_size','')::integer; q:=NULLIF(s->>'qualifiers_per_group','')::integer;
  qualified:=NULLIF(s->>'qualified_team_count','')::integer; direct_n:=COALESCE(NULLIF(s->>'direct_entry_count','')::integer,0);
  matches_n:=NULLIF(s->>'matches_per_group','')::integer; interval_n:=NULLIF(s->>'interval_minutes','')::integer; first_at:=NULLIF(s->>'first_match_at','')::timestamptz;
  IF r IS NULL OR r<>(SELECT count(*)+1 FROM public.event_stage_roadmaps WHERE event_id=p_event_id)
   OR nm IS NULL OR char_length(nm) NOT BETWEEN 2 AND 80 OR gs IS NULL OR gs NOT BETWEEN 2 AND 24
   OR q IS NULL OR q NOT BETWEEN 0 AND gs OR qualified IS NULL OR qualified<0 OR direct_n<0
   OR matches_n IS NULL OR matches_n NOT BETWEEN 1 AND 20 OR interval_n IS NULL OR interval_n NOT BETWEEN 1 AND 240
   OR first_at IS NULL OR first_at<=now() OR (previous_at IS NOT NULL AND first_at<=previous_at) THEN
   RAISE EXCEPTION 'Stage % has missing or invalid roadmap settings',r;
  END IF;
  IF r<n AND q<1 THEN RAISE EXCEPTION 'Every non-final stage needs a qualification count'; END IF;
  IF r=n AND q<>0 THEN RAISE EXCEPTION 'Final stage qualifiers_per_group must be 0'; END IF;
  SELECT count(*)::integer INTO assigned FROM public.event_stage_direct_invites WHERE event_id=p_event_id AND target_round_number=r;
  IF assigned<>direct_n THEN RAISE EXCEPTION 'Stage % expects % direct-entry teams but % are assigned',r,direct_n,assigned; END IF;
  next_direct:=CASE WHEN r<n THEN COALESCE(NULLIF(p_stage_configs->r->>'direct_entry_count','')::integer,0) ELSE 0 END;
  INSERT INTO public.event_stage_roadmaps(event_id,round_number,configuration,version,published_at,published_by)
  VALUES(p_event_id,r,jsonb_build_object('round_number',r,'stage_name',nm,'stage_type',COALESCE(NULLIF(s->>'stage_type',''),'custom'),
   'group_size',gs,'qualifiers_per_group',q,'qualified_team_count',qualified,'direct_entry_count',direct_n,
   'matches_per_group',matches_n,'interval_minutes',interval_n,'first_match_at',first_at,
   'direct_invites',next_direct,'next_round_team_count',qualified+next_direct),version_n,now(),auth.uid());
  summary:=summary||CASE WHEN summary='' THEN '' ELSE E'\n' END||format('%s. %s · group %s · matches %s · qualify %s · direct %s',r,nm,gs,matches_n,q,direct_n);
  previous_at:=first_at;
 END LOOP;
 UPDATE public.events SET roadmap_published_at=now(),roadmap_published_by=auth.uid(),roadmap_version=version_n WHERE id=p_event_id;
 SELECT id INTO roadmap_ch FROM public.channels WHERE event_id=p_event_id AND name='roadmap' AND stage_id IS NULL AND group_id IS NULL ORDER BY created_at LIMIT 1;
 IF roadmap_ch IS NULL THEN RAISE EXCEPTION 'Tournament roadmap channel is missing'; END IF;
 INSERT INTO public.messages(channel_id,sender_id,body) VALUES(roadmap_ch,auth.uid(),'Complete tournament roadmap published · v'||version_n||E'\n'||summary);
 FOR sid IN SELECT r.id FROM public.event_rounds r WHERE r.event_id=p_event_id
  AND EXISTS(SELECT 1 FROM public.matches m WHERE m.stage_id=r.id) AND r.schedule_published_at IS NULL ORDER BY r.round_number
 LOOP PERFORM public.publish_event_stage_schedule(sid); END LOOP;
 INSERT INTO public.audit_logs(actor_id,event_id,entity_type,entity_id,action,reason,metadata)
 VALUES(auth.uid(),p_event_id,'event',p_event_id,'complete_event_roadmap_published','Complete stage-to-stage roadmap published in one action',
  jsonb_build_object('roadmap_version',version_n,'stage_count',n,'summary',summary));
 RETURN jsonb_build_object('event_id',p_event_id,'roadmap_version',version_n,'stage_count',n,'roadmap_published',true);
END;$function$;

CREATE OR REPLACE FUNCTION public.generate_event_roadmap(p_event_id uuid, p_matches_per_group integer, p_interval_minutes integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_event public.events%ROWTYPE;
  v_roadmap jsonb;
  v_stage_count integer;
  v_stage_names jsonb;
  v_group_size integer;
  v_qualify_per_group integer;
  v_expected_qualified integer;
  v_direct_invites integer;
  v_registered_team_count integer;
  v_team_count integer;
  v_group_count integer;
  v_stage_id uuid;
  v_stage_name text;
  v_first_match_at timestamptz;
  v_result jsonb;
  v_assigned_invites integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF NOT app_private.is_event_staff(p_event_id) THEN
    RAISE EXCEPTION 'Only authorised event staff can generate the roadmap';
  END IF;
  IF p_matches_per_group < 1 OR p_matches_per_group > 20
     OR p_interval_minutes < 1 OR p_interval_minutes > 240 THEN
    RAISE EXCEPTION 'Matches per group must be 1-20 and interval must be 1-240 minutes';
  END IF;

  SELECT * INTO v_event FROM public.events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Event not found'; END IF;
  IF v_event.format = 'solo' THEN
    RAISE EXCEPTION 'Automatic team-group roadmap currently supports Duo, Squad or Custom team formats';
  END IF;

  v_stage_count := NULLIF(v_event.event_config->>'stage_count','')::integer;
  v_stage_names := COALESCE(v_event.event_config->'stage_names','[]'::jsonb);
  SELECT configuration INTO v_roadmap FROM public.event_stage_roadmaps
   WHERE event_id=p_event_id AND round_number=1 AND published_at IS NOT NULL;
  IF v_roadmap IS NULL OR v_event.roadmap_published_at IS NULL THEN
    RAISE EXCEPTION 'Publish the complete stage-to-stage roadmap before generating Stage 1';
  END IF;
  IF v_stage_count IS NULL OR v_stage_count < 1 OR v_stage_count > 16
     OR jsonb_typeof(v_roadmap) <> 'object' THEN
    RAISE EXCEPTION 'Complete the saved stage count and roadmap before generating groups';
  END IF;

  v_group_size := NULLIF(v_roadmap->>'group_size','')::integer;
  v_qualify_per_group := NULLIF(v_roadmap->>'qualifiers_per_group','')::integer;
  v_expected_qualified := NULLIF(v_roadmap->>'qualified_team_count','')::integer;
  SELECT count(*)::integer INTO v_direct_invites FROM public.event_stage_direct_invites
   WHERE event_id=p_event_id AND target_round_number=2;
  IF v_group_size IS NULL OR v_group_size < 2 OR v_group_size > 24
     OR v_qualify_per_group IS NULL OR v_qualify_per_group < 1 OR v_qualify_per_group > v_group_size
     OR v_expected_qualified IS NULL OR v_expected_qualified < 0 OR v_direct_invites < 0
     OR COALESCE(NULLIF(v_roadmap->>'next_round_team_count','')::integer,-1) <> v_expected_qualified + v_direct_invites THEN
    RAISE EXCEPTION 'Saved roadmap values are invalid for automatic generation';
  END IF;
  IF v_direct_invites > 0 AND v_stage_count < 2 THEN
    RAISE EXCEPTION 'Direct-entry teams require a later stage';
  END IF;

  SELECT count(DISTINCT er.team_id)::integer INTO v_registered_team_count
  FROM public.event_registrations er
  WHERE er.event_id = p_event_id
    AND er.status IN ('approved','checked_in')
    AND er.roster_locked AND er.team_id IS NOT NULL;

  SELECT count(*)::integer INTO v_assigned_invites
  FROM public.event_stage_direct_invites
  WHERE event_id = p_event_id AND target_round_number = 2;

  IF v_assigned_invites <> v_direct_invites THEN
    RAISE EXCEPTION 'Select exactly % direct-entry teams in Event Operations before generating the roadmap; % currently assigned',
      v_direct_invites,v_assigned_invites;
  END IF;

  SELECT count(DISTINCT er.team_id)::integer INTO v_team_count
  FROM public.event_registrations er
  WHERE er.event_id = p_event_id
    AND er.status IN ('approved','checked_in')
    AND er.roster_locked AND er.team_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.event_stage_direct_invites di
      WHERE di.event_id = p_event_id AND di.team_id = er.team_id
        AND di.target_round_number > 1
    );

  IF v_team_count < 2 THEN
    RAISE EXCEPTION 'At least two approved, roster-locked teams must enter stage one after direct-entry teams are excluded';
  END IF;

  v_group_count := ceil(v_team_count::numeric / v_group_size)::integer;
  IF v_team_count < v_group_count * 2 THEN
    RAISE EXCEPTION 'The stage-one roster would create a group with fewer than two teams. Adjust the group size first.';
  END IF;
  IF v_group_count * v_qualify_per_group <> v_expected_qualified THEN
    RAISE EXCEPTION 'Roadmap mismatch: % groups × % qualifiers = %, but the saved roadmap expects % qualified teams',
      v_group_count,v_qualify_per_group,v_group_count * v_qualify_per_group,v_expected_qualified;
  END IF;

  SELECT id INTO v_stage_id
  FROM public.event_rounds WHERE event_id = p_event_id AND round_number = 1
  FOR UPDATE;
  IF v_stage_id IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM public.matches WHERE stage_id = v_stage_id) THEN
      RETURN jsonb_build_object(
        'already_generated',true,'stage_id',v_stage_id,
        'message','Stage one already has generated matches; existing roadmap was preserved.'
      );
    END IF;
    IF EXISTS (SELECT 1 FROM public.event_groups WHERE round_id = v_stage_id) THEN
      RAISE EXCEPTION 'Stage one has a partial group setup. Existing rows were preserved; review it before retrying.';
    END IF;
    RAISE EXCEPTION 'Stage one already exists without generated groups. Review the draft stage before retrying.';
  END IF;

  v_stage_name := COALESCE(NULLIF(v_roadmap->>'stage_name',''),
    NULLIF(trim(v_stage_names->>0),''),CASE WHEN v_stage_count=1 THEN 'Final' ELSE 'Stage 1' END);
  IF p_matches_per_group <> (v_roadmap->>'matches_per_group')::integer
     OR p_interval_minutes <> (v_roadmap->>'interval_minutes')::integer THEN
    RAISE EXCEPTION 'Stage 1 match settings differ from the published roadmap';
  END IF;
  v_first_match_at := (v_roadmap->>'first_match_at')::timestamptz;
  IF v_first_match_at IS NULL OR v_first_match_at <= now() THEN
    RAISE EXCEPTION 'Tournament start time must still be in the future before the initial schedule is generated';
  END IF;

  INSERT INTO public.event_rounds(
    event_id,round_number,name,status,starts_at,stage_type,group_size,
    matches_per_group,advancement_rules,configuration,room_release_minutes_before
  ) VALUES (
    p_event_id,1,v_stage_name,'draft',v_first_match_at,
    CASE WHEN v_stage_count = 1 THEN 'final' ELSE 'qualifier' END,
    v_group_size,p_matches_per_group,
    jsonb_build_object('mode','top_per_group','qualify_per_group',v_qualify_per_group,
      'qualified_team_count',v_expected_qualified,'direct_invites',v_direct_invites),
    jsonb_build_object('source','events.event_config','interval_minutes',p_interval_minutes,
      'first_match_at',v_first_match_at,'roadmap_version',COALESCE(v_event.event_config->>'schema_version','1'),
      'direct_invite_team_count',v_direct_invites),
    10
  ) RETURNING id INTO v_stage_id;

  INSERT INTO public.event_groups(round_id,label,sort_order)
  SELECT v_stage_id,'Group ' || n,n
  FROM generate_series(1,v_group_count) n;

  INSERT INTO public.event_group_teams(group_id,team_id,seeded_by)
  SELECT g.id, ranked.team_id, auth.uid()
  FROM (
    SELECT er.team_id,
      ntile(v_group_count) OVER (ORDER BY er.registered_at,er.team_id) AS group_number
    FROM public.event_registrations er
    WHERE er.event_id = p_event_id
      AND er.status IN ('approved','checked_in')
      AND er.roster_locked AND er.team_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.event_stage_direct_invites di
        WHERE di.event_id = p_event_id AND di.team_id = er.team_id
      )
  ) ranked
  JOIN public.event_groups g
    ON g.round_id = v_stage_id AND g.sort_order = ranked.group_number;

  v_result := app_private.generate_event_stage_matches(
    v_stage_id,p_matches_per_group,p_interval_minutes,v_first_match_at
  );

  INSERT INTO public.audit_logs(actor_id,event_id,entity_type,entity_id,action,reason,metadata)
  VALUES (
    auth.uid(),p_event_id,'event_stage',v_stage_id,'roadmap_stage_one_generated',
    'Generated from the organiser-approved event_config roadmap',
    jsonb_build_object('group_size',v_group_size,'qualify_per_group',v_qualify_per_group,
      'registered_teams',v_registered_team_count,'grouped_stage_one_teams',v_team_count,
      'direct_invite_count',v_direct_invites,'group_count',v_group_count,
      'matches_per_group',p_matches_per_group,'interval_minutes',p_interval_minutes,
      'matches_created',v_result->'matches_created','stage_name',v_stage_name)
  );

  RETURN v_result || jsonb_build_object('stage_id',v_stage_id,'stage_name',v_stage_name,
    'qualified_team_count',v_expected_qualified,'direct_invite_count',v_direct_invites,
    'schedule_published',true);
END;
$function$;
