-- Tournament channel content contract.
-- Info is evergreen tournament metadata; Updates is for lifecycle and scoped operational notices.
-- Messages are queued through the existing service-role scheduled-announcement worker so
-- read-only announcement channels and their permission guard remain intact.

CREATE TABLE IF NOT EXISTS public.event_channel_announcement_dispatches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  dispatch_key text NOT NULL,
  scheduled_announcement_id uuid
    REFERENCES public.scheduled_channel_announcements(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(event_id, dispatch_key)
);

ALTER TABLE public.event_channel_announcement_dispatches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.event_channel_announcement_dispatches FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.event_channel_announcement_dispatches TO service_role;
DROP POLICY IF EXISTS event_channel_announcement_dispatches_deny_client
  ON public.event_channel_announcement_dispatches;
CREATE POLICY event_channel_announcement_dispatches_deny_client
  ON public.event_channel_announcement_dispatches
  FOR ALL TO anon, authenticated
  USING (false)
  WITH CHECK (false);

CREATE INDEX IF NOT EXISTS event_channel_announcement_dispatches_event_time_idx
  ON public.event_channel_announcement_dispatches(event_id, created_at DESC);

CREATE OR REPLACE FUNCTION app_private.enqueue_event_channel_announcement(
  p_event_id uuid,
  p_channel_name text,
  p_dispatch_key text,
  p_body text,
  p_target_user_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event public.events%ROWTYPE;
  v_channel public.channels%ROWTYPE;
  v_dispatch_id uuid;
  v_announcement_id uuid;
  v_sender_id uuid;
  v_body text;
  v_mentions text;
BEGIN
  IF p_event_id IS NULL OR p_dispatch_key IS NULL OR trim(p_dispatch_key) = ''
     OR p_channel_name NOT IN ('info','updates','roadmap','schedule') THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_event
  FROM public.events
  WHERE id = p_event_id;
  IF NOT FOUND OR v_event.community_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_channel
  FROM public.channels
  WHERE event_id = p_event_id
    AND lower(name) = lower(p_channel_name)
    AND stage_id IS NULL AND group_id IS NULL AND match_id IS NULL
    AND archived_at IS NULL
  ORDER BY created_at
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_sender_id := v_event.organizer_id;
  SELECT string_agg('@' || recipients.username, ' ' ORDER BY recipients.username)
  INTO v_mentions
  FROM (
    SELECT DISTINCT p.username
    FROM unnest(coalesce(p_target_user_ids, ARRAY[]::uuid[])) AS targets(user_id)
    JOIN public.profiles p ON p.id = targets.user_id
    WHERE p.username IS NOT NULL
      AND p.id <> v_sender_id
      AND app_private.can_user_receive_channel_mention(p.id, v_channel.id)
  ) recipients;

  v_body := left(
    coalesce(p_body,'') ||
    CASE WHEN coalesce(v_mentions,'') = '' THEN ''
      ELSE E'\n\nFor: ' || v_mentions END,
    4000
  );

  INSERT INTO public.event_channel_announcement_dispatches(event_id,dispatch_key)
  VALUES (p_event_id,p_dispatch_key)
  ON CONFLICT(event_id,dispatch_key) DO NOTHING
  RETURNING id INTO v_dispatch_id;

  IF v_dispatch_id IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.scheduled_channel_announcements(
    channel_id,community_id,created_by,body,publish_at,status
  ) VALUES (
    v_channel.id,v_event.community_id,v_sender_id,v_body,now() - interval '1 second','scheduled'
  )
  RETURNING id INTO v_announcement_id;

  UPDATE public.event_channel_announcement_dispatches
  SET scheduled_announcement_id = v_announcement_id
  WHERE id = v_dispatch_id;

  RETURN v_announcement_id;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.enqueue_event_channel_announcement(uuid,text,text,text,uuid[])
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.enqueue_event_channel_announcement(uuid,text,text,text,uuid[])
  TO service_role;

CREATE OR REPLACE FUNCTION app_private.tournament_event_channel_info()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_game_name text;
  v_game_code text;
  v_game_tag text;
  v_stages text;
  v_rules text;
  v_scoring text;
  v_config jsonb;
  v_body text;
BEGIN
  IF NEW.status NOT IN ('published','registration_open','registration_closed','live','completed') THEN
    RETURN NEW;
  END IF;

  SELECT g.name,g.code INTO v_game_name,v_game_code
  FROM public.games g WHERE g.id = NEW.game_id;
  v_game_name := coalesce(v_game_name,'Game');
  v_game_tag := '#' || lower(regexp_replace(coalesce(v_game_code,'game'),'[^a-zA-Z0-9]+','_','g'));
  v_config := coalesce(NEW.event_config,'{}'::jsonb);

  SELECT string_agg(stage_name,' → ' ORDER BY ordinal)
  INTO v_stages
  FROM (
    SELECT value AS stage_name,ordinality AS ordinal
    FROM jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(v_config->'stage_names')='array'
        THEN v_config->'stage_names' ELSE '[]'::jsonb END
    ) WITH ORDINALITY
  ) stage_names;

  v_rules := coalesce(
    nullif(NEW.rules_json->>'summary',''),
    nullif(NEW.rules_json->>'custom_text',''),
    nullif(NEW.rules_json->>'rules',''),
    nullif(v_config->'rulebook'->>'title',''),
    'See the organiser-published rulebook in this tournament.'
  );
  v_scoring := CASE
    WHEN NEW.scoring_config IS NULL OR NEW.scoring_config = '{}'::jsonb
      THEN 'Scoring details will be published by the organiser.'
    ELSE left(NEW.scoring_config::text,1200)
  END;

  v_body := format(
    E'%s TOURNAMENT INFORMATION\n\nTournament: %s\nGame: %s (%s)\nFormat: %s\nSlots: %s\nPrize pool: ₹%s\nEntry: %s\nRegistration opens: %s\nRegistration closes: %s\nTournament starts: %s\nStages: %s\nRules: %s\nScoring: %s\n\nOfficial lifecycle and operational announcements will appear in #updates.',
    v_game_tag,
    NEW.name,
    v_game_name,
    v_game_tag,
    upper(replace(NEW.format,'_',' ')),
    NEW.capacity,
    coalesce(v_config->>'prize_pool_amount','0'),
    CASE
      WHEN coalesce(v_config->>'entry_type','free')='paid'
        THEN 'Paid · ₹' || coalesce(v_config->>'entry_fee','')
      ELSE 'Free'
    END,
    coalesce(to_char(NEW.registration_opens_at AT TIME ZONE 'Asia/Kolkata','DD Mon YYYY, HH12:MI AM'),'Not set') || ' IST',
    coalesce(to_char(NEW.registration_closes_at AT TIME ZONE 'Asia/Kolkata','DD Mon YYYY, HH12:MI AM'),'Not set') || ' IST',
    to_char(NEW.starts_at AT TIME ZONE 'Asia/Kolkata','DD Mon YYYY, HH12:MI AM') || ' IST',
    coalesce(v_stages, nullif(v_config->>'stage_count','') || ' stages · names to be decided'),
    left(v_rules,1200),
    v_scoring
  );

  PERFORM app_private.enqueue_event_channel_announcement(
    NEW.id,'info','info:' || md5(v_body),v_body,ARRAY[]::uuid[]
  );
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.tournament_event_channel_info() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS events_tournament_info_channel ON public.events;
CREATE TRIGGER events_tournament_info_channel
AFTER INSERT OR UPDATE OF status,name,format,game_id,starts_at,registration_opens_at,
  registration_closes_at,capacity,event_config,rules_json,scoring_config
ON public.events
FOR EACH ROW EXECUTE FUNCTION app_private.tournament_event_channel_info();

CREATE OR REPLACE FUNCTION app_private.tournament_event_channel_lifecycle_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_game_name text;
  v_game_code text;
  v_game_tag text;
  v_open_time text;
  v_close_time text;
  v_target_users uuid[];
  v_role_labels text;
  v_body text;
BEGIN
  IF TG_OP='UPDATE' THEN
    IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
      RETURN NEW;
    END IF;
  END IF;
  IF NEW.status NOT IN ('published','registration_open','registration_closed') THEN
    RETURN NEW;
  END IF;

  SELECT g.name,g.code INTO v_game_name,v_game_code
  FROM public.games g WHERE g.id=NEW.game_id;
  v_game_name := coalesce(v_game_name,'Game');
  v_game_tag := '#' || lower(regexp_replace(coalesce(v_game_code,'game'),'[^a-zA-Z0-9]+','_','g'));
  v_open_time := coalesce(
    to_char(NEW.registration_opens_at AT TIME ZONE 'Asia/Kolkata','DD Mon YYYY, HH12:MI AM') || ' IST',
    'To be announced'
  );
  v_close_time := coalesce(
    to_char(NEW.registration_closes_at AT TIME ZONE 'Asia/Kolkata','DD Mon YYYY, HH12:MI AM') || ' IST',
    'To be announced'
  );

  SELECT array_agg(DISTINCT recipients.user_id)
  INTO v_target_users
  FROM (
    SELECT NEW.organizer_id AS user_id
    UNION
    SELECT esa.user_id
    FROM public.event_staff_assignments esa
    WHERE esa.event_id=NEW.id AND esa.scope_type='event'
  ) recipients;

  SELECT string_agg(DISTINCT esa.role_key, ', ' ORDER BY esa.role_key)
  INTO v_role_labels
  FROM public.event_staff_assignments esa
  WHERE esa.event_id=NEW.id AND esa.scope_type='event';

  IF NEW.status='published' THEN
    v_body := format('%s %s is now published. Registration opens %s and closes %s. Full tournament details are in #info.',
      v_game_tag,NEW.name,v_open_time,v_close_time) || CASE WHEN v_role_labels IS NOT NULL THEN chr(10) || 'Event roles: ' || v_role_labels ELSE '' END;
  ELSIF NEW.status='registration_open' THEN
    v_body := format('%s Registration is now OPEN for %s. Deadline: %s. Check #info for entry requirements and tournament details.',
      v_game_tag,NEW.name,v_close_time) || CASE WHEN v_role_labels IS NOT NULL THEN chr(10) || 'Event roles: ' || v_role_labels ELSE '' END;
  ELSE
    v_body := format('%s Registration is now CLOSED for %s. The organiser will publish the next operational updates here.',
      v_game_tag,NEW.name) || CASE WHEN v_role_labels IS NOT NULL THEN chr(10) || 'Event roles: ' || v_role_labels ELSE '' END;
  END IF;

  PERFORM app_private.enqueue_event_channel_announcement(
    NEW.id,'updates','event_status:' || NEW.status,v_body,coalesce(v_target_users,ARRAY[]::uuid[])
  );

  IF NEW.status='registration_closed' THEN
    PERFORM app_private.enqueue_event_notification(
      NEW.id, audience.user_id, 'registration_closed',
      'Tournament registration closed',
      NEW.name || ' registration is now closed.'
    )
    FROM (
      SELECT cm.user_id
      FROM public.community_members cm
      WHERE cm.community_id=NEW.community_id
        AND EXISTS (
          SELECT 1 FROM public.game_accounts ga
          WHERE ga.user_id=cm.user_id AND ga.game_id=NEW.game_id
            AND ga.ownership_status <> 'rejected'
        )
      UNION
      SELECT ef.user_id FROM public.event_follows ef WHERE ef.event_id=NEW.id
    ) audience;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.tournament_event_channel_lifecycle_update() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS events_tournament_lifecycle_channel_update ON public.events;
CREATE TRIGGER events_tournament_lifecycle_channel_update
AFTER INSERT OR UPDATE OF status ON public.events
FOR EACH ROW EXECUTE FUNCTION app_private.tournament_event_channel_lifecycle_update();

CREATE OR REPLACE FUNCTION app_private.tournament_group_assignment_channel_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event_id uuid;
  v_event_name text;
  v_game_code text;
  v_tag text;
  v_group_label text;
  v_group_channel text;
  v_team_name text;
  v_round_id uuid;
  v_target_users uuid[];
  v_role_labels text;
  v_body text;
BEGIN
  SELECT e.id,e.name,g.code,eg.label,eg.round_id,t.name
  INTO v_event_id,v_event_name,v_game_code,v_group_label,v_round_id,v_team_name
  FROM public.event_groups eg
  JOIN public.event_rounds r ON r.id=eg.round_id
  JOIN public.events e ON e.id=r.event_id
  JOIN public.games g ON g.id=e.game_id
  JOIN public.teams t ON t.id=NEW.team_id
  WHERE eg.id=NEW.group_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  SELECT c.name INTO v_group_channel
  FROM public.channels c
  WHERE c.group_id=NEW.group_id AND lower(c.name) LIKE '%-idp'
    AND c.archived_at IS NULL
  ORDER BY c.created_at LIMIT 1;
  IF v_group_channel IS NULL THEN RETURN NEW; END IF;

  v_tag := '#' || lower(regexp_replace(coalesce(v_game_code,'game'),'[^a-zA-Z0-9]+','_','g'));
  SELECT array_agg(DISTINCT recipients.user_id)
  INTO v_target_users
  FROM (
    SELECT tm.user_id FROM public.team_members tm WHERE tm.team_id=NEW.team_id
    UNION
    SELECT t.owner_user_id FROM public.teams t WHERE t.id=NEW.team_id
    UNION
    SELECT esa.user_id FROM public.event_staff_assignments esa
    WHERE esa.event_id=v_event_id
      AND (
        esa.scope_type='event'
        OR (esa.scope_type='stage' AND esa.stage_id=v_round_id)
        OR (esa.scope_type='group' AND esa.group_id=NEW.group_id)
      )
  ) recipients;

  SELECT string_agg(DISTINCT esa.role_key, ', ' ORDER BY esa.role_key)
  INTO v_role_labels
  FROM public.event_staff_assignments esa
  WHERE esa.event_id=v_event_id
    AND (
      esa.scope_type='event'
      OR (esa.scope_type='stage' AND esa.stage_id=v_round_id)
      OR (esa.scope_type='group' AND esa.group_id=NEW.group_id)
    );

  v_body := format(
    '%s Group assignment: %s has been placed in %s for %s. Your private IDP and slot list are in #%s. Match timings will appear in #schedule after the organiser publishes them.',
    v_tag,v_team_name,v_group_label,v_event_name,v_group_channel
  ) || CASE WHEN v_role_labels IS NOT NULL THEN chr(10) || 'Assigned event roles: ' || v_role_labels ELSE '' END;
  PERFORM app_private.enqueue_event_channel_announcement(
    v_event_id,'updates',
    'group_assignment:' || NEW.group_id::text || ':' || NEW.team_id::text,
    v_body,coalesce(v_target_users,ARRAY[]::uuid[])
  );
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.tournament_group_assignment_channel_update() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS event_group_teams_tournament_channel_update ON public.event_group_teams;
CREATE TRIGGER event_group_teams_tournament_channel_update
AFTER INSERT OR UPDATE OF group_id,team_id ON public.event_group_teams
FOR EACH ROW EXECUTE FUNCTION app_private.tournament_group_assignment_channel_update();

CREATE OR REPLACE FUNCTION app_private.tournament_stage_schedule_channel_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_event_name text;
  v_game_code text;
  v_group record;
  v_group_channel text;
  v_target_users uuid[];
  v_role_labels text;
  v_tag text;
  v_body text;
BEGIN
  IF NEW.schedule_published_at IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP='UPDATE' THEN
    IF OLD.schedule_version IS NOT DISTINCT FROM NEW.schedule_version
       AND OLD.schedule_published_at IS NOT DISTINCT FROM NEW.schedule_published_at THEN
      RETURN NEW;
    END IF;
  END IF;

  SELECT e.name,g.code INTO v_event_name,v_game_code
  FROM public.events e JOIN public.games g ON g.id=e.game_id
  WHERE e.id=NEW.event_id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  v_tag := '#' || lower(regexp_replace(coalesce(v_game_code,'game'),'[^a-zA-Z0-9]+','_','g'));

  FOR v_group IN
    SELECT eg.id,eg.label
    FROM public.event_groups eg
    WHERE eg.round_id=NEW.id
    ORDER BY eg.sort_order
  LOOP
    SELECT c.name INTO v_group_channel
    FROM public.channels c
    WHERE c.group_id=v_group.id AND lower(c.name) LIKE '%-idp'
      AND c.archived_at IS NULL
    ORDER BY c.created_at LIMIT 1;

    SELECT array_agg(DISTINCT recipients.user_id)
    INTO v_target_users
    FROM (
      SELECT tm.user_id
      FROM public.event_group_teams gt
      JOIN public.team_members tm ON tm.team_id=gt.team_id
      WHERE gt.group_id=v_group.id
      UNION
      SELECT t.owner_user_id
      FROM public.event_group_teams gt
      JOIN public.teams t ON t.id=gt.team_id
      WHERE gt.group_id=v_group.id
      UNION
      SELECT esa.user_id
      FROM public.event_staff_assignments esa
      WHERE esa.event_id=NEW.event_id
        AND (
          esa.scope_type='event'
          OR (esa.scope_type='stage' AND esa.stage_id=NEW.id)
          OR (esa.scope_type='group' AND esa.group_id=v_group.id)
        )
    ) recipients;

    SELECT string_agg(DISTINCT esa.role_key, ', ' ORDER BY esa.role_key)
    INTO v_role_labels
    FROM public.event_staff_assignments esa
    WHERE esa.event_id=NEW.event_id
      AND (
        esa.scope_type='event'
        OR (esa.scope_type='stage' AND esa.stage_id=NEW.id)
        OR (esa.scope_type='group' AND esa.group_id=v_group.id)
      );

    v_body := format(
      '%s Schedule published for %s · %s. See the official match list in #schedule and your group-specific details in #%s.',
      v_tag,v_event_name,v_group.label,coalesce(v_group_channel,'group IDP channel')
    ) || CASE WHEN v_role_labels IS NOT NULL THEN chr(10) || 'Assigned event roles: ' || v_role_labels ELSE '' END;
    PERFORM app_private.enqueue_event_channel_announcement(
      NEW.event_id,'updates',
      'stage_schedule:' || NEW.id::text || ':v' || NEW.schedule_version::text || ':' || v_group.id::text,
      v_body,coalesce(v_target_users,ARRAY[]::uuid[])
    );
  END LOOP;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.tournament_stage_schedule_channel_update() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS event_rounds_tournament_schedule_channel_update ON public.event_rounds;
CREATE TRIGGER event_rounds_tournament_schedule_channel_update
AFTER INSERT OR UPDATE OF schedule_published_at,schedule_version ON public.event_rounds
FOR EACH ROW EXECUTE FUNCTION app_private.tournament_stage_schedule_channel_update();
