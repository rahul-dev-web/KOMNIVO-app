-- Phase 3: isolate test registrations and dispatch tournament notifications to scoped recipients.
-- Test records never enter real slot counting, participant lists, standings, or score pipelines.

CREATE TABLE IF NOT EXISTS public.event_test_registrations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  team_id uuid REFERENCES public.teams(id) ON DELETE SET NULL,
  submitted_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'submitted'
    CHECK (status IN ('submitted','passed','failed','cancelled')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS event_test_registrations_active_team_uidx
  ON public.event_test_registrations(event_id, team_id)
  WHERE team_id IS NOT NULL AND status = 'submitted';
CREATE UNIQUE INDEX IF NOT EXISTS event_test_registrations_active_solo_uidx
  ON public.event_test_registrations(event_id, submitted_by)
  WHERE team_id IS NULL AND status = 'submitted';
CREATE INDEX IF NOT EXISTS event_test_registrations_event_created_idx
  ON public.event_test_registrations(event_id, created_at DESC);
CREATE INDEX IF NOT EXISTS event_test_registrations_submitter_idx
  ON public.event_test_registrations(submitted_by, created_at DESC);

CREATE TABLE IF NOT EXISTS public.event_test_registration_players (
  registration_id uuid NOT NULL REFERENCES public.event_test_registrations(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  game_account_id uuid REFERENCES public.game_accounts(id) ON DELETE SET NULL,
  PRIMARY KEY (registration_id, user_id)
);
CREATE INDEX IF NOT EXISTS event_test_registration_players_user_idx
  ON public.event_test_registration_players(user_id, registration_id);

ALTER TABLE public.event_test_registrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_test_registration_players ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.event_test_registrations, public.event_test_registration_players
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.event_test_registrations, public.event_test_registration_players
  TO authenticated;

DROP POLICY IF EXISTS event_test_registrations_read_scoped
  ON public.event_test_registrations;
CREATE POLICY event_test_registrations_read_scoped
  ON public.event_test_registrations
  FOR SELECT TO authenticated
  USING (
    submitted_by = (select auth.uid())
    OR public.is_event_staff(event_id)
  );

DROP POLICY IF EXISTS event_test_registration_players_read_scoped
  ON public.event_test_registration_players;
CREATE POLICY event_test_registration_players_read_scoped
  ON public.event_test_registration_players
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.event_test_registrations r
      WHERE r.id = registration_id
        AND (r.submitted_by = (select auth.uid()) OR public.is_event_staff(r.event_id))
    )
  );

-- This table is an idempotency ledger, not a client-readable notification API.
CREATE TABLE IF NOT EXISTS public.event_notification_dispatches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  notification_key text NOT NULL,
  notification_id uuid REFERENCES public.notifications(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(event_id, user_id, notification_key)
);
CREATE INDEX IF NOT EXISTS event_notification_dispatches_event_time_idx
  ON public.event_notification_dispatches(event_id, created_at DESC);

ALTER TABLE public.event_notification_dispatches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.event_notification_dispatches FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.event_notification_dispatches TO service_role;
DROP POLICY IF EXISTS event_notification_dispatches_deny_client
  ON public.event_notification_dispatches;
CREATE POLICY event_notification_dispatches_deny_client
  ON public.event_notification_dispatches
  FOR ALL TO anon, authenticated
  USING (false)
  WITH CHECK (false);

CREATE OR REPLACE FUNCTION app_private.can_receive_event_notification(
  p_event_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.events e
    JOIN public.communities c ON c.id = e.community_id
    WHERE e.id = p_event_id
      AND p_user_id IS NOT NULL
      AND (
        c.visibility = 'public'
        OR c.owner_user_id = p_user_id
        OR e.organizer_id = p_user_id
        OR EXISTS (
          SELECT 1 FROM public.community_members cm
          WHERE cm.community_id = e.community_id AND cm.user_id = p_user_id
        )
      )
  );
$function$;
REVOKE ALL ON FUNCTION app_private.can_receive_event_notification(uuid,uuid)
  FROM PUBLIC, anon, authenticated;

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
BEGIN
  IF p_event_id IS NULL OR p_user_id IS NULL OR p_notification_key IS NULL
     OR NOT app_private.can_receive_event_notification(p_event_id, p_user_id) THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.event_notification_dispatches(event_id,user_id,notification_key)
  VALUES (p_event_id,p_user_id,p_notification_key)
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
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION app_private.notify_event_published()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid;
  v_open_text text;
BEGIN
  IF NEW.status <> 'published' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;
  IF NEW.community_id IS NULL OR NEW.game_id IS NULL THEN RETURN NEW; END IF;

  v_open_text := CASE
    WHEN NEW.registration_opens_at IS NULL THEN 'Registration opening time is not yet announced.'
    ELSE 'Registration opens at ' ||
      to_char(NEW.registration_opens_at AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI') || ' UTC.'
  END;

  FOR v_user_id IN
    SELECT audience.user_id
    FROM (
      SELECT cm.user_id
      FROM public.community_members cm
      WHERE cm.community_id = NEW.community_id
      UNION
      SELECT ef.user_id
      FROM public.event_follows ef
      WHERE ef.event_id = NEW.id
    ) audience
    WHERE EXISTS (
      SELECT 1 FROM public.game_accounts ga
      WHERE ga.user_id = audience.user_id
        AND ga.game_id = NEW.game_id
        AND ga.ownership_status <> 'rejected'
    )
  LOOP
    PERFORM app_private.enqueue_event_notification(
      NEW.id,
      v_user_id,
      'event_published',
      'Tournament published',
      NEW.name || ' is now published. ' || v_open_text
    );
  END LOOP;

  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION app_private.notify_event_published()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS events_notify_game_audience_after_publish ON public.events;
CREATE TRIGGER events_notify_game_audience_after_publish
AFTER INSERT OR UPDATE OF status ON public.events
FOR EACH ROW
EXECUTE FUNCTION app_private.notify_event_published();

CREATE OR REPLACE FUNCTION app_private.notify_event_registration_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event public.events%ROWTYPE;
  v_team public.teams%ROWTYPE;
  v_user_id uuid;
  v_key text;
  v_title text;
  v_body text;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_event FROM public.events WHERE id = NEW.event_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  IF TG_OP = 'INSERT' THEN
    v_key := 'registration_submitted:' || NEW.id::text;
    v_title := 'Registration received';
    v_body := CASE
      WHEN NEW.team_id IS NULL THEN 'Your registration for ' || v_event.name || ' was received.'
      ELSE 'A registration for ' || v_event.name || ' was submitted for your team. Current status: ' || NEW.status || '.'
    END;
  ELSE
    v_key := 'registration_status:' || NEW.id::text || ':' || NEW.status;
    v_title := 'Registration ' || replace(NEW.status,'_',' ');
    v_body := CASE
      WHEN NEW.team_id IS NULL THEN 'Your registration for ' || v_event.name || ' is now ' || replace(NEW.status,'_',' ') || '.'
      ELSE 'Your team registration for ' || v_event.name || ' is now ' || replace(NEW.status,'_',' ') || '.'
    END;
  END IF;

  FOR v_user_id IN
    SELECT NEW.captain_user_id
    UNION
    SELECT t.owner_user_id
    FROM public.teams t
    WHERE NEW.team_id IS NOT NULL AND t.id = NEW.team_id
      AND NOT EXISTS (
        SELECT 1 FROM public.team_members tm
        WHERE tm.team_id = t.id AND tm.role = 'captain'
      )
    UNION
    SELECT tm.user_id
    FROM public.team_members tm
    WHERE NEW.team_id IS NOT NULL
      AND tm.team_id = NEW.team_id
      AND tm.role = 'captain'
  LOOP
    PERFORM app_private.enqueue_event_notification(
      NEW.event_id, v_user_id, v_key, v_title, v_body
    );
  END LOOP;

  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION app_private.notify_event_registration_change()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS event_registrations_notify_recipients
  ON public.event_registrations;
CREATE TRIGGER event_registrations_notify_recipients
AFTER INSERT OR UPDATE OF status ON public.event_registrations
FOR EACH ROW
EXECUTE FUNCTION app_private.notify_event_registration_change();

CREATE OR REPLACE FUNCTION app_private.notify_group_team_assignment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event_id uuid;
  v_event_name text;
  v_group_label text;
  v_user_id uuid;
BEGIN
  SELECT e.id,e.name,g.label
  INTO v_event_id,v_event_name,v_group_label
  FROM public.event_groups g
  JOIN public.event_rounds r ON r.id = g.round_id
  JOIN public.events e ON e.id = r.event_id
  WHERE g.id = NEW.group_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  FOR v_user_id IN
    SELECT tm.user_id
    FROM public.team_members tm
    WHERE tm.team_id = NEW.team_id
    UNION
    SELECT t.owner_user_id
    FROM public.teams t
    WHERE t.id = NEW.team_id
  LOOP
    PERFORM app_private.enqueue_event_notification(
      v_event_id,
      v_user_id,
      'group_assigned:' || NEW.group_id::text || ':' || NEW.team_id::text,
      'Group assigned',
      'Your team has been placed in Group ' || v_group_label || ' for ' || v_event_name || '.'
    );
  END LOOP;

  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION app_private.notify_group_team_assignment()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS event_group_teams_notify_assignment
  ON public.event_group_teams;
CREATE TRIGGER event_group_teams_notify_assignment
AFTER INSERT ON public.event_group_teams
FOR EACH ROW
EXECUTE FUNCTION app_private.notify_group_team_assignment();

CREATE OR REPLACE FUNCTION app_private.notify_match_schedule(
  p_match_id uuid,
  p_team_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_match public.matches%ROWTYPE;
  v_event public.events%ROWTYPE;
  v_team_name text;
  v_user_id uuid;
  v_epoch text;
  v_title text;
  v_body text;
BEGIN
  SELECT * INTO v_match FROM public.matches WHERE id = p_match_id;
  IF NOT FOUND OR v_match.starts_at IS NULL THEN RETURN; END IF;
  IF v_match.status NOT IN ('scheduled','check_in','room_setup','lobby_review','cancelled') THEN
    RETURN;
  END IF;

  SELECT * INTO v_event FROM public.events WHERE id = v_match.event_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT t.name INTO v_team_name FROM public.teams t WHERE t.id = p_team_id;
  v_epoch := extract(epoch FROM v_match.starts_at)::bigint::text || ':' || v_match.status;

  IF v_match.status = 'cancelled' THEN
    v_title := 'Match cancelled';
    v_body := 'Match ' || v_match.match_number || ' for ' || v_event.name || ' has been cancelled.';
  ELSE
    v_title := 'Match schedule updated';
    v_body := 'Match ' || v_match.match_number ||
      CASE WHEN v_match.group_label IS NULL THEN '' ELSE ' (' || v_match.group_label || ')' END ||
      ' for ' || v_event.name || ' is scheduled for ' ||
      to_char(v_match.starts_at AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI') || ' UTC.';
  END IF;

  FOR v_user_id IN
    SELECT tm.user_id
    FROM public.team_members tm
    WHERE tm.team_id = p_team_id
    UNION
    SELECT t.owner_user_id
    FROM public.teams t
    WHERE t.id = p_team_id
  LOOP
    PERFORM app_private.enqueue_event_notification(
      v_match.event_id,
      v_user_id,
      'match_schedule:' || p_match_id::text || ':' || p_team_id::text || ':' || v_epoch,
      v_title,
      coalesce(v_team_name,'Your team') || ': ' || v_body
    );
  END LOOP;
END;
$function$;
REVOKE ALL ON FUNCTION app_private.notify_match_schedule(uuid,uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION app_private.notify_match_schedule_from_match()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_team_id uuid;
BEGIN
  FOR v_team_id IN
    SELECT mp.team_id
    FROM public.match_participants mp
    WHERE mp.match_id = NEW.id
    UNION
    SELECT egt.team_id
    FROM public.event_group_teams egt
    WHERE NEW.group_id IS NOT NULL
      AND egt.group_id = NEW.group_id
  LOOP
    PERFORM app_private.notify_match_schedule(NEW.id,v_team_id);
  END LOOP;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION app_private.notify_match_schedule_from_match()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS matches_notify_schedule_recipients ON public.matches;
CREATE TRIGGER matches_notify_schedule_recipients
AFTER INSERT OR UPDATE OF starts_at,status ON public.matches
FOR EACH ROW
EXECUTE FUNCTION app_private.notify_match_schedule_from_match();

CREATE OR REPLACE FUNCTION app_private.notify_match_schedule_from_participant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  PERFORM app_private.notify_match_schedule(NEW.match_id,NEW.team_id);
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION app_private.notify_match_schedule_from_participant()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS match_participants_notify_schedule_recipients
  ON public.match_participants;
CREATE TRIGGER match_participants_notify_schedule_recipients
AFTER INSERT OR UPDATE OF match_id,team_id ON public.match_participants
FOR EACH ROW
EXECUTE FUNCTION app_private.notify_match_schedule_from_participant();

CREATE OR REPLACE FUNCTION app_private.submit_test_registration(
  p_event_id uuid,
  p_team_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event public.events%ROWTYPE;
  v_registration_id uuid;
  v_roster_size integer := 1;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT * INTO v_event
  FROM public.events
  WHERE id = p_event_id
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Event not found'; END IF;
  IF v_event.status NOT IN ('published','registration_open') THEN
    RAISE EXCEPTION 'Test registration is unavailable before publication or after registration closes';
  END IF;
  IF v_event.registration_closes_at IS NULL OR v_event.registration_closes_at <= now() THEN
    RAISE EXCEPTION 'Test registration window has closed or is not configured';
  END IF;
  IF NOT app_private.resolve_permission('event.view','event',p_event_id,NULL,NULL) THEN
    RAISE EXCEPTION 'You cannot access this tournament';
  END IF;

  IF v_event.format = 'solo' THEN
    IF p_team_id IS NOT NULL THEN
      RAISE EXCEPTION 'Solo test registrations do not accept a team';
    END IF;
  ELSE
    IF p_team_id IS NULL THEN
      RAISE EXCEPTION 'Select a team for this test registration';
    END IF;
    IF NOT app_private.is_event_registration_eligible_player(p_event_id,auth.uid(),p_team_id) THEN
      RAISE EXCEPTION 'Your team is not eligible for this tournament test registration';
    END IF;
    SELECT count(*) INTO v_roster_size
    FROM public.team_members tm
    WHERE tm.team_id = p_team_id;
  END IF;

  IF v_event.format = 'solo'
     AND NOT app_private.is_event_registration_eligible_player(p_event_id,auth.uid(),NULL) THEN
    RAISE EXCEPTION 'You are not eligible for this tournament test registration';
  END IF;

  INSERT INTO public.event_test_registrations(event_id,team_id,submitted_by)
  VALUES (p_event_id,p_team_id,auth.uid())
  RETURNING id INTO v_registration_id;

  IF v_event.format = 'solo' THEN
    INSERT INTO public.event_test_registration_players(registration_id,user_id,game_account_id)
    SELECT v_registration_id,auth.uid(),ga.id
    FROM public.game_accounts ga
    WHERE ga.user_id = auth.uid() AND ga.game_id = v_event.game_id
    ORDER BY ga.last_synced_at DESC NULLS LAST
    LIMIT 1;
    IF NOT FOUND THEN
      INSERT INTO public.event_test_registration_players(registration_id,user_id)
      VALUES (v_registration_id,auth.uid());
    END IF;
  ELSE
    INSERT INTO public.event_test_registration_players(registration_id,user_id,game_account_id)
    SELECT v_registration_id,tm.user_id,ga.id
    FROM public.team_members tm
    LEFT JOIN LATERAL (
      SELECT id FROM public.game_accounts
      WHERE user_id=tm.user_id AND game_id=v_event.game_id
      ORDER BY last_synced_at DESC NULLS LAST
      LIMIT 1
    ) ga ON true
    WHERE tm.team_id=p_team_id;
  END IF;

  RETURN jsonb_build_object(
    'test_registration_id',v_registration_id,
    'status','submitted',
    'roster_size',v_roster_size,
    'is_test',true,
    'consumes_real_slot',false,
    'affects_standings',false
  );
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'An active test registration already exists for this player or team';
END;
$function$;
REVOKE ALL ON FUNCTION app_private.submit_test_registration(uuid,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app_private.submit_test_registration(uuid,uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.submit_test_registration(
  p_event_id uuid,
  p_team_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SET search_path = ''
AS $function$
  SELECT app_private.submit_test_registration(p_event_id,p_team_id);
$function$;
REVOKE ALL ON FUNCTION public.submit_test_registration(uuid,uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_test_registration(uuid,uuid)
  TO authenticated;

COMMENT ON TABLE public.event_test_registrations IS
  'Isolated tournament registration-test submissions. Never counted as real event registrations, capacity, public participants or scoring inputs.';
COMMENT ON TABLE public.event_test_registration_players IS
  'Roster snapshots for isolated registration-test submissions; not linked to real registration, match participation or scoring.';
COMMENT ON TABLE public.event_notification_dispatches IS
  'Server-only idempotency ledger for targeted tournament notifications.';
