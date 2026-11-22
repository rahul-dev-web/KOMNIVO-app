-- Phase 4 distribution correction: direct-entry teams are seeded across
-- groups using the same snake distribution as qualified teams, not clustered.
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
    SELECT di.team_id,1 AS invite_order,2147483647,2147483647,
      0::numeric,0::integer,0::integer
    FROM public.event_stage_direct_invites di
    WHERE di.event_id = v_event.id AND di.target_round_number = v_next_round
  ),
  ranked AS (
    SELECT team_id,
      row_number() OVER (
        ORDER BY invite_order,source_group_order,group_rank,
          points DESC,kills DESC,first_places DESC,team_id
      )::integer AS seed_index
    FROM candidates
  ),
  distributed AS (
    SELECT team_id,
      CASE
        WHEN (floor((seed_index - 1)::numeric / v_group_count)::integer % 2) = 0
          THEN mod(seed_index - 1,v_group_count) + 1
        ELSE v_group_count - mod(seed_index - 1,v_group_count)
      END AS target_group_order
    FROM ranked
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
