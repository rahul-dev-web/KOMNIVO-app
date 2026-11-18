-- Tighten custom-role assignment and grant use of the immutable weekday validator.
GRANT EXECUTE ON FUNCTION app_private.valid_days_of_week(smallint[]) TO authenticated, service_role;

DROP POLICY IF EXISTS community_member_roles_write_admin ON public.community_member_roles;
CREATE POLICY community_member_roles_write_admin ON public.community_member_roles
FOR ALL TO authenticated
USING (app_private.can_manage_community_roles(community_id))
WITH CHECK (
  app_private.can_manage_community_roles(community_id)
  AND EXISTS (
    SELECT 1
    FROM public.community_members cm
    WHERE cm.community_id = public.community_member_roles.community_id
      AND cm.user_id = public.community_member_roles.user_id
  )
);

