CREATE OR REPLACE FUNCTION app_private.can_user_receive_channel_mention(
  p_user_id uuid,
  p_channel_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_channel public.channels%ROWTYPE;
  v_owner_id uuid;
  v_member_role text;
  v_is_owner boolean := false;
  v_custom_allowed boolean := false;
  v_custom_denied boolean := false;
  v_override_allowed boolean := false;
  v_override_denied boolean := false;
  v_direct_override_found boolean := false;
  v_event_organizer uuid;
  v_event_status text;
  v_match_stage uuid;
  v_match_group uuid;
  v_group_stage uuid;
BEGIN
  IF p_user_id IS NULL OR p_channel_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT * INTO v_channel
  FROM public.channels c
  WHERE c.id=p_channel_id AND c.archived_at IS NULL;
  IF NOT FOUND THEN RETURN false; END IF;

  IF v_channel.event_id IS NULL THEN
    IF v_channel.community_id IS NULL THEN
      RETURN EXISTS (
        SELECT 1 FROM public.channel_members cm
        WHERE cm.channel_id=p_channel_id AND cm.user_id=p_user_id
      );
    END IF;

    SELECT c.owner_user_id INTO v_owner_id
    FROM public.communities c WHERE c.id=v_channel.community_id;
    IF NOT FOUND THEN RETURN false; END IF;

    v_is_owner := v_owner_id=p_user_id;
    SELECT cm.role INTO v_member_role
    FROM public.community_members cm
    WHERE cm.community_id=v_channel.community_id AND cm.user_id=p_user_id;

    IF NOT FOUND AND NOT v_is_owner THEN RETURN false; END IF;

    IF NOT v_is_owner AND EXISTS (
      SELECT 1 FROM public.community_member_restrictions r
      WHERE r.community_id=v_channel.community_id
        AND r.target_user_id=p_user_id
        AND r.restriction_type='ban'
        AND r.revoked_at IS NULL
        AND (r.expires_at IS NULL OR r.expires_at>now())
    ) THEN
      RETURN false;
    END IF;

    SELECT
      coalesce(bool_or(rp.allowed),false),
      coalesce(bool_or(NOT rp.allowed),false)
    INTO v_custom_allowed,v_custom_denied
    FROM public.community_member_roles cmr
    JOIN public.role_permissions rp ON rp.role_id=cmr.role_id
    WHERE cmr.community_id=v_channel.community_id
      AND cmr.user_id=p_user_id
      AND rp.permission_key='channel.view';

    SELECT EXISTS (
      SELECT 1
      FROM public.channel_permission_overrides cpo
      JOIN public.community_member_roles cmr
        ON cmr.role_id=cpo.role_id
       AND cmr.community_id=cpo.community_id
       AND cmr.user_id=p_user_id
      WHERE cpo.community_id=v_channel.community_id
        AND cpo.channel_id=p_channel_id
        AND cpo.permission_key='channel.view'
    ) INTO v_direct_override_found;

    IF v_direct_override_found THEN
      SELECT
        coalesce(bool_or(cpo.effect='allow'),false),
        coalesce(bool_or(cpo.effect='deny'),false)
      INTO v_override_allowed,v_override_denied
      FROM public.channel_permission_overrides cpo
      JOIN public.community_member_roles cmr
        ON cmr.role_id=cpo.role_id
       AND cmr.community_id=cpo.community_id
       AND cmr.user_id=p_user_id
      WHERE cpo.community_id=v_channel.community_id
        AND cpo.channel_id=p_channel_id
        AND cpo.permission_key='channel.view';
    ELSIF v_channel.category_id IS NOT NULL THEN
      SELECT
        coalesce(bool_or(cpo.effect='allow'),false),
        coalesce(bool_or(cpo.effect='deny'),false)
      INTO v_override_allowed,v_override_denied
      FROM public.category_permission_overrides cpo
      JOIN public.community_member_roles cmr
        ON cmr.role_id=cpo.role_id
       AND cmr.community_id=cpo.community_id
       AND cmr.user_id=p_user_id
      WHERE cpo.community_id=v_channel.community_id
        AND cpo.category_id=v_channel.category_id
        AND cpo.permission_key='channel.view';
    END IF;

    IF (v_custom_denied OR v_override_denied) AND NOT v_is_owner THEN
      RETURN false;
    END IF;
    IF v_is_owner THEN RETURN true; END IF;

    RETURN (NOT v_channel.is_private)
      OR v_member_role IN ('owner','admin','moderator','organiser')
      OR EXISTS (
        SELECT 1 FROM public.channel_members cm
        WHERE cm.channel_id=p_channel_id AND cm.user_id=p_user_id
      )
      OR v_custom_allowed
      OR v_override_allowed;
  END IF;

  SELECT e.organizer_id,e.status
  INTO v_event_organizer,v_event_status
  FROM public.events e
  WHERE e.id=v_channel.event_id;
  IF NOT FOUND THEN RETURN false; END IF;

  IF v_channel.match_id IS NOT NULL THEN
    SELECT m.stage_id,m.group_id
    INTO v_match_stage,v_match_group
    FROM public.matches m
    WHERE m.id=v_channel.match_id AND m.event_id=v_channel.event_id;

    IF NOT FOUND
       OR (v_channel.stage_id IS NOT NULL AND v_channel.stage_id IS DISTINCT FROM v_match_stage)
       OR (v_channel.group_id IS NOT NULL AND v_channel.group_id IS DISTINCT FROM v_match_group) THEN
      RETURN false;
    END IF;

    RETURN p_user_id=v_event_organizer
      OR EXISTS (
        SELECT 1 FROM public.matches m
        WHERE m.id=v_channel.match_id AND m.host_user_id=p_user_id
      )
      OR EXISTS (
        SELECT 1
        FROM public.match_participants mp
        JOIN public.team_members tm ON tm.team_id=mp.team_id
        WHERE mp.match_id=v_channel.match_id AND tm.user_id=p_user_id
      )
      OR EXISTS (
        SELECT 1 FROM public.event_staff_assignments a
        WHERE a.event_id=v_channel.event_id
          AND a.user_id=p_user_id
          AND (
            (a.scope_type='event' AND a.role_key=ANY(ARRAY[
              'competition_manager','tournament_director','referee',
              'result_reviewer','dispute_reviewer'
            ]::text[]))
            OR (a.scope_type='stage' AND a.stage_id=v_match_stage
              AND a.role_key=ANY(ARRAY[
                'competition_manager','tournament_director','match_operator',
                'referee','result_reviewer','dispute_reviewer','support_staff'
              ]::text[]))
            OR (a.scope_type='group' AND a.group_id=v_match_group
              AND a.role_key=ANY(ARRAY[
                'match_operator','referee','result_reviewer',
                'dispute_reviewer','support_staff'
              ]::text[]))
            OR (a.scope_type='match' AND a.match_id=v_channel.match_id
              AND a.role_key=ANY(ARRAY[
                'match_operator','referee','result_reviewer','dispute_reviewer',
                'support_staff','caster','streamer'
              ]::text[]))
          )
      );
  END IF;

  IF v_channel.group_id IS NOT NULL THEN
    SELECT r.id INTO v_group_stage
    FROM public.event_groups g
    JOIN public.event_rounds r ON r.id=g.round_id
    WHERE g.id=v_channel.group_id AND r.event_id=v_channel.event_id;

    IF NOT FOUND OR
       (v_channel.stage_id IS NOT NULL AND v_channel.stage_id IS DISTINCT FROM v_group_stage) THEN
      RETURN false;
    END IF;

    IF v_channel.is_private THEN
      RETURN p_user_id=v_event_organizer
        OR EXISTS (
          SELECT 1 FROM public.event_group_teams gt
          JOIN public.team_members tm ON tm.team_id=gt.team_id
          WHERE gt.group_id=v_channel.group_id AND tm.user_id=p_user_id
        )
        OR EXISTS (
          SELECT 1 FROM public.event_staff_assignments a
          WHERE a.event_id=v_channel.event_id AND a.user_id=p_user_id
            AND (
              (a.scope_type='event' AND a.role_key=ANY(ARRAY[
                'competition_manager','tournament_director','referee',
                'result_reviewer','dispute_reviewer'
              ]::text[]))
              OR (a.scope_type='stage' AND a.stage_id=v_group_stage
                AND a.role_key=ANY(ARRAY[
                  'competition_manager','tournament_director','match_operator',
                  'referee','result_reviewer','dispute_reviewer','support_staff'
                ]::text[]))
              OR (a.scope_type='group' AND a.group_id=v_channel.group_id
                AND a.role_key=ANY(ARRAY[
                  'match_operator','referee','result_reviewer',
                  'dispute_reviewer','support_staff'
                ]::text[]))
            )
        );
    END IF;

    RETURN v_event_status IN ('published','registration_open','registration_closed','live','completed')
      OR p_user_id=v_event_organizer
      OR EXISTS (
        SELECT 1 FROM public.event_group_teams gt
        JOIN public.team_members tm ON tm.team_id=gt.team_id
        WHERE gt.group_id=v_channel.group_id AND tm.user_id=p_user_id
      )
      OR EXISTS (
        SELECT 1 FROM public.event_staff_assignments a
        WHERE a.event_id=v_channel.event_id AND a.user_id=p_user_id
          AND (
            (a.scope_type='event' AND a.role_key=ANY(ARRAY[
              'competition_manager','tournament_director','referee',
              'result_reviewer','dispute_reviewer'
            ]::text[]))
            OR (a.scope_type='stage' AND a.stage_id=v_group_stage
              AND a.role_key=ANY(ARRAY[
                'competition_manager','tournament_director','match_operator',
                'referee','result_reviewer','dispute_reviewer','support_staff'
              ]::text[]))
            OR (a.scope_type='group' AND a.group_id=v_channel.group_id
              AND a.role_key=ANY(ARRAY[
                'match_operator','referee','result_reviewer',
                'dispute_reviewer','support_staff'
              ]::text[]))
          )
      );
  END IF;

  IF v_channel.stage_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.event_rounds r
      WHERE r.id=v_channel.stage_id AND r.event_id=v_channel.event_id
    ) THEN
      RETURN false;
    END IF;

    IF v_channel.is_private THEN
      RETURN p_user_id=v_event_organizer
        OR EXISTS (
          SELECT 1 FROM public.event_staff_assignments a
          WHERE a.event_id=v_channel.event_id
            AND a.user_id=p_user_id
            AND (
              (a.scope_type='event' AND a.role_key=ANY(ARRAY[
                'competition_manager','tournament_director'
              ]::text[]))
              OR (a.scope_type='stage' AND a.stage_id=v_channel.stage_id
                AND a.role_key=ANY(ARRAY[
                  'competition_manager','tournament_director','match_operator',
                  'referee','result_reviewer','dispute_reviewer','support_staff'
                ]::text[]))
            )
        );
    END IF;

    RETURN v_event_status IN ('published','registration_open','registration_closed','live','completed')
      OR p_user_id=v_event_organizer
      OR EXISTS (
        SELECT 1 FROM public.event_staff_assignments a
        WHERE a.event_id=v_channel.event_id AND a.user_id=p_user_id
          AND (
            (a.scope_type='event' AND a.role_key=ANY(ARRAY[
              'competition_manager','tournament_director','referee',
              'result_reviewer','dispute_reviewer'
            ]::text[]))
            OR (a.scope_type='stage' AND a.stage_id=v_channel.stage_id
              AND a.role_key=ANY(ARRAY[
                'competition_manager','tournament_director','match_operator',
                'referee','result_reviewer','dispute_reviewer','support_staff',
                'caster','streamer'
              ]::text[]))
          )
      )
      OR EXISTS (
        SELECT 1
        FROM public.event_groups g
        JOIN public.event_group_teams gt ON gt.group_id=g.id
        JOIN public.team_members tm ON tm.team_id=gt.team_id
        WHERE g.round_id=v_channel.stage_id AND tm.user_id=p_user_id
      );
  END IF;

  -- Root event channel. Private channels are limited to the organiser and
  -- event-scoped staff. Public channels follow event.view eligibility.
  IF v_channel.is_private THEN
    RETURN p_user_id=v_event_organizer
      OR EXISTS (
        SELECT 1 FROM public.event_staff_assignments a
        WHERE a.event_id=v_channel.event_id
          AND a.user_id=p_user_id
          AND a.scope_type='event'
      );
  END IF;

  RETURN v_event_status IN ('published','registration_open','registration_closed','live','completed')
    OR p_user_id=v_event_organizer
    OR EXISTS (
      SELECT 1 FROM public.event_staff_assignments a
      WHERE a.event_id=v_channel.event_id AND a.user_id=p_user_id
    )
    OR EXISTS (
      SELECT 1 FROM public.event_registrations er
      WHERE er.event_id=v_channel.event_id
        AND (
          er.captain_user_id=p_user_id
          OR (er.team_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.team_members tm
            WHERE tm.team_id=er.team_id AND tm.user_id=p_user_id
          ))
          OR EXISTS (
            SELECT 1 FROM public.registration_players rp
            WHERE rp.registration_id=er.id AND rp.user_id=p_user_id
          )
        )
    );
END;
$function$;

