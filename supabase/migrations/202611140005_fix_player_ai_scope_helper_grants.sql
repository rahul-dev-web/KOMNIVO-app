-- Reassert the intended least-privilege grants for the Player AI scope helper.
-- Its SECURITY DEFINER body is replaced in 202611140004.
revoke all on function app_private.can_access_ai_scope(text, uuid, uuid) from public, anon;
grant execute on function app_private.can_access_ai_scope(text, uuid, uuid) to authenticated;
