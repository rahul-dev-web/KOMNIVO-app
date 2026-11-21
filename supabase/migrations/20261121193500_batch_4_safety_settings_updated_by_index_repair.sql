-- Repair the missing Batch 4 safety-settings FK index in environments
-- where the original migration was recorded but the index was not materialized.
create index if not exists community_safety_settings_updated_by_idx
  on public.community_safety_settings(updated_by);
