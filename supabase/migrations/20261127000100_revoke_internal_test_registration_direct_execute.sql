-- Keep the privileged test-registration implementation private.
-- The authenticated public.submit_test_registration RPC is SECURITY DEFINER,
-- so clients never need direct EXECUTE on this internal app_private function.
REVOKE ALL ON FUNCTION app_private.submit_test_registration(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
