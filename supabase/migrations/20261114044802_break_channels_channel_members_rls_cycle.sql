-- Break the channels <-> channel_members RLS dependency.
-- The channels SELECT policy previously queried public.channel_members
-- directly. channel_members policies query public.channels, causing
-- PostgreSQL SQLSTATE 42P17 during RLS policy expansion.
--
-- This helper reads channel_members with the privileges of its postgres
-- owner, bypassing that table's RLS only for this narrow membership lookup.

CREATE OR REPLACE FUNCTION app_private.is_channel_member(p_channel_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.channel_members AS cm
    WHERE cm.channel_id = p_channel_id
      AND cm.user_id = (SELECT auth.uid())
  );
$function$;

REVOKE ALL ON FUNCTION app_private.is_channel_member(uuid) FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA app_private TO authenticated;
GRANT EXECUTE ON FUNCTION app_private.is_channel_member(uuid) TO authenticated;

DROP POLICY IF EXISTS channels_read_member ON public.channels;

CREATE POLICY channels_read_member
ON public.channels
FOR SELECT
TO authenticated
USING (
  (
    community_id IS NOT NULL
    AND app_private.is_community_member(community_id)
    AND (
      NOT is_private
      OR app_private.can_manage_community(community_id)
      OR app_private.is_channel_member(id)
    )
  )
  OR
  (
    community_id IS NULL
    AND app_private.is_channel_member(id)
  )
);
