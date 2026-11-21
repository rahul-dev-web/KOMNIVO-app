-- Tournament root notice boards are organiser-published, not merely event-staff writable.
CREATE OR REPLACE FUNCTION app_private.guard_batch3_channel_message()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_settings public.channel_settings%ROWTYPE;
  v_last_sent timestamptz;
  v_channel public.channels%ROWTYPE;
  v_can_manage boolean;
  v_can_publish_event_channel boolean;
  v_announcement_publishers_only boolean;
BEGIN
  IF app_private.is_batch3_maintenance_context() THEN RETURN NEW; END IF;

  SELECT * INTO v_channel
  FROM public.channels c
  WHERE c.id=NEW.channel_id AND c.archived_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Channel is unavailable or archived'; END IF;

  SELECT * INTO v_settings FROM public.channel_settings WHERE channel_id=NEW.channel_id;

  v_can_manage := CASE
    WHEN v_channel.event_id IS NOT NULL THEN app_private.can_manage_event_channel(v_channel.id)
    ELSE app_private.resolve_permission('channel.manage_messages','community',v_channel.community_id,NULL,v_channel.id)
  END;

  v_announcement_publishers_only := CASE
    WHEN v_settings.channel_id IS NULL THEN v_channel.kind='announcement'
    ELSE v_settings.announcement_publishers_only
  END;

  v_can_publish_event_channel := v_can_manage;
  IF v_channel.event_id IS NOT NULL
     AND v_channel.stage_id IS NULL
     AND v_channel.group_id IS NULL
     AND v_channel.match_id IS NULL
     AND (coalesce(v_settings.read_only,false) OR v_announcement_publishers_only) THEN
    v_can_publish_event_channel := app_private.resolve_permission(
      'event.manage','event',v_channel.event_id,NULL,NULL
    );
  END IF;

  IF v_settings.channel_id IS NOT NULL
     AND v_settings.read_only
     AND NOT v_can_publish_event_channel THEN
    RAISE EXCEPTION 'This channel is read-only';
  END IF;

  IF NOT app_private.can_send_channel_message(NEW.channel_id) AND NOT v_can_manage
  THEN RAISE EXCEPTION 'You cannot send messages in this channel'; END IF;

  IF NEW.parent_message_id IS NOT NULL AND v_settings.channel_id IS NOT NULL
     AND NOT v_settings.allow_threads AND NOT v_can_manage THEN
    RAISE EXCEPTION 'Message threads are disabled in this channel';
  END IF;

  IF v_announcement_publishers_only AND NOT v_can_publish_event_channel
  THEN RAISE EXCEPTION 'Only authorised organisers can publish in this channel'; END IF;

  IF v_settings.channel_id IS NOT NULL THEN
    IF NOT v_settings.allow_links AND NEW.body ~* '(https?://|www[.])'
    THEN RAISE EXCEPTION 'Links are disabled in this channel'; END IF;
    IF NOT v_settings.allow_everyone_mention
       AND NEW.body ~* '(^|[[:space:]])@(everyone|here)([[:space:]]|$)' THEN
      RAISE EXCEPTION 'Broad mentions are disabled in this channel';
    END IF;
    IF NOT v_settings.allow_role_mentions AND NEW.body ~ '<@&[0-9a-fA-F-]{36}>' THEN
      RAISE EXCEPTION 'Role mentions are disabled in this channel';
    END IF;
    IF NOT v_settings.allow_user_mentions AND NEW.body ~ '<@[0-9a-fA-F-]{36}>' THEN
      RAISE EXCEPTION 'User mentions are disabled in this channel';
    END IF;

    IF v_settings.slow_mode_seconds > 0 AND NOT v_can_manage THEN
      PERFORM pg_advisory_xact_lock(hashtextextended(NEW.channel_id::text||':'||NEW.sender_id::text,0));
      SELECT max(m.created_at) INTO v_last_sent
      FROM public.messages m
      WHERE m.channel_id=NEW.channel_id AND m.sender_id=NEW.sender_id AND m.deleted_at IS NULL;
      IF v_last_sent IS NOT NULL
         AND v_last_sent > now() - make_interval(secs => v_settings.slow_mode_seconds) THEN
        RAISE EXCEPTION 'Slow mode is active. Please wait before sending again';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.guard_batch3_channel_message() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.guard_batch3_channel_message() TO service_role;
