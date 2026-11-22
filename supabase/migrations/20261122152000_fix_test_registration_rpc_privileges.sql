-- Keep the privileged test-registration implementation behind the authenticated public RPC.
CREATE OR REPLACE FUNCTION public.submit_test_registration(
  p_event_id uuid,
  p_team_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT app_private.submit_test_registration(p_event_id,p_team_id);
$function$;

REVOKE ALL ON FUNCTION app_private.submit_test_registration(uuid,uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.submit_test_registration(uuid,uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_test_registration(uuid,uuid)
  TO authenticated;
