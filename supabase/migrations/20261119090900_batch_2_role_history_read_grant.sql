-- Allow authenticated requests to reach the role-history table; RLS still restricts rows to authorised audit readers.
GRANT SELECT ON public.community_role_history TO authenticated;
REVOKE INSERT,UPDATE,DELETE ON public.community_role_history FROM anon,authenticated;
