-- Preview an unsaved custom-role draft without persisting any permission changes.
CREATE OR REPLACE FUNCTION public.preview_community_role_draft_permissions(
  p_community_id uuid,
  p_role_id uuid,
  p_permissions jsonb,
  p_channel_id uuid DEFAULT NULL
)
RETURNS TABLE(permission_key text,allowed boolean,source text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_category_id uuid;
  v_channel_private boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF NOT app_private.resolve_permission('community.manage_roles','community',p_community_id,NULL,NULL) THEN
    RAISE EXCEPTION 'You cannot preview a role draft in this community';
  END IF;
  IF p_role_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.community_roles cr
    WHERE cr.id=p_role_id AND cr.community_id=p_community_id
      AND cr.archived_at IS NULL AND NOT cr.is_system
      AND cr.position < app_private.community_authority_rank(p_community_id)
  ) THEN
    RAISE EXCEPTION 'Draft role is not editable or is at/above your hierarchy level';
  END IF;
  IF p_permissions IS NULL OR jsonb_typeof(p_permissions)<>'object' THEN
    RAISE EXCEPTION 'Draft permissions must be a JSON object';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_each(p_permissions) e
    WHERE jsonb_typeof(e.value)<>'boolean'
       OR NOT EXISTS (
         SELECT 1 FROM app_private.permission_definitions d
         WHERE d.scope_type='community' AND d.permission_key=e.key
       )
  ) THEN RAISE EXCEPTION 'Draft contains an unknown permission or non-boolean value'; END IF;

  IF p_channel_id IS NOT NULL THEN
    SELECT c.category_id,c.is_private
      INTO v_category_id,v_channel_private
    FROM public.channels c
    WHERE c.id=p_channel_id AND c.community_id=p_community_id AND c.event_id IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'Channel not in community'; END IF;
  END IF;

  RETURN QUERY
  WITH keys AS (
    SELECT d.permission_key FROM app_private.permission_definitions d
    WHERE d.scope_type='community'
  ),
  overrides AS (
    SELECT o.permission_key,bool_or(o.effect='allow') allow_override,bool_or(o.effect='deny') deny_override
    FROM (
      SELECT cpo.permission_key,cpo.effect
      FROM public.channel_permission_overrides cpo
      WHERE p_role_id IS NOT NULL AND p_channel_id IS NOT NULL
        AND cpo.community_id=p_community_id AND cpo.channel_id=p_channel_id
        AND cpo.role_id=p_role_id
      UNION ALL
      SELECT cpo.permission_key,cpo.effect
      FROM public.category_permission_overrides cpo
      WHERE p_role_id IS NOT NULL AND p_channel_id IS NOT NULL
        AND v_category_id IS NOT NULL
        AND cpo.community_id=p_community_id AND cpo.category_id=v_category_id
        AND cpo.role_id=p_role_id
        AND NOT EXISTS (
          SELECT 1 FROM public.channel_permission_overrides direct
          WHERE direct.community_id=p_community_id AND direct.channel_id=p_channel_id
            AND direct.role_id=p_role_id AND direct.permission_key=cpo.permission_key
        )
    ) o GROUP BY o.permission_key
  ),
  baseline AS (
    SELECT k.permission_key,
      CASE
        WHEN k.permission_key='community.view' THEN true
        WHEN k.permission_key='channel.view' THEN p_channel_id IS NOT NULL AND NOT v_channel_private
        WHEN k.permission_key='channel.read_history' THEN p_channel_id IS NOT NULL AND NOT v_channel_private
        WHEN k.permission_key='channel.send_messages' THEN p_channel_id IS NOT NULL AND NOT v_channel_private
        WHEN k.permission_key='channel.react' THEN p_channel_id IS NOT NULL AND NOT v_channel_private
        ELSE false
      END base_allowed
    FROM keys k
  )
  SELECT k.permission_key,
    CASE
      WHEN o.deny_override THEN false
      WHEN o.allow_override THEN true
      WHEN p_permissions ? k.permission_key THEN (p_permissions->>k.permission_key)::boolean
      ELSE b.base_allowed
    END allowed,
    CASE
      WHEN o.deny_override THEN 'channel_or_category_deny'
      WHEN o.allow_override THEN 'channel_or_category_allow'
      WHEN p_permissions ? k.permission_key AND (p_permissions->>k.permission_key)::boolean THEN 'draft_allow'
      WHEN p_permissions ? k.permission_key THEN 'draft_deny'
      WHEN b.base_allowed THEN 'built_in_default'
      ELSE 'not_granted'
    END source
  FROM keys k
  LEFT JOIN overrides o ON o.permission_key=k.permission_key
  LEFT JOIN baseline b ON b.permission_key=k.permission_key
  ORDER BY k.permission_key;
END;
$function$;
REVOKE ALL ON FUNCTION public.preview_community_role_draft_permissions(uuid,uuid,jsonb,uuid) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.preview_community_role_draft_permissions(uuid,uuid,jsonb,uuid) TO authenticated;
