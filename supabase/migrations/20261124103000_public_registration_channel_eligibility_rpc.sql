-- Expose the registration-channel eligibility check as a narrowly granted RPC.
-- The wrapper runs as the caller; the private helper performs the auth.uid()-bound check.
CREATE OR REPLACE FUNCTION public.can_write_event_registration_channel(
  p_channel_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $function$
  SELECT app_private.can_write_event_registration_channel(p_channel_id);
$function$;

REVOKE ALL ON FUNCTION public.can_write_event_registration_channel(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_write_event_registration_channel(uuid)
  TO authenticated;
