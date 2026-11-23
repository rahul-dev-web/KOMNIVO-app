-- Make an active community ban authoritative for canonical community permissions.
-- Public community access is denied while the ban is active; appeals remain available
-- through their dedicated appellant-scoped RPC and policy.
DO $patch$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
BEGIN
  v_definition := pg_get_functiondef(
    'app_private.resolve_permission(text,text,uuid,uuid,uuid)'::regprocedure
  );

  v_old := $old$
    v_is_member := found or v_is_owner;

    if p_permission_key = 'community.view' then
  $old$;

  IF position(v_old in v_definition)=0 THEN
    RAISE EXCEPTION 'Could not locate the community membership resolution block';
  END IF;

  v_new := $new$
    v_is_member := found or v_is_owner;

    -- A current ban removes every membership-derived community permission.
    -- Owners are not subject to another member's restriction action.
    IF NOT v_is_owner AND EXISTS (
      SELECT 1
      FROM public.community_member_restrictions r
      WHERE r.community_id = p_scope_id
        AND r.target_user_id = v_uid
        AND r.restriction_type = 'ban'
        AND r.starts_at <= now()
        AND r.revoked_at IS NULL
        AND (r.expires_at IS NULL OR r.expires_at > now())
    ) THEN
      RETURN false;
    END IF;

    if p_permission_key = 'community.view' then
  $new$;

  EXECUTE replace(v_definition,v_old,v_new);
END;
$patch$;
