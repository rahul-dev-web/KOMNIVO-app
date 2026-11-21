-- Allow an authorised result reviewer at the exact Match scope to preview
-- private LiveOps evidence, including match-scoped referees/result reviewers.
DROP POLICY IF EXISTS match_evidence_read_liveops ON storage.objects;
CREATE POLICY match_evidence_read_liveops
  ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id='match-evidence'
    AND EXISTS (
      SELECT 1
      FROM public.liveops_captures lc
      WHERE lc.evidence_path=objects.name
        AND (
          lc.operator_id=(SELECT auth.uid())
          OR app_private.resolve_permission(
            'match.results.review','match',lc.match_id,NULL,NULL
          )
        )
    )
  );
