
DO $migration$
DECLARE
  v_def text;
  v_old text;
BEGIN
  -- The match-generation helper must require the current stage's plan only.
  v_def := pg_get_functiondef(
    'app_private.generate_event_stage_matches(uuid,integer,integer,timestamptz)'::regprocedure
  );
  v_old := $old$if v_roadmap is null or (select roadmap_published_at from public.events where id=v_stage.event_id) is null then$old$;
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate the global publish gate in generate_event_stage_matches';
  END IF;
  v_def := replace(v_def,v_old,$new$if v_roadmap is null then$new$);
  EXECUTE v_def;

  -- Direct-entry edits invalidate an ungenerated target-stage roadmap so staff
  -- must publish the revised stage plan before anyone can qualify into it.
  -- If the stage already exists, keep the plan published and synchronize its
  -- direct-entry count because the assignment RPC updates scheduled groups/matches.
  v_def := pg_get_functiondef(
    'public.set_event_stage_direct_invites(uuid,integer,uuid[])'::regprocedure
  );
  v_old := $old$UPDATE public.event_rounds SET schedule_published_at=NULL,schedule_published_by=NULL,status='draft'$old$;
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate the direct-entry schedule invalidation block';
  END IF;
  v_def := replace(v_def,v_old,$new$IF EXISTS (
    SELECT 1 FROM public.event_rounds
    WHERE event_id=p_event_id AND round_number=p_target_round_number
  ) THEN
    UPDATE public.event_stage_roadmaps
    SET configuration = jsonb_set(
          configuration,
          '{direct_entry_count}',
          to_jsonb((
            SELECT count(*)::integer FROM public.event_stage_direct_invites
            WHERE event_id=p_event_id AND target_round_number=p_target_round_number
          )),
          true
        ),
        version = version + 1,
        published_at = now(),
        published_by = auth.uid()
    WHERE event_id=p_event_id AND round_number=p_target_round_number;
  ELSE
    DELETE FROM public.event_stage_roadmaps
    WHERE event_id=p_event_id AND round_number=p_target_round_number;
  END IF;

  UPDATE public.event_rounds SET schedule_published_at=NULL,schedule_published_by=NULL,status='draft'$new$);
  EXECUTE v_def;
END;
$migration$;
