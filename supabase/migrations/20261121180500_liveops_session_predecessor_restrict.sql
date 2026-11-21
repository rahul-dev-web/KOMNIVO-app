ALTER TABLE public.liveops_sessions
  DROP CONSTRAINT IF EXISTS liveops_sessions_previous_session_id_fkey;

ALTER TABLE public.liveops_sessions
  ADD CONSTRAINT liveops_sessions_previous_session_id_fkey
  FOREIGN KEY (previous_session_id)
  REFERENCES public.liveops_sessions(id)
  ON DELETE RESTRICT;
