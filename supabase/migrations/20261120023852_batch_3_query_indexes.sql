-- Batch 3 query and foreign-key indexes.
-- These cover the new channel/forum/poll/scheduling tables and the existing
-- message surfaces now used more heavily by Batch 3.
create index if not exists channel_category_preferences_user_collapsed_idx
  on public.channel_category_preferences(user_id,is_collapsed,category_id);

create index if not exists forum_posts_channel_community_idx
  on public.forum_posts(channel_id,community_id);
create index if not exists forum_posts_community_idx
  on public.forum_posts(community_id);
create index if not exists forum_posts_author_idx
  on public.forum_posts(author_id);
create index if not exists forum_post_replies_author_idx
  on public.forum_post_replies(author_id);

create index if not exists channel_polls_channel_community_idx
  on public.channel_polls(channel_id,community_id);
create index if not exists channel_polls_community_idx
  on public.channel_polls(community_id);
create index if not exists channel_polls_created_by_idx
  on public.channel_polls(created_by);
create index if not exists channel_poll_votes_option_poll_idx
  on public.channel_poll_votes(option_id,poll_id);

create index if not exists channel_settings_channel_community_idx
  on public.channel_settings(channel_id,community_id);
create index if not exists channel_settings_updated_by_idx
  on public.channel_settings(updated_by)
  where updated_by is not null;

create index if not exists scheduled_announcements_channel_community_idx
  on public.scheduled_channel_announcements(channel_id,community_id);
create index if not exists scheduled_announcements_community_idx
  on public.scheduled_channel_announcements(community_id);
create index if not exists scheduled_announcements_created_by_idx
  on public.scheduled_channel_announcements(created_by);

create index if not exists event_communication_instances_community_idx
  on public.event_communication_instances(community_id);
create index if not exists event_communication_instances_template_idx
  on public.event_communication_instances(template_key);
create index if not exists event_communication_instances_created_by_idx
  on public.event_communication_instances(created_by);

create index if not exists event_channel_lifecycle_rules_community_idx
  on public.event_channel_lifecycle_rules(community_id);
create index if not exists event_channel_lifecycle_rules_created_by_idx
  on public.event_channel_lifecycle_rules(created_by);

create index if not exists message_attachments_message_id_idx
  on public.message_attachments(message_id);
create index if not exists message_pins_message_id_idx
  on public.message_pins(message_id);
create index if not exists message_pins_pinned_by_idx
  on public.message_pins(pinned_by);
create index if not exists message_reactions_user_id_idx
  on public.message_reactions(user_id);
create index if not exists channel_read_states_user_id_idx
  on public.channel_read_states(user_id);
create index if not exists channel_members_user_id_idx
  on public.channel_members(user_id);
create index if not exists messages_parent_message_id_idx
  on public.messages(parent_message_id)
  where parent_message_id is not null;
