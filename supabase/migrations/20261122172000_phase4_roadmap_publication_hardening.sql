-- Phase 4 hardening: initial-stage direct invites belong to later rounds;
-- confirm the approved qualifier count before creating the next round; keep
-- the public schedule-channel summary compact while full fixtures are group-scoped.

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
  v_team_count integer;
  v_group_count integer;
  v_stage_id uuid;
  v_stage_name text;
  v_first_match_at timestamptz;
  v_group record;
  v_result jsonb;
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
  v_roadmap := v_event.event_config->'roadmap';
  IF v_stage_count IS NULL OR v_stage_count < 1 OR v_stage_count > 16
     OR jsonb_typeof(v_roadmap) <> 'object' THEN
    RAISE EXCEPTION 'Complete the saved stage count and roadmap before generating groups';
  END IF;

  v_group_size := NULLIF(v_roadmap->>'group_size','')::integer;
  v_qualify_per_group := NULLIF(v_roadmap->>'qualifiers_per_group','')::integer;
  v_expected_qualified := NULLIF(v_roadmap->>'qualified_team_count','')::integer;
  v_direct_invites := COALESCE(NULLIF(v_roadmap->>'direct_invites','')::integer,0);
  IF v_group_size IS NULL OR v_group_size < 2 OR v_group_size > 24
     OR v_qualify_per_group IS NULL OR v_qualify_per_group < 1 OR v_qualify_per_group > v_group_size
     OR v_expected_qualified IS NULL OR v_expected_qualified < 0 OR v_direct_invites < 0
     OR COALESCE(NULLIF(v_roadmap->>'next_round_team_count','')::integer,-1) <> v_expected_qualified + v_direct_invites THEN
    RAISE EXCEPTION 'Saved roadmap values are invalid for automatic generation';
  END IF;

  SELECT count(*)::integer INTO v_team_count
  FROM public.event_registrations
  WHERE event_id = p_event_id
    AND status IN ('approved','checked_in')
    AND roster_locked AND team_id IS NOT NULL;
  IF v_team_count < 2 THEN
    RAISE EXCEPTION 'Approve at least two team registrations and lock their rosters first';
  END IF;

  v_group_count := ceil(v_team_count::numeric / v_group_size)::integer;
  IF v_group_count * v_qualify_per_group <> v_expected_qualified THEN
    RAISE EXCEPTION 'Roadmap mismatch: % groups × % qualifiers = %, but the saved roadmap expects % qualified teams',
      v_group_count,v_qualify_per_group,v_group_count * v_qualify_per_group,v_expected_qualified;
  END IF;

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

  v_stage_name := COALESCE(
    NULLIF(trim(v_stage_names->>0),''),
    CASE WHEN v_stage_count = 1 THEN 'Final' ELSE 'Stage 1' END
  );
  v_first_match_at := v_event.starts_at;
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
      'first_match_at',v_first_match_at,'roadmap_version',COALESCE(v_event.event_config->>'schema_version','1')),
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
      'registered_teams',v_team_count,'group_count',v_group_count,
      'matches_per_group',p_matches_per_group,'interval_minutes',p_interval_minutes,
      'matches_created',v_result->'matches_created','stage_name',v_stage_name)
  );

  RETURN v_result || jsonb_build_object('stage_id',v_stage_id,'stage_name',v_stage_name,
    'qualified_team_count',v_expected_qualified,'schedule_published',false);
END;
$function$


CREATE OR REPLACE FUNCTION public.advance_event_stage_from_roadmap(p_source_stage_id uuid, p_matches_per_group integer, p_interval_minutes integer, p_first_match_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_source public.event_rounds%ROWTYPE;
  v_event public.events%ROWTYPE;
  v_roadmap jsonb;
  v_names jsonb;
  v_stage_count integer;
  v_next_round integer;
  v_group_size integer;
  v_qualify integer;
  v_direct_invites integer;
  v_stage_name text;
  v_advanced jsonb;
  v_matches jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT * INTO v_source FROM public.event_rounds WHERE id = p_source_stage_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Source stage not found'; END IF;
  IF NOT app_private.is_event_staff(v_source.event_id) THEN
    RAISE EXCEPTION 'Only authorised event staff can advance a stage';
  END IF;
  IF p_matches_per_group < 1 OR p_matches_per_group > 20
     OR p_interval_minutes < 1 OR p_interval_minutes > 240
     OR p_first_match_at IS NULL OR p_first_match_at <= now() THEN
    RAISE EXCEPTION 'Enter 1-20 matches, a 1-240 minute interval and a future first-match time';
  END IF;
  SELECT * INTO v_event FROM public.events WHERE id = v_source.event_id;
  v_roadmap := v_event.event_config->'roadmap';
  v_names := COALESCE(v_event.event_config->'stage_names','[]'::jsonb);
  v_stage_count := NULLIF(v_event.event_config->>'stage_count','')::integer;
  v_next_round := v_source.round_number + 1;
  IF v_stage_count IS NULL OR v_next_round > v_stage_count THEN
    RAISE EXCEPTION 'The saved roadmap has no additional stage after %',v_source.name;
  END IF;
  v_group_size := NULLIF(v_roadmap->>'group_size','')::integer;
  v_qualify := NULLIF(v_roadmap->>'qualifiers_per_group','')::integer;
  v_direct_invites := COALESCE(NULLIF(v_roadmap->>'direct_invites','')::integer,0);
  IF v_group_size IS NULL OR v_group_size < 2 OR v_group_size > 24
     OR v_qualify IS NULL OR v_qualify < 1 OR v_qualify > 24 THEN
    RAISE EXCEPTION 'The saved roadmap group/qualification settings are incomplete';
  END IF;
  IF v_direct_invites > 0 THEN
    RAISE EXCEPTION 'The next stage requires % direct invite slots. Explicit team assignment is required before automatic advancement.',v_direct_invites;
  END IF;
  IF EXISTS (SELECT 1 FROM public.event_rounds WHERE event_id = v_event.id AND round_number = v_next_round) THEN
    RAISE EXCEPTION 'The next stage already exists; it will not be overwritten';
  END IF;

  v_stage_name := COALESCE(NULLIF(trim(v_names->>(v_next_round - 1)),''),'Stage '||v_next_round);
  v_advanced := app_private.advance_event_stage(
    p_source_stage_id,v_stage_name,
    CASE WHEN v_next_round = v_stage_count THEN 'final' ELSE 'qualifier' END,
    v_group_size,v_qualify
  );
  IF COALESCE((v_advanced->>'qualified_team_count')::integer,0)
       <> COALESCE(NULLIF(v_roadmap->>'qualified_team_count','')::integer,-1) THEN
    RAISE EXCEPTION 'Approved standings qualify % teams, but the saved roadmap expects %; review the qualification configuration.',
      COALESCE((v_advanced->>'qualified_team_count')::integer,0),
      NULLIF(v_roadmap->>'qualified_team_count','')::integer;
  END IF;
  v_matches := app_private.generate_event_stage_matches(
    (v_advanced->>'target_stage_id')::uuid,
    p_matches_per_group,p_interval_minutes,p_first_match_at
  );
  RETURN v_advanced || v_matches || jsonb_build_object(
    'stage_name',v_stage_name,'schedule_published',false
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.publish_event_stage_schedule(p_stage_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_stage public.event_rounds%ROWTYPE;
  v_event public.events%ROWTYPE;
  v_schedule_channel uuid;
  v_actor uuid := auth.uid();
  v_version integer;
  v_match_count integer;
  v_team record;
  v_group record;
  v_body text;
  v_group_body text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT * INTO v_stage FROM public.event_rounds WHERE id = p_stage_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tournament stage not found'; END IF;
  IF NOT app_private.is_event_staff(v_stage.event_id) THEN
    RAISE EXCEPTION 'Only authorised event staff can publish the stage schedule';
  END IF;
  SELECT * INTO v_event FROM public.events WHERE id = v_stage.event_id;
  SELECT count(*)::integer INTO v_match_count
  FROM public.matches WHERE stage_id = p_stage_id AND status <> 'cancelled';
  IF v_match_count = 0 THEN RAISE EXCEPTION 'Generate at least one match before publishing the schedule'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.matches
    WHERE stage_id = p_stage_id AND status <> 'cancelled' AND starts_at IS NULL
  ) THEN RAISE EXCEPTION 'Every scheduled match needs a start time before publication'; END IF;

  UPDATE public.event_rounds
  SET schedule_published_at = now(),
      schedule_published_by = v_actor,
      schedule_version = schedule_version + 1,
      status = 'published'
  WHERE id = p_stage_id
  RETURNING schedule_version INTO v_version;

  SELECT id INTO v_schedule_channel FROM public.channels
  WHERE event_id = v_event.id AND name = 'schedule' AND stage_id IS NULL AND group_id IS NULL
  ORDER BY created_at LIMIT 1;

  v_body := 'Schedule published · ' || v_stage.name || ' · version ' || v_version ||
    E'\\n' || v_match_count || ' matches across ' ||
    (SELECT count(*) FROM public.event_groups WHERE round_id = p_stage_id) ||
    ' groups. Detailed match times are posted in each private group IDP channel.';

  IF v_schedule_channel IS NOT NULL THEN
    INSERT INTO public.messages(channel_id,sender_id,body)
    VALUES(v_schedule_channel,v_actor,v_body);
  END IF;

  FOR v_group IN
    SELECT g.id,g.label,g.sort_order,c.id AS idp_channel_id
    FROM public.event_groups g
    LEFT JOIN public.channels c
      ON c.group_id = g.id AND lower(c.name) LIKE '%-idp'
    WHERE g.round_id = p_stage_id
    ORDER BY g.sort_order
  LOOP
    v_group_body := 'Group schedule · ' || v_stage.name || ' · version ' || v_version || E'\n' ||
      COALESCE((
        SELECT string_agg(
          COALESCE(m.match_code,'Match '||m.match_number) || ' — ' ||
          to_char(m.starts_at AT TIME ZONE 'Asia/Kolkata','DD Mon YYYY, HH12:MI AM') || ' IST',
          E'\n' ORDER BY m.group_match_number,m.match_number
        )
        FROM public.matches m
        WHERE m.stage_id = p_stage_id AND m.group_id = v_group.id AND m.status <> 'cancelled'
      ),'No matches');
    IF v_group.idp_channel_id IS NOT NULL THEN
      INSERT INTO public.messages(channel_id,sender_id,body)
      VALUES(v_group.idp_channel_id,v_actor,v_group_body);
    END IF;
  END LOOP;

  FOR v_team IN
    SELECT DISTINCT scheduled.match_id,scheduled.team_id
    FROM (
      SELECT mp.match_id,mp.team_id
      FROM public.match_participants mp
      JOIN public.matches m ON m.id = mp.match_id
      WHERE m.stage_id = p_stage_id AND m.status <> 'cancelled'
      UNION
      SELECT m.id,egt.team_id
      FROM public.matches m
      JOIN public.event_group_teams egt ON egt.group_id = m.group_id
      WHERE m.stage_id = p_stage_id AND m.status <> 'cancelled'
    ) scheduled
  LOOP
    PERFORM app_private.notify_match_schedule(v_team.match_id,v_team.team_id);
  END LOOP;

  INSERT INTO public.audit_logs(actor_id,event_id,entity_type,entity_id,action,reason,metadata)
  VALUES(
    v_actor,v_event.id,'event_stage',p_stage_id,'stage_schedule_published',
    CASE WHEN v_version = 1 THEN 'Organiser published the generated roadmap schedule'
         ELSE 'Organiser published a corrected roadmap schedule' END,
    jsonb_build_object('schedule_version',v_version,'matches',v_match_count,
      'targeted_team_count',(SELECT count(DISTINCT team_id) FROM (
        SELECT mp.team_id FROM public.match_participants mp JOIN public.matches m ON m.id=mp.match_id WHERE m.stage_id=p_stage_id
        UNION SELECT egt.team_id FROM public.matches m JOIN public.event_group_teams egt ON egt.group_id=m.group_id WHERE m.stage_id=p_stage_id
      ) t))
  );

  RETURN jsonb_build_object('stage_id',p_stage_id,'schedule_version',v_version,
    'matches_published',v_match_count,'schedule_published',true);
END;
$function$;
