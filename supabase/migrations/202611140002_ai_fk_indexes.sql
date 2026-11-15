-- Add indexes for foreign keys introduced by the AI foundation.
create index if not exists ai_actions_run_id_idx on public.ai_actions(run_id);
create index if not exists ai_actions_owner_user_id_idx on public.ai_actions(owner_user_id);
create index if not exists ai_documents_owner_user_id_idx on public.ai_documents(owner_user_id);
create index if not exists ai_policy_updated_by_idx on public.ai_policy(updated_by) where updated_by is not null;
create index if not exists ai_proposals_approved_by_idx on public.ai_proposals(approved_by) where approved_by is not null;
create index if not exists ai_proposals_owner_user_id_idx on public.ai_proposals(owner_user_id);
create index if not exists ai_usage_conversation_id_idx on public.ai_usage_ledger(conversation_id) where conversation_id is not null;
create index if not exists ai_usage_run_id_idx on public.ai_usage_ledger(run_id) where run_id is not null;
create index if not exists ai_usage_event_id_idx on public.ai_usage_ledger(event_id) where event_id is not null;
