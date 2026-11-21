-- Make service-only delivery log access explicit to RLS auditors and cover FKs.
DROP POLICY IF EXISTS notification_delivery_attempts_deny_client
  ON public.notification_delivery_attempts;
CREATE POLICY notification_delivery_attempts_deny_client
  ON public.notification_delivery_attempts
  FOR ALL TO anon,authenticated
  USING (false)
  WITH CHECK (false);

CREATE INDEX IF NOT EXISTS message_mentions_notification_id_idx
  ON public.message_mentions(notification_id);
CREATE INDEX IF NOT EXISTS message_mentions_sender_id_idx
  ON public.message_mentions(sender_id);
CREATE INDEX IF NOT EXISTS notification_delivery_attempts_device_token_id_idx
  ON public.notification_delivery_attempts(device_token_id);
