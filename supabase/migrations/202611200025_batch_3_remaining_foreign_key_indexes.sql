-- Remaining Batch 3/category-permission foreign-key access paths.
create index if not exists channel_categories_created_by_idx
  on public.channel_categories(created_by);
create index if not exists channel_categories_event_id_idx
  on public.channel_categories(event_id)
  where event_id is not null;
create index if not exists channel_categories_stage_id_idx
  on public.channel_categories(stage_id)
  where stage_id is not null;

create index if not exists channel_permission_overrides_channel_community_idx
  on public.channel_permission_overrides(channel_id,community_id);
create index if not exists channel_permission_overrides_community_idx
  on public.channel_permission_overrides(community_id);
create index if not exists channel_permission_overrides_role_community_idx
  on public.channel_permission_overrides(role_id,community_id);
create index if not exists channel_permission_overrides_updated_by_idx
  on public.channel_permission_overrides(updated_by)
  where updated_by is not null;

create index if not exists channel_read_states_last_read_message_id_idx
  on public.channel_read_states(last_read_message_id)
  where last_read_message_id is not null;
create index if not exists event_communication_instances_category_id_idx
  on public.event_communication_instances(category_id)
  where category_id is not null;
create index if not exists message_attachments_uploaded_by_idx
  on public.message_attachments(uploaded_by);
create index if not exists scheduled_announcements_published_message_id_idx
  on public.scheduled_channel_announcements(published_message_id)
  where published_message_id is not null;
