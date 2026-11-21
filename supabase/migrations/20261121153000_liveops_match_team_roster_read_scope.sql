-- Let a LiveOps operator view only the teams and participant slots in the
-- exact Match they are authorised to capture and transcribe.
DROP POLICY IF EXISTS participants_read_team_or_staff
  ON public.match_participants;
CREATE POLICY participants_read_team_or_staff
  ON public.match_participants
  FOR SELECT TO authenticated
  USING (
    app_private.resolve_permission('participant.view','participant',match_id,team_id,NULL)
    OR app_private.resolve_permission('liveops.capture.submit','match',match_id,NULL,NULL)
  );

DROP POLICY IF EXISTS teams_read_visible ON public.teams;
CREATE POLICY teams_read_visible
  ON public.teams
  FOR SELECT TO authenticated
  USING (
    app_private.resolve_permission('team.view','team',id,NULL,NULL)
    OR EXISTS (
      SELECT 1 FROM public.match_participants mp
      WHERE mp.team_id=teams.id
        AND app_private.resolve_permission('liveops.capture.submit','match',mp.match_id,NULL,NULL)
    )
  );
