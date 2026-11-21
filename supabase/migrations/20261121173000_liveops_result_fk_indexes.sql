-- Cover the result/candidate foreign-key lookups and evaluate auth.uid() once per statement.
CREATE INDEX IF NOT EXISTS match_results_approved_by_idx
  ON public.match_results(approved_by);
CREATE INDEX IF NOT EXISTS match_results_submitted_by_idx
  ON public.match_results(submitted_by);
CREATE INDEX IF NOT EXISTS match_results_team_id_idx
  ON public.match_results(team_id);
CREATE INDEX IF NOT EXISTS result_candidate_evidence_created_by_idx
  ON public.result_candidate_evidence(created_by);
CREATE INDEX IF NOT EXISTS result_candidate_evidence_team_id_idx
  ON public.result_candidate_evidence(team_id);
CREATE INDEX IF NOT EXISTS result_candidates_reviewed_by_idx
  ON public.result_candidates(reviewed_by);
CREATE INDEX IF NOT EXISTS result_candidates_source_observation_id_idx
  ON public.result_candidates(source_observation_id);

DROP POLICY IF EXISTS result_candidates_insert_operator
  ON public.result_candidates;
CREATE POLICY result_candidates_insert_operator
  ON public.result_candidates
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.screen_observations o
      JOIN public.liveops_sessions s ON s.id=o.session_id
      WHERE o.id=result_candidates.source_observation_id
        AND s.operator_id=(SELECT auth.uid())
    )
  );
