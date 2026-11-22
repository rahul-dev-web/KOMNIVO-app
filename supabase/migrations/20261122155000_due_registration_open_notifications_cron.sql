-- Dispatch scheduled registration-open notices even when the event remains in published state.
CREATE INDEX IF NOT EXISTS events_registration_open_due_idx
  ON public.events(registration_opens_at,registration_closes_at)
  WHERE status IN ('published','registration_open')
    AND registration_opens_at IS NOT NULL;

CREATE OR REPLACE FUNCTION app_private.dispatch_due_registration_open_notifications()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event record;
  v_user_id uuid;
  v_notification_id uuid;
  v_dispatched integer := 0;
BEGIN
  FOR v_event IN
    SELECT e.id,e.community_id,e.game_id,e.name,e.registration_closes_at
    FROM public.events e
    WHERE e.status IN ('published','registration_open')
      AND e.community_id IS NOT NULL
      AND e.game_id IS NOT NULL
      AND e.registration_opens_at IS NOT NULL
      AND e.registration_opens_at <= now()
      AND e.registration_closes_at > now()
  LOOP
    FOR v_user_id IN
      SELECT audience.user_id
      FROM (
        SELECT cm.user_id
        FROM public.community_members cm
        WHERE cm.community_id=v_event.community_id
        UNION
        SELECT ef.user_id
        FROM public.event_follows ef
        WHERE ef.event_id=v_event.id
      ) audience
      WHERE EXISTS (
        SELECT 1
        FROM public.game_accounts ga
        WHERE ga.user_id=audience.user_id
          AND ga.game_id=v_event.game_id
          AND ga.ownership_status <> 'rejected'
      )
    LOOP
      v_notification_id := app_private.enqueue_event_notification(
        v_event.id,
        v_user_id,
        'registration_open',
        'Tournament registration is open',
        v_event.name || ' is now accepting registrations. The deadline is ' ||
          to_char(v_event.registration_closes_at AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI') || ' UTC.'
      );
      IF v_notification_id IS NOT NULL THEN
        v_dispatched := v_dispatched + 1;
      END IF;
    END LOOP;
  END LOOP;

  RETURN v_dispatched;
END;
$function$;
REVOKE ALL ON FUNCTION app_private.dispatch_due_registration_open_notifications()
  FROM PUBLIC,anon,authenticated;

DO $$
DECLARE
  v_job_id bigint;
BEGIN
  SELECT jobid INTO v_job_id
  FROM cron.job
  WHERE jobname='komnivo-registration-open-notifications'
  LIMIT 1;

  IF v_job_id IS NOT NULL THEN
    PERFORM cron.unschedule(v_job_id);
  END IF;

  PERFORM cron.schedule(
    'komnivo-registration-open-notifications',
    '* * * * *',
    'select app_private.dispatch_due_registration_open_notifications();'
  );
END;
$$;
