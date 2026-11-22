-- Keep the shared group match-room trigger compatible with the separate IDP channel.
CREATE OR REPLACE FUNCTION app_private.create_event_match_channel()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_community_id uuid;
  v_event_name text;
  v_stage_name text;
  v_group_label text;
  v_category_id uuid;
  v_channel_id uuid;
BEGIN
  IF NEW.stage_id IS NULL OR NEW.group_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT e.community_id,e.name,r.name,g.label
  INTO v_community_id,v_event_name,v_stage_name,v_group_label
  FROM public.events e
  JOIN public.event_rounds r ON r.id=NEW.stage_id AND r.event_id=e.id
  JOIN public.event_groups g ON g.id=NEW.group_id AND g.round_id=r.id
  WHERE e.id=NEW.event_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Match stage/group does not belong to the selected event';
  END IF;
  IF v_community_id IS NULL THEN RETURN NEW; END IF;

  INSERT INTO public.channel_categories(
    community_id,name,description,position,created_by,event_id,stage_id,group_id
  ) VALUES (
    v_community_id,
    left(v_event_name,32)||' · '||left(v_stage_name,18)||' · '||v_group_label,
    'Automatically managed private group room for '||v_stage_name||' / '||v_group_label,
    NEW.round_number*1000+COALESCE((
      SELECT eg.sort_order FROM public.event_groups eg WHERE eg.id=NEW.group_id
    ),0),
    COALESCE(NEW.host_user_id,(SELECT e.organizer_id FROM public.events e WHERE e.id=NEW.event_id)),
    NEW.event_id,NEW.stage_id,NEW.group_id
  )
  ON CONFLICT (group_id) WHERE group_id IS NOT NULL DO NOTHING;

  SELECT cc.id INTO v_category_id
  FROM public.channel_categories cc
  WHERE cc.group_id=NEW.group_id;

  INSERT INTO public.channels(
    community_id,name,description,kind,is_private,created_by,
    category_id,event_id,stage_id,group_id,match_id,is_temporary
  ) VALUES (
    v_community_id,
    lower(regexp_replace(v_group_label||'-match-room','[^a-zA-Z0-9-]+','-','g')),
    'Private group room for '||v_stage_name||' / '||v_group_label||
      '. Individual map results are tracked as separate match records.',
    'match',true,
    COALESCE(NEW.host_user_id,(SELECT e.organizer_id FROM public.events e WHERE e.id=NEW.event_id)),
    v_category_id,NEW.event_id,NEW.stage_id,NEW.group_id,NULL,true
  )
  ON CONFLICT (group_id)
    WHERE group_id IS NOT NULL AND match_id IS NULL AND kind='match'
  DO NOTHING;

  SELECT c.id INTO v_channel_id
  FROM public.channels c
  WHERE c.group_id=NEW.group_id AND c.match_id IS NULL AND c.kind='match'
  ORDER BY c.created_at
  LIMIT 1;

  INSERT INTO public.channel_members(channel_id,user_id)
  SELECT v_channel_id,rp.user_id
  FROM public.match_participants mp
  JOIN public.registration_players rp ON rp.registration_id=mp.registration_id
  WHERE mp.match_id=NEW.id AND v_channel_id IS NOT NULL
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION app_private.create_event_match_channel() FROM PUBLIC,anon,authenticated;
