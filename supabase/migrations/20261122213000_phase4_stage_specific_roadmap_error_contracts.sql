
DO $migration$
DECLARE
  v_def text;
  v_old text;
BEGIN
  v_def := pg_get_functiondef('public.generate_event_roadmap(uuid,integer,integer)'::regprocedure);
  v_old := 'Publish the complete stage-to-stage roadmap before generating Stage 1';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Stage 1 error message not found'; END IF;
  v_def := replace(v_def,v_old,'Publish the Stage 1 roadmap before generating Stage 1');
  EXECUTE v_def;

  v_def := pg_get_functiondef('app_private.generate_event_stage_matches(uuid,integer,integer,timestamptz)'::regprocedure);
  v_old := 'Publish the complete roadmap before generating this stage schedule';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Stage schedule error message not found'; END IF;
  v_def := replace(v_def,v_old,'Publish this stage roadmap before generating its schedule');
  EXECUTE v_def;

  v_def := pg_get_functiondef('app_private.advance_event_stage(uuid,text,text,integer,integer)'::regprocedure);
  v_old := 'The complete target-stage roadmap must be published before qualification';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Internal stage-advance error message not found'; END IF;
  v_def := replace(v_def,v_old,'Both source and target stage roadmaps must be published before qualification');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.advance_event_stage_from_roadmap(uuid,integer,integer,timestamptz)'::regprocedure);
  v_old := 'Publish the entire stage-to-stage roadmap before qualifying or advancing';
  IF position(v_old in v_def)=0 THEN RAISE EXCEPTION 'Public stage-advance error message not found'; END IF;
  v_def := replace(v_def,v_old,'Publish both the source and target stage roadmaps before qualifying or advancing');
  EXECUTE v_def;
END;
$migration$;
