-- Least-privilege Data API grants for KOMNIVO (all application tables are postgres-owned).
revoke all privileges on all tables in schema public from anon, authenticated;
revoke all privileges on all sequences in schema public from anon, authenticated;

grant usage on schema public to anon, authenticated;
grant select on public.games to anon, authenticated;

grant select, insert, update on public.profiles to authenticated;
grant select, insert, update on public.game_accounts to authenticated;
grant select, insert on public.game_profile_snapshots to authenticated;

grant select, insert, update, delete on public.communities to authenticated;
grant select, insert, update, delete on public.community_members to authenticated;
grant select, insert, update, delete on public.community_invites to authenticated;
grant select, insert, update, delete on public.channels to authenticated;
grant select, insert, delete on public.channel_members to authenticated;
grant select, insert, update on public.messages to authenticated;
grant select, insert, delete on public.message_reactions to authenticated;
grant select, insert, update, delete on public.channel_read_states to authenticated;
grant select, insert on public.message_attachments to authenticated;
grant select, insert, delete on public.message_pins to authenticated;
grant select, insert, update, delete on public.user_blocks to authenticated;

grant select, insert, update, delete on public.teams to authenticated;
grant select, insert, update, delete on public.team_members to authenticated;
grant select, insert on public.team_invites to authenticated;
grant update (status) on public.team_invites to authenticated;
grant select, insert, update, delete on public.events to authenticated;
grant select on public.event_registrations to authenticated;
grant update (status, approved_at) on public.event_registrations to authenticated;
grant select, insert, update on public.registration_players to authenticated;
grant select, insert, update, delete on public.event_rounds to authenticated;
grant select, insert, update, delete on public.event_groups to authenticated;
grant select, insert, update, delete on public.event_group_teams to authenticated;
grant select, insert, delete on public.event_follows to authenticated;
grant select, insert, update on public.event_standings to authenticated;

grant select, insert, update on public.matches to authenticated;
grant select, insert, update on public.match_participants to authenticated;
grant select, insert, update on public.match_checkins to authenticated;
grant select, insert on public.room_credentials to authenticated;
grant select, insert on public.match_results to authenticated;
grant select, insert on public.result_evidence to authenticated;
grant select, insert, update on public.result_disputes to authenticated;
grant select, insert on public.opponent_confirmations to authenticated;
grant select, insert on public.audit_logs to authenticated;

grant select, update on public.notifications to authenticated;
grant select, insert, update, delete on public.device_tokens to authenticated;
grant select, insert, update on public.moderation_reports to authenticated;
grant select, insert, update on public.liveops_sessions to authenticated;
grant select, insert on public.screen_observations to authenticated;
grant select, insert on public.lobby_checks to authenticated;
grant select, insert on public.result_candidates to authenticated;
grant select, insert, update on public.notification_preferences to authenticated;

-- Future objects created by the postgres migration owner need explicit grants.
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated;
