-- Cover the remaining LiveOps session foreign keys.
CREATE INDEX IF NOT EXISTS liveops_sessions_event_id_idx
  ON public.liveops_sessions(event_id);
CREATE INDEX IF NOT EXISTS liveops_sessions_match_id_idx
  ON public.liveops_sessions(match_id);
CREATE INDEX IF NOT EXISTS liveops_sessions_operator_id_idx
  ON public.liveops_sessions(operator_id);
