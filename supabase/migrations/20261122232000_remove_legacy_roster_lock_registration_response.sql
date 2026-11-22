-- Registration accepts the Team and no longer reports an Organizer roster-lock state.
DO $remove_registration_lock_response$
DECLARE
  v_definition text;
  v_updated text;
BEGIN
  v_definition := pg_get_functiondef(
    'app_private.register_for_event(uuid,uuid)'::regprocedure
  );
  v_updated := replace(
    v_definition,
    E'    \'roster_size\', v_roster_count,\n    \'roster_locked\', false',
    E'    \'roster_size\', v_roster_count'
  );
  IF position('roster_locked' IN v_updated) > 0 THEN
    RAISE EXCEPTION 'The registration RPC still exposes a legacy roster_locked field';
  END IF;
  EXECUTE v_updated;
END;
$remove_registration_lock_response$;
