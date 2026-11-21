-- Targeted @username mentions. No Tags channel and no channel-wide mention fallback.
-- Recipient eligibility is evaluated for the target user, not inferred from the sender's RLS context.

CREATE OR REPLACE FUNCTION app_private.can_user_receive_channel_mention(
  p_user_id uuid,
  p_channel_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_channel public.channels%ROWTYPE;
  v_owner_id uuid;
  v_member_role text;
  v_is_owner boolean := false;
  v_custom_allowed boolean := false;
  v_custom_denied boolean := false;
  v_override_allowed boolean := false;
  v_override_denied boolean := false;
  v_direct_override_found boolean := false;
  v_event_organizer uuid;
  v_event_status text;
  v_match_stage uuid;
  v_match_group uuid;
  v_group_stage uuid;
BEGIN
  IF p_user_id IS NULL OR p_channel_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT * INTO v_channel
  FROM public.channels c
  WHERE c.id=p_channel_id AND c.archived_at IS NULL;
  IF NOT FOUND THEN RETURN false; END IF;

  IF v_channel.event_id IS NULL THEN
    IF v_channel.community_id IS NULL THEN
      RETURN EXISTS (
        SELECT 1 FROM public.channel_members cm
        WHERE cm.channel_id=p_channel_id AND cm.user_id=p_user_id
      );
    END IF;

    SELECT c.owner_user_id INTO v_owner_id
    FROM public.communities c WHERE c.id=v_channel.community_id;
    IF NOT FOUND THEN RETURN false; END IF;

    v_is_owner := v_owner_id=p_user_id;
    SELECT cm.role INTO v_member_role
    FROM public.community_members cm
    WHERE cm.community_id=v_channel.community_id AND cm.user_id=p_user_id;

    IF NOT FOUND AND NOT v_is_owner THEN RETURN false; END IF;

    IF NOT v_is_owner AND EXISTS (
      SELECT 1 FROM public.community_member_restrictions r
      WHERE r.community_id=v_channel.community_id
        AND r.target_user_id=p_user_id
        AND r.restriction_type='ban'
        AND r.revoked_at IS NULL
        AND (r.expires_at IS NULL OR r.expires_at>now())
    ) THEN
      RETURN false;
    END IF;

    SELECT
      coalesce(bool_or(rp.allowed),false),
      coalesce(bool_or(NOT rp.allowed),false)
    INTO v_custom_allowed,v_custom_denied
    FROM public.community_member_roles cmr
    JOIN public.role_permissions rp ON rp.role_id=cmr.role_id
    WHERE cmr.community_id=v_channel.community_id
      AND cmr.user_id=p_user_id
      AND rp.permission_key='channel.view';

    SELECT EXISTS (
      SELECT 1
      FROM public.channel_permission_overrides cpo
      JOIN public.community_member_roles cmr
        ON cmr.role_id=cpo.role_id
       AND cmr.community_id=cpo.community_id
       AND cmr.user_id=p_user_id
      WHERE cpo.community_id=v_channel.community_id
        AND cpo.channel_id=p_channel_id
        AND cpo.permission_key='channel.view'
    ) INTO v_direct_override_found;

    IF v_direct_override_found THEN
      SELECT
        coalesce(bool_or(cpo.effect='allow'),false),
        coalesce(bool_or(cpo.effect='deny'),false)
      INTO v_override_allowed,v_override_denied
      FROM public.channel_permission_overrides cpo
      JOIN public.community_member_roles cmr
        ON cmr.role_id=cpo.role_id
       AND cmr.community_id=cpo.community_id
       AND cmr.user_id=p_user_id
      WHERE cpo.community_id=v_channel.community_id
        AND cpo.channel_id=p_channel_id
        AND cpo.permission_key='channel.view';
    ELSIF v_channel.category_id IS NOT NULL THEN
      SELECT
        coalesce(bool_or(cpo.effect='allow'),false),
        coalesce(bool_or(cpo.effect='deny'),false)
      INTO v_override_allowed,v_override_denied
      FROM public.category_permission_overrides cpo
      JOIN public.community_member_roles cmr
        ON cmr.role_id=cpo.role_id
       AND cmr.community_id=cpo.community_id
       AND cmr.user_id=p_user_id
      WHERE cpo.community_id=v_channel.community_id
        AND cpo.category_id=v_channel.category_id
        AND cpo.permission_key='channel.view';
    END IF;

    IF (v_custom_denied OR v_override_denied) AND NOT v_is_owner THEN
      RETURN false;
    END IF;
    IF v_is_owner THEN RETURN true; END IF;

    RETURN (NOT v_channel.is_private)
      OR v_member_role IN ('owner','admin','moderator','organiser')
      OR EXISTS (
        SELECT 1 FROM public.channel_members cm
        WHERE cm.channel_id=p_channel_id AND cm.user_id=p_user_id
      )
      OR v_custom_allowed
      OR v_override_allowed;
  END IF;

  SELECT e.organizer_id,e.status
  INTO v_event_organizer,v_event_status
  FROM public.events e
  WHERE e.id=v_channel.event_id;
  IF NOT FOUND THEN RETURN false; END IF;

  IF v_channel.match_id IS NOT NULL THEN
    SELECT m.stage_id,m.group_id
    INTO v_match_stage,v_match_group
    FROM public.matches m
    WHERE m.id=v_channel.match_id AND m.event_id=v_channel.event_id;

    IF NOT FOUND
       OR (v_channel.stage_id IS NOT NULL AND v_channel.stage_id IS DISTINCT FROM v_match_stage)
       OR (v_channel.group_id IS NOT NULL AND v_channel.group_id IS DISTINCT FROM v_match_group) THEN
      RETURN false;
    END IF;

    RETURN p_user_id=v_event_organizer
      OR EXISTS (
        SELECT 1 FROM public.matches m
        WHERE m.id=v_channel.match_id AND m.host_user_id=p_user_id
      )
      OR EXISTS (
        SELECT 1
        FROM public.match_participants mp
        JOIN public.team_members tm ON tm.team_id=mp.team_id
        WHERE mp.match_id=v_channel.match_id AND tm.user_id=p_user_id
      )
      OR EXISTS (
        SELECT 1 FROM public.event_staff_assignments a
        WHERE a.event_id=v_channel.event_id
          AND a.user_id=p_user_id
          AND (
            (a.scope_type='event' AND a.role_key=ANY(ARRAY[
              'competition_manager','tournament_director','referee',
              'result_reviewer','dispute_reviewer'
            ]::text[]))
            OR (a.scope_type='stage' AND a.stage_id=v_match_stage
              AND a.role_key=ANY(ARRAY[
                'competition_manager','tournament_director','match_operator',
                'referee','result_reviewer','dispute_reviewer','support_staff'
              ]::text[]))
            OR (a.scope_type='group' AND a.group_id=v_match_group
              AND a.role_key=ANY(ARRAY[
                'match_operator','referee','result_reviewer',
                'dispute_reviewer','support_staff'
              ]::text[]))
            OR (a.scope_type='match' AND a.match_id=v_channel.match_id
              AND a.role_key=ANY(ARRAY[
                'match_operator','referee','result_reviewer','dispute_reviewer',
                'support_staff','caster','streamer'
              ]::text[]))
          )
      );
  END IF;

  IF v_channel.group_id IS NOT NULL THEN
    SELECT r.id INTO v_group_stage
    FROM public.event_groups g
    JOIN public.event_rounds r ON r.id=g.round_id
    WHERE g.id=v_channel.group_id AND r.event_id=v_channel.event_id;

    IF NOT FOUND OR
       (v_channel.stage_id IS NOT NULL AND v_channel.stage_id IS DISTINCT FROM v_group_stage) THEN
      RETURN false;
    END IF;

    RETURN v_event_status IN ('published','registration_open','registration_closed','live','completed')
      OR p_user_id=v_event_organizer
      OR EXISTS (
        SELECT 1 FROM public.event_group_teams gt
        JOIN public.team_members tm ON tm.team_id=gt.team_id
        WHERE gt.group_id=v_channel.group_id AND tm.user_id=p_user_id
      )
      OR EXISTS (
        SELECT 1 FROM public.event_staff_assignments a
        WHERE a.event_id=v_channel.event_id AND a.user_id=p_user_id
          AND (
            (a.scope_type='event' AND a.role_key=ANY(ARRAY[
              'competition_manager','tournament_director','referee',
              'result_reviewer','dispute_reviewer'
            ]::text[]))
            OR (a.scope_type='stage' AND a.stage_id=v_group_stage
              AND a.role_key=ANY(ARRAY[
                'competition_manager','tournament_director','match_operator',
                'referee','result_reviewer','dispute_reviewer','support_staff'
              ]::text[]))
            OR (a.scope_type='group' AND a.group_id=v_channel.group_id
              AND a.role_key=ANY(ARRAY[
                'match_operator','referee','result_reviewer',
                'dispute_reviewer','support_staff'
              ]::text[]))
          )
      );
  END IF;

  IF v_channel.stage_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.event_rounds r
      WHERE r.id=v_channel.stage_id AND r.event_id=v_channel.event_id
    ) THEN
      RETURN false;
    END IF;

    IF v_channel.is_private THEN
      RETURN p_user_id=v_event_organizer
        OR EXISTS (
          SELECT 1 FROM public.event_staff_assignments a
          WHERE a.event_id=v_channel.event_id
            AND a.user_id=p_user_id
            AND (
              (a.scope_type='event' AND a.role_key=ANY(ARRAY[
                'competition_manager','tournament_director'
              ]::text[]))
              OR (a.scope_type='stage' AND a.stage_id=v_channel.stage_id
                AND a.role_key=ANY(ARRAY[
                  'competition_manager','tournament_director','match_operator',
                  'referee','result_reviewer','dispute_reviewer','support_staff'
                ]::text[]))
            )
        );
    END IF;

    RETURN v_event_status IN ('published','registration_open','registration_closed','live','completed')
      OR p_user_id=v_event_organizer
      OR EXISTS (
        SELECT 1 FROM public.event_staff_assignments a
        WHERE a.event_id=v_channel.event_id AND a.user_id=p_user_id
          AND (
            (a.scope_type='event' AND a.role_key=ANY(ARRAY[
              'competition_manager','tournament_director','referee',
              'result_reviewer','dispute_reviewer'
            ]::text[]))
            OR (a.scope_type='stage' AND a.stage_id=v_channel.stage_id
              AND a.role_key=ANY(ARRAY[
                'competition_manager','tournament_director','match_operator',
                'referee','result_reviewer','dispute_reviewer','support_staff',
                'caster','streamer'
              ]::text[]))
          )
      )
      OR EXISTS (
        SELECT 1
        FROM public.event_groups g
        JOIN public.event_group_teams gt ON gt.group_id=g.id
        JOIN public.team_members tm ON tm.team_id=gt.team_id
        WHERE g.round_id=v_channel.stage_id AND tm.user_id=p_user_id
      );
  END IF;

  -- Root event channel. Private channels are limited to the organiser and
  -- event-scoped staff. Public channels follow event.view eligibility.
  IF v_channel.is_private THEN
    RETURN p_user_id=v_event_organizer
      OR EXISTS (
        SELECT 1 FROM public.event_staff_assignments a
        WHERE a.event_id=v_channel.event_id
          AND a.user_id=p_user_id
          AND a.scope_type='event'
      );
  END IF;

  RETURN v_event_status IN ('published','registration_open','registration_closed','live','completed')
    OR p_user_id=v_event_organizer
    OR EXISTS (
      SELECT 1 FROM public.event_staff_assignments a
      WHERE a.event_id=v_channel.event_id AND a.user_id=p_user_id
    )
    OR EXISTS (
      SELECT 1 FROM public.event_registrations er
      WHERE er.event_id=v_channel.event_id
        AND (
          er.captain_user_id=p_user_id
          OR (er.team_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.team_members tm
            WHERE tm.team_id=er.team_id AND tm.user_id=p_user_id
          ))
          OR EXISTS (
            SELECT 1 FROM public.registration_players rp
            WHERE rp.registration_id=er.id AND rp.user_id=p_user_id
          )
        )
    );
END;
$function$;

REVOKE ALL ON FUNCTION app_private.can_user_receive_channel_mention(uuid,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.can_user_receive_channel_mention(uuid,uuid)
  TO service_role;

CREATE TABLE IF NOT EXISTS public.message_mentions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
  channel_id uuid NOT NULL REFERENCES public.channels(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  mentioned_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  username_snapshot text NOT NULL,
  display_name_snapshot text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','removed')),
  notification_id uuid REFERENCES public.notifications(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  removed_at timestamptz,
  UNIQUE(message_id,mentioned_user_id),
  CHECK ((status='active' AND removed_at IS NULL) OR status='removed')
);

CREATE INDEX IF NOT EXISTS message_mentions_recipient_time_idx
  ON public.message_mentions(mentioned_user_id,created_at DESC);
CREATE INDEX IF NOT EXISTS message_mentions_channel_time_idx
  ON public.message_mentions(channel_id,created_at DESC);

ALTER TABLE public.message_mentions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.message_mentions FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.message_mentions TO authenticated;
DROP POLICY IF EXISTS message_mentions_read_recipient_or_author
  ON public.message_mentions;
CREATE POLICY message_mentions_read_recipient_or_author
  ON public.message_mentions
  FOR SELECT TO authenticated
  USING (
    mentioned_user_id=(SELECT auth.uid())
    OR sender_id=(SELECT auth.uid())
  );

CREATE OR REPLACE FUNCTION public.channel_mention_candidates(
  p_channel_id uuid,
  p_query text DEFAULT ''
)
RETURNS TABLE(
  user_id uuid,
  username text,
  display_name text,
  avatar_url text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_query text := lower(trim(both '@' from coalesce(p_query,'')));
  v_allow_mentions boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_channel_id IS NULL OR NOT app_private.can_send_channel_message(p_channel_id) THEN
    RAISE EXCEPTION 'You cannot mention users in this channel' USING errcode='42501';
  END IF;

  SELECT coalesce(cs.allow_user_mentions,true)
  INTO v_allow_mentions
  FROM public.channels c
  LEFT JOIN public.channel_settings cs ON cs.channel_id=c.id
  WHERE c.id=p_channel_id AND c.archived_at IS NULL;

  IF NOT FOUND OR NOT v_allow_mentions THEN
    RETURN;
  END IF;
  IF length(v_query)<1 THEN RETURN; END IF;

  RETURN QUERY
  SELECT p.id,p.username,p.display_name,p.avatar_url
  FROM public.profiles p
  WHERE p.id<>auth.uid()
    AND p.username IS NOT NULL
    AND (
      position(v_query in lower(p.username))>0
      OR position(v_query in lower(coalesce(p.display_name,'')))>0
    )
    AND app_private.can_user_receive_channel_mention(p.id,p_channel_id)
  ORDER BY
    CASE WHEN lower(p.username) LIKE v_query||'%' THEN 0 ELSE 1 END,
    lower(p.username)
  LIMIT 25;
END;
$function$;

REVOKE ALL ON FUNCTION public.channel_mention_candidates(uuid,text)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.channel_mention_candidates(uuid,text)
  TO authenticated;

CREATE OR REPLACE FUNCTION app_private.sync_message_mentions(
  p_message_id uuid,
  p_channel_id uuid,
  p_sender_id uuid,
  p_body text,
  p_deleted boolean DEFAULT false
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_channel public.channels%ROWTYPE;
  v_sender_name text;
  v_recipient record;
  v_existing record;
  v_username text;
  v_mention_id uuid;
  v_notification_id uuid;
  v_tokens text[] := ARRAY[]::text[];
  v_removed_this_pass uuid[] := ARRAY[]::uuid[];
  v_changed integer := 0;
  v_was_removed boolean;
  v_setting_allows boolean;
BEGIN
  SELECT * INTO v_channel FROM public.channels c WHERE c.id=p_channel_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Message channel no longer exists'; END IF;

  SELECT coalesce(cs.allow_user_mentions,true) INTO v_setting_allows
  FROM public.channel_settings cs WHERE cs.channel_id=p_channel_id;
  IF NOT FOUND THEN v_setting_allows := true; END IF;

  SELECT coalesce(p.display_name,p.username,'A member') INTO v_sender_name
  FROM public.profiles p WHERE p.id=p_sender_id;
  v_sender_name := coalesce(v_sender_name,'A member');

  IF NOT p_deleted AND coalesce(p_body,'') <> '' THEN
    SELECT coalesce(array_agg(DISTINCT lower((matches)[2])),ARRAY[]::text[])
    INTO v_tokens
    FROM regexp_matches(
      p_body,
      '(^|[^[:alnum:]_.-])@([A-Za-z0-9_.-]{2,32})([^[:alnum:]_.-]|$)',
      'g'
    ) AS matches
    WHERE lower((matches)[2]) NOT IN ('everyone','here');
  END IF;

  IF cardinality(v_tokens)>0 AND NOT v_setting_allows THEN
    RAISE EXCEPTION 'User mentions are disabled in this channel';
  END IF;

  -- Removed mentions and access revocations are retained in the snapshot and
  -- receive a correction notice. Their history is never silently erased.
  FOR v_existing IN
    SELECT mm.id,mm.mentioned_user_id,mm.username_snapshot
    FROM public.message_mentions mm
    WHERE mm.message_id=p_message_id AND mm.status='active'
  LOOP
    IF p_deleted
       OR NOT (lower(v_existing.username_snapshot)=ANY(v_tokens))
       OR NOT app_private.can_user_receive_channel_mention(
            v_existing.mentioned_user_id,p_channel_id
          ) THEN
      UPDATE public.message_mentions
      SET status='removed',removed_at=now()
      WHERE id=v_existing.id;

      v_removed_this_pass := array_append(v_removed_this_pass,v_existing.mentioned_user_id);

      INSERT INTO public.notifications(
        user_id,title,body,kind,entity_type,entity_id
      ) VALUES (
        v_existing.mentioned_user_id,
        'Mention correction',
        CASE WHEN p_deleted
          THEN 'A message you were mentioned in was deleted.'
          ELSE 'A message you were mentioned in was edited and no longer mentions you.'
        END,
        'mention_correction','message',p_message_id
      );
      v_changed := v_changed+1;
    END IF;
  END LOOP;

  IF p_deleted THEN RETURN v_changed; END IF;

  FOR v_username IN
    SELECT DISTINCT lower((matches)[2])
    FROM regexp_matches(
      coalesce(p_body,''),
      '(^|[^[:alnum:]_.-])@([A-Za-z0-9_.-]{2,32})([^[:alnum:]_.-]|$)',
      'g'
    ) AS matches
    WHERE lower((matches)[2]) NOT IN ('everyone','here')
  LOOP
    SELECT mm.id,mm.mentioned_user_id,mm.status
    INTO v_existing
    FROM public.message_mentions mm
    WHERE mm.message_id=p_message_id
      AND lower(mm.username_snapshot)=v_username
    LIMIT 1;

    IF FOUND AND v_existing.status='active' THEN
      CONTINUE;
    END IF;

    IF FOUND AND v_existing.status='removed'
       AND v_existing.mentioned_user_id=ANY(v_removed_this_pass) THEN
      -- The same edit removed access and left the textual token behind.
      -- Do not turn that into a fresh mention or block unrelated edits.
      CONTINUE;
    END IF;

    IF FOUND THEN
      v_recipient.user_id := v_existing.mentioned_user_id;
      SELECT p.username,p.display_name INTO v_recipient.username,v_recipient.display_name
      FROM public.profiles p WHERE p.id=v_recipient.user_id;
      v_was_removed := true;
    ELSE
      SELECT p.id,p.username,p.display_name
      INTO v_recipient.user_id,v_recipient.username,v_recipient.display_name
      FROM public.profiles p
      WHERE lower(p.username)=v_username;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'The mentioned username @% does not belong to a current KOMNIVO user',v_username;
      END IF;
      v_was_removed := false;
    END IF;

    IF v_recipient.user_id=p_sender_id THEN
      CONTINUE;
    END IF;

    IF NOT app_private.can_user_receive_channel_mention(
      v_recipient.user_id,p_channel_id
    ) THEN
      RAISE EXCEPTION 'The mentioned user cannot access this channel';
    END IF;

    IF v_was_removed THEN
      UPDATE public.message_mentions
      SET username_snapshot=coalesce(v_recipient.username,v_username),
          display_name_snapshot=coalesce(v_recipient.display_name,''),
          status='active',removed_at=NULL
      WHERE id=v_existing.id
      RETURNING id INTO v_mention_id;
    ELSE
      INSERT INTO public.message_mentions(
        message_id,channel_id,sender_id,mentioned_user_id,
        username_snapshot,display_name_snapshot
      ) VALUES (
        p_message_id,p_channel_id,p_sender_id,v_recipient.user_id,
        coalesce(v_recipient.username,v_username),
        coalesce(v_recipient.display_name,'')
      )
      RETURNING id INTO v_mention_id;
    END IF;

    INSERT INTO public.notifications(
      user_id,title,body,kind,entity_type,entity_id
    ) VALUES (
      v_recipient.user_id,
      'You were mentioned in #'||v_channel.name,
      v_sender_name||' mentioned you in #'||v_channel.name||'.',
      'mention','message',p_message_id
    )
    RETURNING id INTO v_notification_id;

    UPDATE public.message_mentions
    SET notification_id=v_notification_id
    WHERE id=v_mention_id;

    v_changed := v_changed+1;
  END LOOP;

  RETURN v_changed;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.sync_message_mentions(uuid,uuid,uuid,text,boolean)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.sync_message_mentions(uuid,uuid,uuid,text,boolean)
  TO service_role;

CREATE OR REPLACE FUNCTION app_private.notify_channel_members()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_channel public.channels%ROWTYPE;
BEGIN
  SELECT * INTO v_channel
  FROM public.channels c WHERE c.id=NEW.channel_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  PERFORM app_private.sync_message_mentions(
    NEW.id,NEW.channel_id,NEW.sender_id,NEW.body,false
  );

  IF v_channel.community_id IS NOT NULL AND NOT v_channel.is_private THEN
    INSERT INTO public.notifications(user_id,title,body,kind,entity_type,entity_id)
    SELECT cm.user_id,'New message in '||v_channel.name,
      left(NEW.body,180),'message','channel',NEW.channel_id
    FROM public.community_members cm
    WHERE cm.community_id=v_channel.community_id
      AND cm.user_id<>NEW.sender_id
      AND NOT EXISTS (
        SELECT 1 FROM public.message_mentions mm
        WHERE mm.message_id=NEW.id
          AND mm.mentioned_user_id=cm.user_id
          AND mm.status='active'
      );
  ELSE
    INSERT INTO public.notifications(user_id,title,body,kind,entity_type,entity_id)
    SELECT cm.user_id,'New message in '||v_channel.name,
      left(NEW.body,180),'message','channel',NEW.channel_id
    FROM public.channel_members cm
    WHERE cm.channel_id=NEW.channel_id
      AND cm.user_id<>NEW.sender_id
      AND NOT EXISTS (
        SELECT 1 FROM public.message_mentions mm
        WHERE mm.message_id=NEW.id
          AND mm.mentioned_user_id=cm.user_id
          AND mm.status='active'
      );
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION app_private.sync_message_mentions_after_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  PERFORM app_private.sync_message_mentions(
    NEW.id,NEW.channel_id,NEW.sender_id,NEW.body,NEW.deleted_at IS NOT NULL
  );
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.sync_message_mentions_after_update()
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.sync_message_mentions_after_update()
  TO service_role;

DROP TRIGGER IF EXISTS messages_sync_mentions_after_update ON public.messages;
CREATE TRIGGER messages_sync_mentions_after_update
  AFTER UPDATE OF body,deleted_at ON public.messages
  FOR EACH ROW
  WHEN (OLD.body IS DISTINCT FROM NEW.body OR OLD.deleted_at IS DISTINCT FROM NEW.deleted_at)
  EXECUTE FUNCTION app_private.sync_message_mentions_after_update();

COMMENT ON TABLE public.message_mentions IS
  'Immutable identity snapshot for targeted @username mentions. Status tracks removal and correction notices; no channel-wide Tags channel is used.';
COMMENT ON FUNCTION public.channel_mention_candidates(uuid,text) IS
  'Returns only users who can view the exact channel and are eligible for a targeted @username mention. Requires current sender permission and allow_user_mentions.';
