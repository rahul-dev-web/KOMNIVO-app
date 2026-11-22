-- Phase 3 completion: auditable notification targeting and registration-open fan-out.
ALTER TABLE public.event_notification_dispatches
  ADD COLUMN IF NOT EXISTS target_rule text NOT NULL DEFAULT 'event_audience',
  ADD COLUMN IF NOT EXISTS scope_type text NOT NULL DEFAULT 'event',
  ADD COLUMN IF NOT EXISTS scope_id uuid,
  ADD COLUMN IF NOT EXISTS reason text NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS event_notification_dispatches_scope_idx
  ON public.event_notification_dispatches(event_id,scope_type,scope_id,created_at DESC);
CREATE INDEX IF NOT EXISTS event_notification_dispatches_target_rule_idx
  ON public.event_notification_dispatches(event_id,target_rule,created_at DESC);

CREATE OR REPLACE FUNCTION app_private.enqueue_event_notification(
  p_event_id uuid,
  p_user_id uuid,
  p_notification_key text,
  p_title text,
  p_body text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_dispatch_id uuid;
  v_notification_id uuid;
  v_target_rule text;
  v_scope_type text;
  v_scope_id uuid;
BEGIN
  IF p_event_id IS NULL OR p_user_id IS NULL OR p_notification_key IS NULL
     OR NOT app_private.can_receive_event_notification(p_event_id, p_user_id) THEN
    RETURN NULL;
  END IF;

  v_target_rule := split_part(p_notification_key,':',1);
  v_scope_type := CASE
    WHEN v_target_rule='group_assigned' THEN 'group'
    WHEN v_target_rule='match_schedule' THEN 'match'
    WHEN v_target_rule IN ('registration_submitted','registration_status') THEN 'registration'
    ELSE 'event'
  END;
  v_scope_id := CASE
    WHEN v_scope_type IN ('group','match','registration')
      THEN nullif(split_part(p_notification_key,':',2),'')::uuid
    ELSE NULL
  END;

  INSERT INTO public.event_notification_dispatches(
    event_id,user_id,notification_key,target_rule,scope_type,scope_id,reason
  )
  VALUES (
    p_event_id,p_user_id,p_notification_key,v_target_rule,v_scope_type,v_scope_id,
    left(coalesce(p_title,'')||': '||coalesce(p_body,''),1000)
  )
  ON CONFLICT(event_id,user_id,notification_key) DO NOTHING
  RETURNING id INTO v_dispatch_id;

  IF v_dispatch_id IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.notifications(user_id,title,body,kind,entity_type,entity_id)
  VALUES (
    p_user_id,
    left(coalesce(p_title,'Tournament update'),120),
    left(coalesce(p_body,''),2000),
    'tournament',
    'event',
    p_event_id
  )
  RETURNING id INTO v_notification_id;

  UPDATE public.event_notification_dispatches
  SET notification_id = v_notification_id
  WHERE id = v_dispatch_id;

  RETURN v_notification_id;
END;
$function$;
REVOKE ALL ON FUNCTION app_private.enqueue_event_notification(uuid,uuid,text,text,text)
  FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION app_private.notify_event_registration_open()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid;
  v_close_text text;
BEGIN
  IF NEW.status <> 'registration_open' THEN
    RETURN NEW;
  END IF;
  IF TG_OP='UPDATE' AND OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;
  IF NEW.community_id IS NULL OR NEW.game_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.registration_opens_at IS NOT NULL AND NEW.registration_opens_at > now() THEN
    RETURN NEW;
  END IF;
  IF NEW.registration_closes_at IS NULL OR NEW.registration_closes_at <= now() THEN
    RETURN NEW;
  END IF;

  v_close_text := to_char(
    NEW.registration_closes_at AT TIME ZONE 'UTC',
    'YYYY-MM-DD HH24:MI'
  ) || ' UTC';

  FOR v_user_id IN
    SELECT audience.user_id
    FROM (
      SELECT cm.user_id
      FROM public.community_members cm
      WHERE cm.community_id=NEW.community_id
      UNION
      SELECT ef.user_id
      FROM public.event_follows ef
      WHERE ef.event_id=NEW.id
    ) audience
    WHERE EXISTS (
      SELECT 1
      FROM public.game_accounts ga
      WHERE ga.user_id=audience.user_id
        AND ga.game_id=NEW.game_id
        AND ga.ownership_status <> 'rejected'
    )
  LOOP
    PERFORM app_private.enqueue_event_notification(
      NEW.id,
      v_user_id,
      'registration_open',
      'Tournament registration is open',
      NEW.name || ' is now accepting registrations. The deadline is ' || v_close_text || '.'
    );
  END LOOP;

  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION app_private.notify_event_registration_open()
  FROM PUBLIC,anon,authenticated;

DROP TRIGGER IF EXISTS events_notify_registration_open ON public.events;
CREATE TRIGGER events_notify_registration_open
AFTER UPDATE OF status ON public.events
FOR EACH ROW
EXECUTE FUNCTION app_private.notify_event_registration_open();

COMMENT ON COLUMN public.event_notification_dispatches.target_rule IS
  'The server-resolved audience rule key that selected this individual recipient.';
COMMENT ON COLUMN public.event_notification_dispatches.scope_type IS
  'The notification action scope: event, registration, group or match.';
COMMENT ON COLUMN public.event_notification_dispatches.scope_id IS
  'Polymorphic registration/group/match scope ID; event-scoped rows use event_id.';
COMMENT ON COLUMN public.event_notification_dispatches.reason IS
  'Human-readable notification reason snapshot for delivery audit.';
