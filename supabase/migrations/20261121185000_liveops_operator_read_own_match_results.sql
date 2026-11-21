-- A match-scoped LiveOps operator must be able to verify the official
-- submission created by their own session before invoking Next Match.
DROP POLICY IF EXISTS match_results_read_liveops_operator
  ON public.match_results;
CREATE POLICY match_results_read_liveops_operator
  ON public.match_results
  FOR SELECT TO authenticated
  USING (
    app_private.resolve_permission(
      'liveops.capture.submit','match',match_results.match_id,NULL,NULL
    )
  );
