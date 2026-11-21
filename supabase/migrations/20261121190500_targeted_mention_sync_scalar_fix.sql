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
  v_existing record;
  v_recipient_id uuid;
  v_recipient_username text;
  v_recipient_display_name text;
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
      v_recipient_id := v_existing.mentioned_user_id;
      SELECT p.username,p.display_name INTO v_recipient_username,v_recipient_display_name
      FROM public.profiles p WHERE p.id=v_recipient_id;
      v_was_removed := true;
    ELSE
      SELECT p.id,p.username,p.display_name
      INTO v_recipient_id,v_recipient_username,v_recipient_display_name
      FROM public.profiles p
      WHERE lower(p.username)=v_username;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'The mentioned username @% does not belong to a current KOMNIVO user',v_username;
      END IF;
      v_was_removed := false;
    END IF;

    IF v_recipient_id=p_sender_id THEN
      CONTINUE;
    END IF;

    IF NOT app_private.can_user_receive_channel_mention(
      v_recipient_id,p_channel_id
    ) THEN
      RAISE EXCEPTION 'The mentioned user cannot access this channel';
    END IF;

    IF v_was_removed THEN
      UPDATE public.message_mentions
      SET username_snapshot=coalesce(v_recipient_username,v_username),
          display_name_snapshot=coalesce(v_recipient_display_name,''),
          status='active',removed_at=NULL
      WHERE id=v_existing.id
      RETURNING id INTO v_mention_id;
    ELSE
      INSERT INTO public.message_mentions(
        message_id,channel_id,sender_id,mentioned_user_id,
        username_snapshot,display_name_snapshot
      ) VALUES (
        p_message_id,p_channel_id,p_sender_id,v_recipient_id,
        coalesce(v_recipient_username,v_username),
        coalesce(v_recipient_display_name,'')
      )
      RETURNING id INTO v_mention_id;
    END IF;

    INSERT INTO public.notifications(
      user_id,title,body,kind,entity_type,entity_id
    ) VALUES (
      v_recipient_id,
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

