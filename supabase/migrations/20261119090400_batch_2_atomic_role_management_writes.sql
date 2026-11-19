-- Batch 2: transaction-safe role definition and member assignment APIs.
CREATE OR REPLACE FUNCTION public.save_community_role(
  p_community_id uuid,
  p_role_id uuid,
  p_name text,
  p_description text,
  p_colour text,
  p_position integer,
  p_permissions jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_role_id uuid;
  v_permission record;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF NOT app_private.resolve_permission('community.manage_roles','community',p_community_id,NULL,NULL) THEN
    RAISE EXCEPTION 'You cannot manage roles in this community';
  END IF;
  IF length(trim(coalesce(p_name,''))) < 2 OR length(trim(p_name)) > 40 THEN
    RAISE EXCEPTION 'Role name must be between 2 and 40 characters';
  END IF;
  IF length(coalesce(p_description,'')) > 300 THEN RAISE EXCEPTION 'Role description is too long'; END IF;
  IF p_colour IS NULL OR p_colour !~ '^#[0-9A-Fa-f]{6}$' THEN RAISE EXCEPTION 'Role colour must be a six-digit HEX value'; END IF;
  IF p_position IS NULL OR p_position < 1 THEN RAISE EXCEPTION 'Role hierarchy position must be positive'; END IF;
  IF p_permissions IS NULL OR jsonb_typeof(p_permissions) <> 'object' THEN
    RAISE EXCEPTION 'Role permissions must be a JSON object';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_each(p_permissions) e
    WHERE jsonb_typeof(e.value) <> 'boolean'
       OR NOT EXISTS (
         SELECT 1 FROM app_private.permission_definitions d
         WHERE d.scope_type='community' AND d.permission_key=e.key
       )
  ) THEN RAISE EXCEPTION 'Permission map contains an unknown key or non-boolean value'; END IF;

  IF p_role_id IS NULL THEN
    INSERT INTO public.community_roles(community_id,name,description,colour,position,created_by)
    VALUES(p_community_id,trim(p_name),coalesce(p_description,''),upper(p_colour),p_position,auth.uid())
    RETURNING id INTO v_role_id;
  ELSE
    UPDATE public.community_roles
    SET name=trim(p_name),description=coalesce(p_description,''),colour=upper(p_colour),position=p_position
    WHERE id=p_role_id AND community_id=p_community_id AND NOT is_system AND archived_at IS NULL
    RETURNING id INTO v_role_id;
    IF v_role_id IS NULL THEN RAISE EXCEPTION 'Custom role not found, archived or immutable'; END IF;
  END IF;

  DELETE FROM public.role_permissions rp
  WHERE rp.role_id=v_role_id
    AND NOT EXISTS (SELECT 1 FROM jsonb_each(p_permissions) e WHERE e.key=rp.permission_key);

  FOR v_permission IN SELECT key,value FROM jsonb_each(p_permissions) LOOP
    INSERT INTO public.role_permissions(role_id,permission_key,allowed)
    VALUES(v_role_id,v_permission.key,(v_permission.value::text)::boolean)
    ON CONFLICT(role_id,permission_key) DO UPDATE SET allowed=EXCLUDED.allowed;
  END LOOP;
  RETURN v_role_id;
END;
$function$;
REVOKE ALL ON FUNCTION public.save_community_role(uuid,uuid,text,text,text,integer,jsonb) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.save_community_role(uuid,uuid,text,text,text,integer,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.replace_community_member_roles(
  p_community_id uuid,
  p_user_id uuid,
  p_role_ids uuid[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_role_count integer;
  v_distinct_count integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF NOT app_private.resolve_permission('community.manage_roles','community',p_community_id,NULL,NULL) THEN
    RAISE EXCEPTION 'You cannot assign community roles';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.community_members cm WHERE cm.community_id=p_community_id AND cm.user_id=p_user_id) THEN
    RAISE EXCEPTION 'Target user is not a member of this community';
  END IF;

  SELECT count(*),count(DISTINCT input_roles.role_id) INTO v_role_count,v_distinct_count
  FROM unnest(coalesce(p_role_ids,ARRAY[]::uuid[])) AS input_roles(role_id);
  IF v_role_count <> v_distinct_count THEN RAISE EXCEPTION 'Duplicate role IDs are not allowed'; END IF;
  IF EXISTS (
    SELECT 1 FROM unnest(coalesce(p_role_ids,ARRAY[]::uuid[])) AS input_roles(role_id)
    LEFT JOIN public.community_roles cr ON cr.id=input_roles.role_id AND cr.community_id=p_community_id
    WHERE cr.id IS NULL OR cr.archived_at IS NOT NULL OR cr.preset_key='owner'
  ) THEN RAISE EXCEPTION 'Every selected role must be active, assignable and belong to this community'; END IF;

  DELETE FROM public.community_member_roles cmr
  WHERE cmr.community_id=p_community_id AND cmr.user_id=p_user_id
    AND NOT (cmr.role_id=ANY(coalesce(p_role_ids,ARRAY[]::uuid[])));

  INSERT INTO public.community_member_roles(community_id,user_id,role_id,assigned_by)
  SELECT p_community_id,p_user_id,input_roles.role_id,auth.uid()
  FROM unnest(coalesce(p_role_ids,ARRAY[]::uuid[])) AS input_roles(role_id)
  WHERE NOT EXISTS (
    SELECT 1 FROM public.community_member_roles cmr
    WHERE cmr.community_id=p_community_id AND cmr.user_id=p_user_id AND cmr.role_id=input_roles.role_id
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.replace_community_member_roles(uuid,uuid,uuid[]) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.replace_community_member_roles(uuid,uuid,uuid[]) TO authenticated;
