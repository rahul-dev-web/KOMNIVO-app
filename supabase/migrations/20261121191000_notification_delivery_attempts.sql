-- Durable per-device push delivery attempts for notifications (including targeted mentions).
CREATE TABLE IF NOT EXISTS public.notification_delivery_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  notification_id uuid NOT NULL REFERENCES public.notifications(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  device_token_id uuid NOT NULL REFERENCES public.device_tokens(id) ON DELETE CASCADE,
  attempt_number smallint NOT NULL CHECK (attempt_number BETWEEN 1 AND 3),
  status text NOT NULL CHECK (status IN ('accepted','retryable_failure','permanent_failure')),
  http_status integer,
  error_code text,
  attempted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(notification_id,device_token_id,attempt_number)
);

CREATE INDEX IF NOT EXISTS notification_delivery_notification_time_idx
  ON public.notification_delivery_attempts(notification_id,attempted_at DESC);
CREATE INDEX IF NOT EXISTS notification_delivery_user_time_idx
  ON public.notification_delivery_attempts(user_id,attempted_at DESC);

ALTER TABLE public.notification_delivery_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.notification_delivery_attempts FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.notification_delivery_attempts TO service_role;

COMMENT ON TABLE public.notification_delivery_attempts IS
  'Service-role-only per-device FCM delivery log. Tokens are never stored; each notification/device has at most three retry attempts.';
