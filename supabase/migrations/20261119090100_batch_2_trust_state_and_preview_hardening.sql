-- Batch 2: protect player trust states, correct event-scoped trust joins, and expose the staff permission catalogue.
CREATE OR REPLACE FUNCTION app_private.guard_game_account_trust_state_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL THEN
    NEW.ownership_status := 'linked_unverified';
    NEW.verification_attempts := 0;
    NEW.verification_locked_at := NULL;
    NEW.verification_last_attempt_at := NULL;
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION app_private.guard_game_account_trust_state_insert() FROM public,anon,authenticated;
DROP TRIGGER IF EXISTS game_accounts_trust_state_insert_guard ON public.game_accounts;
CREATE TRIGGER game_accounts_trust_state_insert_guard BEFORE INSERT ON public.game_accounts
FOR EACH ROW EXECUTE FUNCTION app_private.guard_game_account_trust_state_insert();

CREATE OR REPLACE VIEW public.my_competition_trust_states
WITH (security_invoker = true)
AS
SELECT ga.user_id,ga.game_id,ga.id AS game_account_id,ga.ownership_status,
  ga.ownership_status='verified' AS is_verified_player,
  er.event_id,er.id AS registration_id,
  er.status IN ('approved','checked_in') AS is_registered_player,
  m.id AS match_id,mc.status AS match_checkin_status,
  mc.status='ready' AS is_checked_in_player
FROM public.game_accounts ga
LEFT JOIN public.registration_players rp
  ON rp.game_account_id=ga.id AND rp.user_id=ga.user_id
LEFT JOIN public.event_registrations er ON er.id=rp.registration_id
LEFT JOIN public.match_checkins mc ON mc.user_id=ga.user_id
LEFT JOIN public.matches m ON m.id=mc.match_id AND m.event_id=er.event_id;
ALTER VIEW public.my_competition_trust_states SET (security_invoker=true);
GRANT SELECT ON public.my_competition_trust_states TO authenticated;

ALTER TABLE public.event_staff_role_permissions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS event_staff_role_permissions_read_authenticated ON public.event_staff_role_permissions;
CREATE POLICY event_staff_role_permissions_read_authenticated ON public.event_staff_role_permissions
FOR SELECT TO authenticated USING ((SELECT auth.uid()) IS NOT NULL);
GRANT SELECT ON public.event_staff_role_permissions TO authenticated;
REVOKE INSERT,UPDATE,DELETE ON public.event_staff_role_permissions FROM anon,authenticated;

CREATE OR REPLACE FUNCTION public.preview_community_role_permissions(
  p_community_id uuid,p_role_id uuid DEFAULT NULL,p_user_id uuid DEFAULT NULL,p_channel_id uuid DEFAULT NULL
) RETURNS TABLE(permission_key text,allowed boolean,source text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_subject uuid:=COALESCE(p_user_id,auth.uid());
  v_category uuid; v_channel_private boolean:=false; v_has_channel_override boolean:=false;
  v_member_role text; v_is_owner boolean:=false; v_channel_member boolean:=false; v_muted boolean:=false;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF v_subject IS DISTINCT FROM auth.uid() AND NOT app_private.resolve_permission('community.manage_permissions','community',p_community_id,NULL,NULL) THEN
    RAISE EXCEPTION 'Cannot preview another member';
  END IF;
  IF p_role_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.community_roles cr WHERE cr.id=p_role_id AND cr.community_id=p_community_id AND cr.archived_at IS NULL) THEN
    RAISE EXCEPTION 'Role not in community or archived';
  END IF;
  IF p_role_id IS NULL AND NOT EXISTS(SELECT 1 FROM public.community_members cm WHERE cm.community_id=p_community_id AND cm.user_id=v_subject)
     AND NOT EXISTS(SELECT 1 FROM public.communities c WHERE c.id=p_community_id AND c.owner_user_id=v_subject) THEN
    RAISE EXCEPTION 'Preview subject is not a community member';
  END IF;
  IF p_role_id IS NULL THEN
    SELECT c.owner_user_id=v_subject INTO v_is_owner FROM public.communities c WHERE c.id=p_community_id;
    SELECT cm.role INTO v_member_role FROM public.community_members cm WHERE cm.community_id=p_community_id AND cm.user_id=v_subject;
    SELECT EXISTS(SELECT 1 FROM public.community_members cm WHERE cm.community_id=p_community_id AND cm.user_id=v_subject AND cm.muted_until IS NOT NULL AND cm.muted_until>now()) INTO v_muted;
  END IF;
  IF p_channel_id IS NOT NULL THEN
    SELECT c.category_id,c.is_private INTO v_category,v_channel_private FROM public.channels c
    WHERE c.id=p_channel_id AND c.community_id=p_community_id AND c.event_id IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'Channel not in community'; END IF;
    IF p_role_id IS NULL THEN
      SELECT EXISTS(SELECT 1 FROM public.channel_members cm WHERE cm.channel_id=p_channel_id AND cm.user_id=v_subject) INTO v_channel_member;
    END IF;
    SELECT EXISTS(SELECT 1 FROM public.channel_permission_overrides o
      WHERE o.community_id=p_community_id AND o.channel_id=p_channel_id
      AND ((p_role_id IS NOT NULL AND o.role_id=p_role_id) OR (p_role_id IS NULL AND EXISTS(
        SELECT 1 FROM public.community_member_roles cmr WHERE cmr.community_id=p_community_id AND cmr.user_id=v_subject AND cmr.role_id=o.role_id))))
    INTO v_has_channel_override;
  END IF;
  RETURN QUERY
  WITH keys AS(SELECT d.permission_key,d.owner_override FROM app_private.permission_definitions d WHERE d.scope_type='community'),
  grants AS(
    SELECT rp.permission_key,bool_or(rp.allowed) allow_grant,bool_or(NOT rp.allowed) deny_grant
    FROM public.role_permissions rp
    WHERE (p_role_id IS NOT NULL AND rp.role_id=p_role_id) OR (p_role_id IS NULL AND EXISTS(
      SELECT 1 FROM public.community_member_roles cmr WHERE cmr.role_id=rp.role_id AND cmr.community_id=p_community_id AND cmr.user_id=v_subject))
    GROUP BY rp.permission_key),
  overrides AS(
    SELECT o.permission_key,bool_or(o.effect='allow') allow_override,bool_or(o.effect='deny') deny_override FROM(
      SELECT cpo.permission_key,cpo.effect FROM public.channel_permission_overrides cpo
      WHERE p_channel_id IS NOT NULL AND v_has_channel_override AND cpo.community_id=p_community_id AND cpo.channel_id=p_channel_id
      AND ((p_role_id IS NOT NULL AND cpo.role_id=p_role_id) OR (p_role_id IS NULL AND EXISTS(
        SELECT 1 FROM public.community_member_roles cmr WHERE cmr.community_id=p_community_id AND cmr.user_id=v_subject AND cmr.role_id=cpo.role_id)))
      UNION ALL
      SELECT cpo.permission_key,cpo.effect FROM public.category_permission_overrides cpo
      WHERE p_channel_id IS NOT NULL AND NOT v_has_channel_override AND v_category IS NOT NULL AND cpo.community_id=p_community_id AND cpo.category_id=v_category
      AND ((p_role_id IS NOT NULL AND cpo.role_id=p_role_id) OR (p_role_id IS NULL AND EXISTS(
        SELECT 1 FROM public.community_member_roles cmr WHERE cmr.community_id=p_community_id AND cmr.user_id=v_subject AND cmr.role_id=cpo.role_id)))
    ) o GROUP BY o.permission_key),
  baseline AS(
    SELECT k.permission_key,
      CASE WHEN p_channel_id IS NULL THEN CASE k.permission_key
        WHEN 'community.view' THEN true WHEN 'community.manage_settings' THEN v_is_owner
        WHEN 'community.manage_structure' THEN v_is_owner OR v_member_role IN ('admin','moderator','organiser')
        WHEN 'community.manage_members' THEN v_is_owner OR v_member_role IN ('admin','moderator')
        WHEN 'community.manage_invites' THEN v_is_owner OR v_member_role IN ('admin','organiser')
        WHEN 'community.manage_roles' THEN v_is_owner OR v_member_role='admin'
        WHEN 'community.manage_permissions' THEN v_is_owner WHEN 'community.audit.read' THEN v_is_owner ELSE false END
      ELSE CASE k.permission_key
        WHEN 'channel.view' THEN (NOT v_channel_private) OR (p_role_id IS NULL AND v_member_role IN ('owner','admin','moderator','organiser')) OR v_channel_member
        WHEN 'channel.read_history' THEN (NOT v_channel_private) OR (p_role_id IS NULL AND v_member_role IN ('owner','admin','moderator','organiser')) OR v_channel_member
        WHEN 'channel.send_messages' THEN ((NOT v_channel_private) OR (p_role_id IS NULL AND v_member_role IN ('owner','admin','moderator','organiser')) OR v_channel_member) AND NOT v_muted
        WHEN 'channel.react' THEN (NOT v_channel_private) OR (p_role_id IS NULL AND v_member_role IN ('owner','admin','moderator','organiser')) OR v_channel_member
        WHEN 'channel.manage_messages' THEN p_role_id IS NULL AND (v_is_owner OR v_member_role IN ('admin','moderator')) ELSE false END
      END AS base_allowed FROM keys k),
  final AS(
    SELECT k.permission_key,
      CASE WHEN p_role_id IS NULL AND v_is_owner AND k.owner_override THEN true
           WHEN o.deny_override THEN false WHEN o.allow_override THEN true WHEN g.deny_grant THEN false
           WHEN g.allow_grant THEN true ELSE COALESCE(b.base_allowed,false) END allowed,
      CASE WHEN p_role_id IS NULL AND v_is_owner AND k.owner_override THEN 'owner_override'
           WHEN o.deny_override THEN 'channel_or_category_deny' WHEN o.allow_override THEN 'channel_or_category_allow'
           WHEN g.deny_grant THEN 'explicit_deny' WHEN g.allow_grant THEN 'role_grant'
           WHEN b.base_allowed THEN 'built_in_default' ELSE 'not_granted' END source
    FROM keys k LEFT JOIN grants g ON g.permission_key=k.permission_key
    LEFT JOIN overrides o ON o.permission_key=k.permission_key
    LEFT JOIN baseline b ON b.permission_key=k.permission_key)
  SELECT final.permission_key,final.allowed,final.source FROM final ORDER BY final.permission_key;
END;
$function$;
REVOKE ALL ON FUNCTION public.preview_community_role_permissions(uuid,uuid,uuid,uuid) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.preview_community_role_permissions(uuid,uuid,uuid,uuid) TO authenticated;
