-- Permission preview for the non-delegable Owner preset includes controlled Owner overrides.
CREATE OR REPLACE FUNCTION public.preview_community_role_permissions(p_community_id uuid, p_role_id uuid DEFAULT NULL::uuid, p_user_id uuid DEFAULT NULL::uuid, p_channel_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(permission_key text, allowed boolean, source text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_subject uuid := COALESCE(p_user_id,auth.uid());
  v_category uuid;
  v_channel_private boolean := false;
  v_has_channel_override boolean := false;
  v_member_role text;
  v_is_owner boolean := false;
  v_is_member boolean := false;
  v_channel_member boolean := false;
  v_muted boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF v_subject IS DISTINCT FROM auth.uid()
     AND NOT app_private.resolve_permission('community.manage_roles','community',p_community_id,NULL,NULL) THEN
    RAISE EXCEPTION 'Cannot preview another member';
  END IF;
  IF p_role_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.community_roles cr
    WHERE cr.id=p_role_id AND cr.community_id=p_community_id AND cr.archived_at IS NULL
  ) THEN RAISE EXCEPTION 'Role not in community or archived'; END IF;
  IF p_role_id IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.community_members cm
    WHERE cm.community_id=p_community_id AND cm.user_id=v_subject
  ) AND NOT EXISTS (
    SELECT 1 FROM public.communities c WHERE c.id=p_community_id AND c.owner_user_id=v_subject
  ) THEN RAISE EXCEPTION 'Preview subject is not a community member'; END IF;

  IF p_role_id IS NULL THEN
    SELECT c.owner_user_id=v_subject INTO v_is_owner
    FROM public.communities c WHERE c.id=p_community_id;
    SELECT cm.role INTO v_member_role FROM public.community_members cm
    WHERE cm.community_id=p_community_id AND cm.user_id=v_subject;
    v_is_member := FOUND OR v_is_owner;
    SELECT EXISTS (
      SELECT 1 FROM public.community_members cm
      WHERE cm.community_id=p_community_id AND cm.user_id=v_subject
        AND cm.muted_until IS NOT NULL AND cm.muted_until>now()
    ) INTO v_muted;
  ELSE
    SELECT cr.preset_key='owner' INTO v_is_owner FROM public.community_roles cr
    WHERE cr.id=p_role_id AND cr.community_id=p_community_id;
  END IF;

  IF p_channel_id IS NOT NULL THEN
    SELECT c.category_id,c.is_private INTO v_category,v_channel_private
    FROM public.channels c
    WHERE c.id=p_channel_id AND c.community_id=p_community_id AND c.event_id IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'Channel not in community'; END IF;
    IF p_role_id IS NULL THEN
      SELECT EXISTS(SELECT 1 FROM public.channel_members cm WHERE cm.channel_id=p_channel_id AND cm.user_id=v_subject)
      INTO v_channel_member;
    END IF;
    SELECT EXISTS (
      SELECT 1 FROM public.channel_permission_overrides o
      WHERE o.community_id=p_community_id AND o.channel_id=p_channel_id
        AND ((p_role_id IS NOT NULL AND o.role_id=p_role_id) OR
             (p_role_id IS NULL AND EXISTS (
               SELECT 1 FROM public.community_member_roles cmr
               WHERE cmr.community_id=p_community_id AND cmr.user_id=v_subject AND cmr.role_id=o.role_id
             )))
    ) INTO v_has_channel_override;
  END IF;

  RETURN QUERY
  WITH keys AS (
    SELECT d.permission_key,d.owner_override
    FROM app_private.permission_definitions d WHERE d.scope_type='community'
  ),
  grants AS (
    SELECT rp.permission_key,bool_or(rp.allowed) allow_grant,bool_or(NOT rp.allowed) deny_grant
    FROM public.role_permissions rp
    WHERE (p_role_id IS NOT NULL AND rp.role_id=p_role_id)
       OR (p_role_id IS NULL AND EXISTS (
         SELECT 1 FROM public.community_member_roles cmr
         WHERE cmr.role_id=rp.role_id AND cmr.community_id=p_community_id AND cmr.user_id=v_subject
       ))
    GROUP BY rp.permission_key
  ),
  overrides AS (
    SELECT o.permission_key,bool_or(o.effect='allow') allow_override,bool_or(o.effect='deny') deny_override
    FROM (
      SELECT cpo.permission_key,cpo.effect
      FROM public.channel_permission_overrides cpo
      WHERE p_channel_id IS NOT NULL AND v_has_channel_override
        AND cpo.community_id=p_community_id AND cpo.channel_id=p_channel_id
        AND ((p_role_id IS NOT NULL AND cpo.role_id=p_role_id) OR
             (p_role_id IS NULL AND EXISTS (
               SELECT 1 FROM public.community_member_roles cmr
               WHERE cmr.community_id=p_community_id AND cmr.user_id=v_subject AND cmr.role_id=cpo.role_id
             )))
      UNION ALL
      SELECT cpo.permission_key,cpo.effect
      FROM public.category_permission_overrides cpo
      WHERE p_channel_id IS NOT NULL AND NOT v_has_channel_override AND v_category IS NOT NULL
        AND cpo.community_id=p_community_id AND cpo.category_id=v_category
        AND ((p_role_id IS NOT NULL AND cpo.role_id=p_role_id) OR
             (p_role_id IS NULL AND EXISTS (
               SELECT 1 FROM public.community_member_roles cmr
               WHERE cmr.community_id=p_community_id AND cmr.user_id=v_subject AND cmr.role_id=cpo.role_id
             )))
    ) o GROUP BY o.permission_key
  ),
  baseline AS (
    SELECT k.permission_key,
      CASE
        WHEN p_channel_id IS NULL THEN
          CASE k.permission_key
            WHEN 'community.view' THEN true
            WHEN 'community.manage_settings' THEN v_is_owner
            WHEN 'community.manage_structure' THEN v_is_owner OR v_member_role IN ('admin','moderator','organiser')
            WHEN 'community.manage_members' THEN v_is_owner OR v_member_role IN ('admin','moderator')
            WHEN 'community.manage_invites' THEN v_is_owner OR v_member_role IN ('admin','organiser')
            WHEN 'community.manage_roles' THEN v_is_owner OR v_member_role='admin'
            WHEN 'community.manage_permissions' THEN v_is_owner
            WHEN 'community.audit.read' THEN v_is_owner
            ELSE false
          END
        ELSE
          CASE k.permission_key
            WHEN 'channel.view' THEN (NOT v_channel_private) OR (p_role_id IS NULL AND v_member_role IN ('owner','admin','moderator','organiser')) OR v_channel_member
            WHEN 'channel.read_history' THEN (NOT v_channel_private) OR (p_role_id IS NULL AND v_member_role IN ('owner','admin','moderator','organiser')) OR v_channel_member
            WHEN 'channel.send_messages' THEN ((NOT v_channel_private) OR (p_role_id IS NULL AND v_member_role IN ('owner','admin','moderator','organiser')) OR v_channel_member) AND NOT v_muted
            WHEN 'channel.react' THEN (NOT v_channel_private) OR (p_role_id IS NULL AND v_member_role IN ('owner','admin','moderator','organiser')) OR v_channel_member
            WHEN 'channel.manage_messages' THEN p_role_id IS NULL AND (v_is_owner OR v_member_role IN ('admin','moderator'))
            ELSE false
          END
      END AS base_allowed
    FROM keys k
  )
  SELECT k.permission_key,
    CASE
      WHEN v_is_owner AND k.owner_override THEN true
      WHEN o.deny_override THEN false
      WHEN o.allow_override THEN true
      WHEN g.deny_grant THEN false
      WHEN g.allow_grant THEN true
      ELSE COALESCE(b.base_allowed,false)
    END AS allowed,
    CASE
      WHEN v_is_owner AND k.owner_override THEN 'owner_override'
      WHEN o.deny_override THEN 'channel_or_category_deny'
      WHEN o.allow_override THEN 'channel_or_category_allow'
      WHEN g.deny_grant THEN 'explicit_deny'
      WHEN g.allow_grant THEN 'role_grant'
      WHEN b.base_allowed THEN 'built_in_default'
      ELSE 'not_granted'
    END AS source
  FROM keys k
  LEFT JOIN grants g ON g.permission_key=k.permission_key
  LEFT JOIN overrides o ON o.permission_key=k.permission_key
  LEFT JOIN baseline b ON b.permission_key=k.permission_key
  ORDER BY k.permission_key;
END;
$function$
;
REVOKE ALL ON FUNCTION public.preview_community_role_permissions(uuid,uuid,uuid,uuid) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.preview_community_role_permissions(uuid,uuid,uuid,uuid) TO authenticated;
