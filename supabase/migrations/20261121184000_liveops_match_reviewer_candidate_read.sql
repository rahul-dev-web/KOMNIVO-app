-- Match-scoped referees/result reviewers must be able to read the exact
-- candidate and team labels shown in their Event Operations review queue.

DROP POLICY IF EXISTS result_candidates_read_team_or_staff
  ON public.result_candidates;
CREATE POLICY result_candidates_read_team_or_staff
  ON public.result_candidates
  FOR SELECT TO authenticated
  USING (
    (team_id IS NOT NULL AND app_private.is_team_member(team_id))
    OR EXISTS (
      SELECT 1 FROM public.matches m
      WHERE m.id=result_candidates.match_id
        AND (
          app_private.is_event_staff(m.event_id)
          OR app_private.resolve_permission('liveops.capture.submit','match',m.id,NULL,NULL)
          OR app_private.resolve_permission('match.results.review','match',m.id,NULL,NULL)
        )
    )
  );

DROP POLICY IF EXISTS teams_read_visible
  ON public.teams;
CREATE POLICY teams_read_visible
  ON public.teams
  FOR SELECT TO authenticated
  USING (
    app_private.resolve_permission('team.view','team',id,NULL,NULL)
    OR EXISTS (
      SELECT 1 FROM public.match_participants mp
      WHERE mp.team_id=teams.id
        AND (
          app_private.resolve_permission('liveops.capture.submit','match',mp.match_id,NULL,NULL)
          OR app_private.resolve_permission('match.results.review','match',mp.match_id,NULL,NULL)
        )
    )
  );
