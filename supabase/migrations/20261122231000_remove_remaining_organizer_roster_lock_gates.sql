-- Remove the remaining legacy roster_locked requirements from manual and roadmap
-- Team/Match operations. A registration approval accepts the Team; it does not
-- freeze which current Team members may play. Verified identity matching is
-- independently enforced by get_liveops_match_roster_snapshot().

DO $remove_all_legacy_gates$
DECLARE
  v_function regprocedure;
  v_definition text;
  v_updated text;
  v_functions regprocedure[] := ARRAY[
    'public.generate_event_roadmap(uuid,integer,integer)'::regprocedure,
    'app_private.generate_event_stage_matches(uuid,integer,integer,timestamp with time zone)'::regprocedure,
    'public.advance_event_stage_from_roadmap(uuid,integer,integer,timestamp with time zone)'::regprocedure,
    'app_private.create_match(uuid,uuid[],timestamp with time zone,text)'::regprocedure,
    'app_private.generate_event_groups(uuid,integer,integer)'::regprocedure,
    'public.publish_event_stage_roadmap(uuid,jsonb)'::regprocedure,
    'public.set_event_stage_direct_invites(uuid,integer,uuid[])'::regprocedure
  ];
BEGIN
  FOREACH v_function IN ARRAY v_functions LOOP
    v_definition := pg_get_functiondef(v_function);
    v_updated := regexp_replace(
      v_definition,
      '(?i)\s+AND\s+(?:[a-z_][a-z0-9_]*\.)?roster_locked\y',
      '',
      'g'
    );
    v_updated := regexp_replace(
      v_updated,
      '(?i)approved and locked roster',
      'approved Team registration',
      'g'
    );
    v_updated := regexp_replace(
      v_updated,
      '(?i)approved, locked roster',
      'approved Team registration',
      'g'
    );
    v_updated := regexp_replace(
      v_updated,
      '(?i)approved, roster-locked registration',
      'approved Team registration',
      'g'
    );
    v_updated := regexp_replace(
      v_updated,
      '(?i)approved, roster-locked teams',
      'approved Team registrations',
      'g'
    );
    v_updated := regexp_replace(
      v_updated,
      '(?i)approved teams with locked rosters',
      'approved Team registrations',
      'g'
    );
    IF position('roster_locked' IN v_updated) > 0
       OR v_updated ~* 'roster-locked|locked roster|locked rosters' THEN
      RAISE EXCEPTION 'Legacy roster lock reference remains in %', v_function;
    END IF;
    EXECUTE v_updated;
  END LOOP;
END;
$remove_all_legacy_gates$;

COMMENT ON FUNCTION app_private.create_match(uuid,uuid[],timestamptz,text) IS
  'Creates a Match from approved Team registrations; no Organizer player-lineup lock is required.';
COMMENT ON FUNCTION app_private.generate_event_groups(uuid,integer,integer) IS
  'Generates groups from approved Team registrations; Team membership remains owned by each Team.';
