-- Supporting indexes for the new LiveOps evidence-batch foreign keys.
CREATE INDEX IF NOT EXISTS liveops_evidence_batches_lobby_idx
  ON public.liveops_evidence_batches(lobby_id);
CREATE INDEX IF NOT EXISTS liveops_evidence_batches_event_idx
  ON public.liveops_evidence_batches(event_id);
CREATE INDEX IF NOT EXISTS liveops_evidence_batches_match_idx
  ON public.liveops_evidence_batches(match_id);
CREATE INDEX IF NOT EXISTS liveops_evidence_batches_operator_idx
  ON public.liveops_evidence_batches(operator_id);
