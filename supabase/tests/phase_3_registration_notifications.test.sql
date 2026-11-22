-- Phase 3: isolated test registration and targeted tournament notification contracts.
-- Run with: supabase test db
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT extensions.plan(28);

SELECT extensions.has_table('public','event_test_registrations',
  'Test registrations have a dedicated isolated table');
SELECT extensions.has_table('public','event_test_registration_players',
  'Test-registration roster snapshots have a separate table');
SELECT extensions.ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid='public.event_test_registrations'::regclass)
  AND (SELECT relrowsecurity FROM pg_class WHERE oid='public.event_test_registration_players'::regclass),
  'Both test-registration tables have RLS enabled'
);
SELECT extensions.ok(
  has_table_privilege('authenticated','public.event_test_registrations','SELECT')
  AND NOT has_table_privilege('authenticated','public.event_test_registrations','INSERT')
  AND NOT has_table_privilege('authenticated','public.event_test_registrations','UPDATE')
  AND NOT has_table_privilege('authenticated','public.event_test_registration_players','INSERT')
  AND NOT has_table_privilege('authenticated','public.event_test_registration_players','DELETE'),
  'Clients can read scoped test registrations but cannot write the tables directly'
);
SELECT extensions.ok(
  NOT has_table_privilege('anon','public.event_test_registrations','SELECT')
  AND NOT has_table_privilege('anon','public.event_test_registration_players','SELECT'),
  'Anonymous users cannot read isolated test records'
);
SELECT extensions.ok(
  to_regprocedure('public.submit_test_registration(uuid,uuid)') IS NOT NULL
  AND has_function_privilege('authenticated','public.submit_test_registration(uuid,uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.submit_test_registration(uuid,uuid)','EXECUTE'),
  'Only authenticated users can submit a test registration through its RPC'
);
SELECT extensions.ok(
  NOT has_function_privilege('authenticated','app_private.submit_test_registration(uuid,uuid)','EXECUTE'),
  'Internal test-registration implementation is not directly callable by clients'
);
SELECT extensions.ok(
  position('registration_closes_at <= now()' IN pg_get_functiondef('app_private.submit_test_registration(uuid,uuid)'::regprocedure)) > 0
  AND position('published' IN pg_get_functiondef('app_private.submit_test_registration(uuid,uuid)'::regprocedure)) > 0
  AND position('registration_open' IN pg_get_functiondef('app_private.submit_test_registration(uuid,uuid)'::regprocedure)) > 0,
  'Test registration opens on publication and stops at the real registration close time'
);
SELECT extensions.ok(
  position('is_event_registration_eligible_player' IN pg_get_functiondef('app_private.submit_test_registration(uuid,uuid)'::regprocedure)) > 0,
  'Test registrations reuse the same player/team eligibility contract'
);
SELECT extensions.ok(
  position('event_registrations' IN pg_get_functiondef('app_private.submit_test_registration(uuid,uuid)'::regprocedure)) = 0
  AND position('match_participants' IN pg_get_functiondef('app_private.submit_test_registration(uuid,uuid)'::regprocedure)) = 0
  AND position('event_standings' IN pg_get_functiondef('app_private.submit_test_registration(uuid,uuid)'::regprocedure)) = 0,
  'Test registration never writes real registration, match participation or standings records'
);
SELECT extensions.ok(
  NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.event_test_registrations'::regclass AND NOT tgisinternal
  ),
  'Test submissions do not trigger registration notifications or public participant tags'
);
SELECT extensions.ok(
  to_regclass('public.event_notification_dispatches') IS NOT NULL
  AND (SELECT relrowsecurity FROM pg_class WHERE oid='public.event_notification_dispatches'::regclass)
  AND NOT has_table_privilege('authenticated','public.event_notification_dispatches','SELECT')
  AND has_table_privilege('service_role','public.event_notification_dispatches','INSERT'),
  'Notification idempotency is stored in an RLS-protected server-only ledger'
);
SELECT extensions.ok(
  to_regprocedure('app_private.enqueue_event_notification(uuid,uuid,text,text,text)') IS NOT NULL
  AND NOT has_function_privilege('authenticated','app_private.enqueue_event_notification(uuid,uuid,text,text,text)','EXECUTE'),
  'Targeted notification enqueue helper is server-only'
);
SELECT extensions.ok(
  position('event_notification_dispatches' IN pg_get_functiondef('app_private.enqueue_event_notification(uuid,uuid,text,text,text)'::regprocedure)) > 0
  AND position('ON CONFLICT' IN pg_get_functiondef('app_private.enqueue_event_notification(uuid,uuid,text,text,text)'::regprocedure)) > 0,
  'The notification enqueue path is idempotent per event, user and notification key'
);
SELECT extensions.ok(
  position('game_accounts' IN pg_get_functiondef('app_private.notify_event_published()'::regprocedure)) > 0
  AND position('event_follows' IN pg_get_functiondef('app_private.notify_event_published()'::regprocedure)) > 0,
  'Publication notifications target game-linked community members and event followers'
);
SELECT extensions.ok(
  position('ownership_status <> ''rejected''' IN pg_get_functiondef('app_private.notify_event_published()'::regprocedure)) > 0,
  'Publication audience excludes rejected game-account links'
);
SELECT extensions.ok(
  position('can_receive_event_notification' IN pg_get_functiondef('app_private.enqueue_event_notification(uuid,uuid,text,text,text)'::regprocedure)) > 0,
  'Every tournament notification checks public/private community visibility before enqueue'
);
SELECT extensions.ok(
  EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.events'::regclass
    AND tgname='events_notify_game_audience_after_publish' AND NOT tgisinternal),
  'Publishing a tournament triggers the game-based audience notification'
);
SELECT extensions.ok(
  position('captain_user_id' IN pg_get_functiondef('app_private.notify_event_registration_change()'::regprocedure)) > 0
  AND position('role = ''captain''' IN pg_get_functiondef('app_private.notify_event_registration_change()'::regprocedure)) > 0
  AND position('owner_user_id' IN pg_get_functiondef('app_private.notify_event_registration_change()'::regprocedure)) > 0,
  'Registration notifications target the submitting player and current IGL/owner fallback'
);
SELECT extensions.ok(
  EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.event_registrations'::regclass
    AND tgname='event_registrations_notify_recipients' AND NOT tgisinternal),
  'Registration creation and status changes trigger targeted notices'
);
SELECT extensions.ok(
  position('team_members' IN pg_get_functiondef('app_private.notify_group_team_assignment()'::regprocedure)) > 0
  AND position('event_groups' IN pg_get_functiondef('app_private.notify_group_team_assignment()'::regprocedure)) > 0,
  'Group assignment notifications resolve the assigned team roster and event scope'
);
SELECT extensions.ok(
  EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.event_group_teams'::regclass
    AND tgname='event_group_teams_notify_assignment' AND NOT tgisinternal),
  'A team entering a group emits its group assignment notification'
);
SELECT extensions.ok(
  position('match_participants' IN pg_get_functiondef('app_private.notify_match_schedule_from_match()'::regprocedure)) > 0
  AND position('event_group_teams' IN pg_get_functiondef('app_private.notify_match_schedule_from_match()'::regprocedure)) > 0,
  'Match schedule notifications resolve both direct match participants and group teams'
);
SELECT extensions.ok(
  EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.matches'::regclass
    AND tgname='matches_notify_schedule_recipients' AND NOT tgisinternal)
  AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='public.match_participants'::regclass
    AND tgname='match_participants_notify_schedule_recipients' AND NOT tgisinternal),
  'Match creation/rescheduling and participant assignment deliver schedule notices'
);
SELECT extensions.ok(
  position('''tournament''' IN pg_get_functiondef('app_private.enqueue_event_notification(uuid,uuid,text,text,text)'::regprocedure)) > 0,
  'Tournament notices use the existing tournament_push notification preference category'
);
SELECT extensions.ok(
  position('can_receive_event_notification' IN pg_get_functiondef('app_private.can_receive_event_notification(uuid,uuid)'::regprocedure)) > 0
  OR to_regprocedure('app_private.can_receive_event_notification(uuid,uuid)') IS NOT NULL,
  'Scoped event audience validation helper is installed'
);
SELECT extensions.ok(
  EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
    AND tablename='event_test_registrations' AND policyname='event_test_registrations_read_scoped')
  AND EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
    AND tablename='event_test_registration_players' AND policyname='event_test_registration_players_read_scoped'),
  'Test records are readable only by their submitter or authorised event staff'
);
SELECT * FROM extensions.finish();
ROLLBACK;
