-- Cover the remaining LiveOps evidence foreign keys and cache auth.uid() in RLS policies.
CREATE INDEX IF NOT EXISTS liveops_captures_event_id_idx
  ON public.liveops_captures(event_id);
CREATE INDEX IF NOT EXISTS liveops_captures_operator_id_idx
  ON public.liveops_captures(operator_id);
CREATE INDEX IF NOT EXISTS liveops_captures_reviewed_by_idx
  ON public.liveops_captures(reviewed_by);
CREATE INDEX IF NOT EXISTS screen_observations_session_id_idx
  ON public.screen_observations(session_id);

DROP POLICY IF EXISTS observations_insert_session_owner ON public.screen_observations;
CREATE POLICY observations_insert_session_owner
  ON public.screen_observations FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.liveops_sessions s
      WHERE s.id=screen_observations.session_id
        AND s.operator_id=(SELECT auth.uid())
    )
  );

DROP POLICY IF EXISTS observations_read_session_owner_or_staff ON public.screen_observations;
CREATE POLICY observations_read_session_owner_or_staff
  ON public.screen_observations FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.liveops_sessions s
      WHERE s.id=screen_observations.session_id
        AND (
          s.operator_id=(SELECT auth.uid())
          OR (
            s.match_id IS NOT NULL
            AND EXISTS (
              SELECT 1 FROM public.matches m
              WHERE m.id=s.match_id AND app_private.is_event_staff(m.event_id)
            )
          )
        )
    )
  );
