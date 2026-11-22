-- Phase 4 completion: explicit, auditable direct-entry team selection.
-- Direct-entry teams are approved, roster-locked event registrations. They skip
-- round one and are inserted alongside approved qualifiers into round two.
-- No team is inferred and all writes are server-authorised.

CREATE TABLE IF NOT EXISTS public.event_stage_direct_invites (
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  team_id uuid NOT NULL REFERENCES public.teams(id) ON DELETE CASCADE,
  target_round_number integer NOT NULL DEFAULT 2 CHECK (target_round_number = 2),
  assigned_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, team_id)
);

CREATE INDEX IF NOT EXISTS event_stage_direct_invites_team_idx
  ON public.event_stage_direct_invites(team_id, event_id);

ALTER TABLE public.event_stage_direct_invites ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS event_stage_direct_invites_read_staff
  ON public.event_stage_direct_invites;
CREATE POLICY event_stage_direct_invites_read_staff
  ON public.event_stage_direct_invites
  FOR SELECT TO authenticated
  USING (app_private.is_event_staff(event_id));
REVOKE ALL ON public.event_stage_direct_invites FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.event_stage_direct_invites TO authenticated;
GRANT ALL ON public.event_stage_direct_invites TO service_role;

CREATE OR REPLACE FUNCTION public.set_event_stage_direct_invites(
  p_event_id uuid,
  p_team_ids uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event public.events%ROWTYPE;
  v_expected integer;
  v_requested integer;
  v_distinct integer;
  v_valid integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF NOT app_private.is_event_staff(p_event_id) THEN
    RAISE EXCEPTION 'Only authorised event staff can assign direct-entry teams';
  END IF;

  SELECT * INTO v_event FROM public.events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tournament not found'; END IF;

  v_expected := COALESCE(NULLIF(v_event.event_config #>> '{roadmap,direct_invites}','')::integer,0);
  IF v_expected < 0 THEN RAISE EXCEPTION 'Saved direct-entry count is invalid'; END IF;
  IF COALESCE(NULLIF(v_event.event_config->>'stage_count','')::integer,0) < 2 AND v_expected > 0 THEN
    RAISE EXCEPTION 'Direct-entry teams require at least two tournament stages';
  END IF;

  v_requested := COALESCE(cardinality(p_team_ids),0);
  SELECT count(DISTINCT team_id)::integer INTO v_distinct
  FROM unnest(COALESCE(p_team_ids,ARRAY[]::uuid[])) AS selected(team_id);
  IF v_requested <> v_distinct THEN
    RAISE EXCEPTION 'A team can only be selected once for direct entry';
  END IF;
  IF v_requested <> v_expected THEN
    RAISE EXCEPTION 'Select exactly % direct-entry teams; received %',v_expected,v_requested;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.event_rounds r
    WHERE r.event_id = p_event_id AND r.round_number = 1
  ) THEN
    RAISE EXCEPTION 'Direct-entry assignments are locked once the first stage has been generated';
  END IF;

  SELECT count(DISTINCT er.team_id)::integer INTO v_valid
  FROM public.event_registrations er
  JOIN public.teams t ON t.id = er.team_id
  JOIN unnest(COALESCE(p_team_ids,ARRAY[]::uuid[])) AS selected(team_id)
    ON selected.team_id = er.team_id
  WHERE er.event_id = p_event_id
    AND er.status IN ('approved','checked_in')
    AND er.roster_locked = true
    AND t.game_id = v_event.game_id;

  IF v_valid <> v_expected THEN
    RAISE EXCEPTION 'Every direct-entry team must have an approved, roster-locked registration for this event and the same game';
  END IF;

  DELETE FROM public.event_stage_direct_invites WHERE event_id = p_event_id;
  INSERT INTO public.event_stage_direct_invites(event_id,team_id,target_round_number,assigned_by)
  SELECT p_event_id,selected.team_id,2,auth.uid()
  FROM unnest(COALESCE(p_team_ids,ARRAY[]::uuid[])) AS selected(team_id);

  INSERT INTO public.audit_logs(
    actor_id,event_id,entity_type,entity_id,action,reason,metadata
  ) VALUES (
    auth.uid(),p_event_id,'event',p_event_id,
    'roadmap_direct_entry_teams_assigned',
    'Organiser explicitly selected registered teams to bypass stage one',
    jsonb_build_object('target_round',2,'team_ids',COALESCE(to_jsonb(p_team_ids),'[]'::jsonb),
      'team_count',v_requested)
  );

  RETURN jsonb_build_object(
    'event_id',p_event_id,'target_round',2,'direct_invite_count',v_requested,
    'team_ids',COALESCE(to_jsonb(p_team_ids),'[]'::jsonb)
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.set_event_stage_direct_invites(uuid,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.set_event_stage_direct_invites(uuid,uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.generate_event_roadmap(
  p_event_id uuid,
  p_matches_per_group integer,
  p_interval_minutes integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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
    'schedule_published',false);
END;
$function$;
REVOKE ALL ON FUNCTION public.generate_event_roadmap(uuid,integer,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.generate_event_roadmap(uuid,integer,integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.advance_event_stage_from_roadmap(
  p_source_stage_id uuid,
  p_matches_per_group integer,
  p_interval_minutes integer,
  p_first_match_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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
  v_expected_qualified integer;
  v_direct_invites integer;
  v_invite_count integer;
  v_qualified_count integer;
  v_total_count integer;
  v_group_count integer;
  v_existing_group_count integer;
  v_target_stage_id uuid;
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

  SELECT * INTO v_event FROM public.events WHERE id = v_source.event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tournament not found'; END IF;
  v_roadmap := v_event.event_config->'roadmap';
  v_names := COALESCE(v_event.event_config->'stage_names','[]'::jsonb);
  v_stage_count := NULLIF(v_event.event_config->>'stage_count','')::integer;
  v_next_round := v_source.round_number + 1;
  IF v_stage_count IS NULL OR v_next_round > v_stage_count THEN
    RAISE EXCEPTION 'The saved roadmap has no additional stage after %',v_source.name;
  END IF;

  v_group_size := NULLIF(v_roadmap->>'group_size','')::integer;
  v_qualify := NULLIF(v_roadmap->>'qualifiers_per_group','')::integer;
  v_expected_qualified := NULLIF(v_roadmap->>'qualified_team_count','')::integer;
  v_direct_invites := COALESCE(NULLIF(v_roadmap->>'direct_invites','')::integer,0);
  IF v_group_size IS NULL OR v_group_size < 2 OR v_group_size > 24
     OR v_qualify IS NULL OR v_qualify < 1 OR v_qualify > 24 THEN
    RAISE EXCEPTION 'The saved roadmap group/qualification settings are incomplete';
  END IF;
  IF v_next_round <> 2 AND v_direct_invites > 0 THEN
    -- The roadmap's direct-entry count applies to the first advancement only.
    v_direct_invites := 0;
  END IF;

  IF EXISTS (SELECT 1 FROM public.event_rounds WHERE event_id = v_event.id AND round_number = v_next_round) THEN
    RAISE EXCEPTION 'The next stage already exists; it will not be overwritten';
  END IF;

  SELECT count(*)::integer INTO v_invite_count
  FROM public.event_stage_direct_invites
  WHERE event_id = v_event.id AND target_round_number = v_next_round;
  IF v_invite_count <> v_direct_invites THEN
    RAISE EXCEPTION 'The roadmap expects % direct-entry teams for stage %, but % are assigned',
      v_direct_invites,v_next_round,v_invite_count;
  END IF;
  IF v_invite_count > 0 AND EXISTS (
    SELECT 1
    FROM public.event_stage_direct_invites di
    WHERE di.event_id = v_event.id
      AND di.target_round_number = v_next_round
      AND NOT EXISTS (
        SELECT 1 FROM public.event_registrations er
        JOIN public.teams t ON t.id = er.team_id
        WHERE er.event_id = v_event.id AND er.team_id = di.team_id
          AND er.status IN ('approved','checked_in') AND er.roster_locked
          AND t.game_id = v_event.game_id
      )
  ) THEN
    RAISE EXCEPTION 'A direct-entry team no longer has an approved, roster-locked registration for this event';
  END IF;

  v_stage_name := COALESCE(NULLIF(trim(v_names->>(v_next_round - 1)),''),'Stage '||v_next_round);
  v_advanced := app_private.advance_event_stage(
    p_source_stage_id,v_stage_name,
    CASE WHEN v_next_round = v_stage_count THEN 'final' ELSE 'custom' END,
    v_group_size,v_qualify
  );
  v_target_stage_id := (v_advanced->>'target_stage_id')::uuid;
  v_qualified_count := COALESCE((v_advanced->>'qualified_team_count')::integer,0);
  IF v_qualified_count <> COALESCE(v_expected_qualified,-1) THEN
    RAISE EXCEPTION 'Approved standings qualify % teams, but the saved roadmap expects %',
      v_qualified_count,v_expected_qualified;
  END IF;

  v_total_count := v_qualified_count + v_invite_count;
  v_group_count := ceil(v_total_count::numeric / v_group_size)::integer;
  IF v_total_count < v_group_count * 2 THEN
    RAISE EXCEPTION 'The next stage would create a group with fewer than two teams. Change the roadmap group size.';
  END IF;

  SELECT count(*)::integer INTO v_existing_group_count
  FROM public.event_groups WHERE round_id = v_target_stage_id;

  IF v_existing_group_count < v_group_count THEN
    INSERT INTO public.event_groups(round_id,label,sort_order)
    SELECT v_target_stage_id,'Group ' || n,n
    FROM generate_series(v_existing_group_count + 1,v_group_count) n;
  END IF;

  -- Remove stale channel membership snapshots before rebuilding the group
  -- distribution. Dynamic can_access_event_group remains the authoritative gate.
  DELETE FROM public.channel_members cm
  USING public.channels c
  WHERE c.id = cm.channel_id AND c.event_id = v_event.id
    AND c.stage_id = v_target_stage_id AND c.group_id IS NOT NULL;

  DELETE FROM public.event_group_teams egt
  USING public.event_groups g
  WHERE g.id = egt.group_id AND g.round_id = v_target_stage_id;

  WITH candidates AS (
    SELECT s.team_id,0 AS invite_order,g.sort_order AS source_group_order,
      s.group_rank,s.points,s.kills,s.first_places
    FROM public.event_stage_standings s
    JOIN public.event_groups g ON g.id = s.group_id
    WHERE s.stage_id = p_source_stage_id AND s.group_rank <= v_qualify
    UNION ALL
    SELECT di.team_id,1 AS invite_order,2147483647,2147483647,0::numeric,0::integer,0::integer
    FROM public.event_stage_direct_invites di
    WHERE di.event_id = v_event.id AND di.target_round_number = v_next_round
  ),
  distributed AS (
    SELECT team_id,
      ntile(v_group_count) OVER (
        ORDER BY invite_order,source_group_order,group_rank,
          points DESC,kills DESC,first_places DESC,team_id
      ) AS target_group_order
    FROM candidates
  )
  INSERT INTO public.event_group_teams(group_id,team_id,seeded_by)
  SELECT g.id,d.team_id,auth.uid()
  FROM distributed d
  JOIN public.event_groups g
    ON g.round_id = v_target_stage_id AND g.sort_order = d.target_group_order;

  INSERT INTO public.audit_logs(actor_id,event_id,entity_type,entity_id,action,reason,metadata)
  VALUES (
    auth.uid(),v_event.id,'event_stage',v_target_stage_id,'roadmap_direct_entry_teams_added',
    'Balanced the approved qualifiers and explicitly assigned direct-entry teams into the next stage',
    jsonb_build_object('source_stage_id',p_source_stage_id,
      'target_stage_id',v_target_stage_id,'qualified_team_count',v_qualified_count,
      'direct_invite_count',v_invite_count,'total_team_count',v_total_count,
      'target_group_count',v_group_count)
  );

  v_matches := app_private.generate_event_stage_matches(
    v_target_stage_id,p_matches_per_group,p_interval_minutes,p_first_match_at
  );

  RETURN v_advanced || v_matches || jsonb_build_object(
    'stage_name',v_stage_name,'group_count',v_group_count,
    'qualified_team_count',v_qualified_count,'direct_invite_count',v_invite_count,
    'total_team_count',v_total_count,'schedule_published',false
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.advance_event_stage_from_roadmap(uuid,integer,integer,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.advance_event_stage_from_roadmap(uuid,integer,integer,timestamptz) TO authenticated;
