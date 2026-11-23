-- Bound automatically generated shared Match-room category names to the existing
-- channel_categories.name contract. The earlier group-IDP category is also bounded;
-- this second insert must remain valid before ON CONFLICT resolves the shared group category.
DO $patch$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
BEGIN
  v_definition := pg_get_functiondef(
    'app_private.create_event_match_channel()'::regprocedure
  );

  v_old := $old$    left(v_event_name,32)||' · '||left(v_stage_name,18)||' · '||v_group_label,$old$;
  IF position(v_old in v_definition)=0 THEN
    RAISE EXCEPTION 'Could not locate the group category name in create_event_match_channel';
  END IF;

  v_new := $new$    left(v_event_name,16) || ' · ' || left(v_stage_name,12) || ' · ' || left(v_group_label,20),$new$;
  EXECUTE replace(v_definition,v_old,v_new);
END;
$patch$;
