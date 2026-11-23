-- Ensure the automatically generated private IDP category stays within the
-- channel_categories.name contract (2..60 characters) for long event/stage/group labels.
CREATE OR REPLACE FUNCTION app_private.provision_event_group_idp_channel(p_group_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_group public.event_groups%ROWTYPE;
  v_stage public.event_rounds%ROWTYPE;
  v_event public.events%ROWTYPE;
  v_category_id uuid;
  v_channel_id uuid;
  v_name text;
BEGIN
  SELECT * INTO v_group FROM public.event_groups WHERE id = p_group_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Event group not found'; END IF;
  SELECT * INTO v_stage FROM public.event_rounds WHERE id = v_group.round_id;
  SELECT * INTO v_event FROM public.events WHERE id = v_stage.event_id;
  IF v_event.community_id IS NULL THEN RETURN NULL; END IF;

  INSERT INTO public.channel_categories(
    community_id,name,description,position,created_by,event_id,stage_id,group_id
  ) VALUES (
    v_event.community_id,
    left(v_event.name,16) || ' · ' || left(v_stage.name,12) || ' · ' || left(v_group.label,20),
    'Private IDP and group-specific operational updates for ' || v_group.label,
    v_stage.round_number * 1000 + v_group.sort_order,
    v_event.organizer_id,v_event.id,v_stage.id,v_group.id
  )
  ON CONFLICT (group_id) WHERE group_id IS NOT NULL DO NOTHING;

  SELECT id INTO v_category_id
  FROM public.channel_categories
  WHERE group_id = p_group_id AND event_id = v_event.id;

  v_name := lower(regexp_replace(v_group.label || '-idp','[^a-zA-Z0-9-]+','-','g'));
  INSERT INTO public.channels(
    community_id,name,description,kind,is_private,created_by,
    category_id,event_id,stage_id,group_id,match_id,is_temporary
  ) VALUES (
    v_event.community_id,v_name,
    'Private group IDP/details and group-specific updates. Access is controlled by group membership and scoped staff permissions.',
    'text',true,v_event.organizer_id,
    v_category_id,v_event.id,v_stage.id,p_group_id,NULL,true
  )
  ON CONFLICT (group_id) WHERE group_id IS NOT NULL AND lower(name) LIKE '%-idp'
  DO NOTHING;

  SELECT id INTO v_channel_id
  FROM public.channels
  WHERE group_id = p_group_id AND lower(name) LIKE '%-idp'
  ORDER BY created_at
  LIMIT 1;

  INSERT INTO public.channel_members(channel_id,user_id)
  SELECT v_channel_id, roster.user_id
  FROM (
    SELECT tm.user_id
    FROM public.event_group_teams gt
    JOIN public.team_members tm ON tm.team_id = gt.team_id
    WHERE gt.group_id = p_group_id
    UNION
    SELECT t.owner_user_id
    FROM public.event_group_teams gt
    JOIN public.teams t ON t.id = gt.team_id
    WHERE gt.group_id = p_group_id
  ) roster
  WHERE v_channel_id IS NOT NULL
  ON CONFLICT DO NOTHING;

  RETURN v_channel_id;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.provision_event_group_idp_channel(uuid) FROM PUBLIC,anon,authenticated;
