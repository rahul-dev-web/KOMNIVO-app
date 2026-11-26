-- Tournament Info and Updates channel routing, scoped mentions and retry safety.
-- Run with: supabase test db
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT extensions.plan(16);

SELECT extensions.has_table(
  'public','event_channel_announcement_dispatches',
  'Tournament channel announcements have a dedicated idempotency ledger'
);

SELECT extensions.ok(
  (SELECT relrowsecurity FROM pg_class
   WHERE oid='public.event_channel_announcement_dispatches'::regclass),
  'Announcement dispatch ledger has RLS enabled'
);

SELECT extensions.ok(
  NOT has_table_privilege('authenticated','public.event_channel_announcement_dispatches','SELECT')
  AND NOT has_table_privilege('authenticated','public.event_channel_announcement_dispatches','INSERT')
  AND NOT has_table_privilege('anon','public.event_channel_announcement_dispatches','SELECT'),
  'Client roles cannot read or mutate internal announcement dispatch records'
);

SELECT extensions.ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.event_channel_announcement_dispatches'::regclass
      AND contype='u'
      AND pg_get_constraintdef(oid) ILIKE '%event_id, dispatch_key%'
  ),
  'The event and dispatch key enforce idempotent announcement creation'
);

SELECT extensions.ok(
  to_regprocedure('app_private.enqueue_event_channel_announcement(uuid,text,text,text,uuid[])') IS NOT NULL,
  'The server-only channel announcement enqueue helper exists'
);

SELECT extensions.ok(
  NOT has_function_privilege(
    'authenticated',
    'app_private.enqueue_event_channel_announcement(uuid,text,text,text,uuid[])',
    'EXECUTE'
  )
  AND NOT has_function_privilege(
    'anon',
    'app_private.enqueue_event_channel_announcement(uuid,text,text,text,uuid[])',
    'EXECUTE'
  ),
  'Untrusted client roles cannot enqueue privileged channel announcements'
);

SELECT extensions.ok(
  position('can_user_receive_channel_mention' IN
    pg_get_functiondef('app_private.enqueue_event_channel_announcement(uuid,text,text,text,uuid[])'::regprocedure)) > 0
  AND position('scheduled_channel_announcements' IN
    pg_get_functiondef('app_private.enqueue_event_channel_announcement(uuid,text,text,text,uuid[])'::regprocedure)) > 0,
  'Announcements are queued for the service publisher and mentions are filtered by exact channel access'
);

SELECT extensions.ok(
  position('info:' IN
    pg_get_functiondef('app_private.tournament_event_channel_info()'::regprocedure)) > 0
  AND position('prize_pool_amount' IN
    pg_get_functiondef('app_private.tournament_event_channel_info()'::regprocedure)) > 0
  AND position('prize_distribution' IN
    pg_get_functiondef('app_private.tournament_event_channel_info()'::regprocedure)) > 0
  AND position('scoring_config' IN
    pg_get_functiondef('app_private.tournament_event_channel_info()'::regprocedure)) > 0,
  'Info posts carry tournament metadata and are deduplicated by the rendered information body'
);

SELECT extensions.ok(
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.events'::regclass
      AND tgname='events_tournament_info_channel'
      AND NOT tgisinternal
  ),
  'Published tournament information changes are routed to the Info channel'
);

SELECT extensions.ok(
  position('event_status:' IN
    pg_get_functiondef('app_private.tournament_event_channel_lifecycle_update()'::regprocedure)) > 0
  AND position('registration_open' IN
    pg_get_functiondef('app_private.tournament_event_channel_lifecycle_update()'::regprocedure)) > 0
  AND position('registration_closed' IN
    pg_get_functiondef('app_private.tournament_event_channel_lifecycle_update()'::regprocedure)) > 0,
  'Publish, registration-open and registration-closed transitions are routed to Updates with stable dedupe keys'
);

SELECT extensions.ok(
  position('event_staff_assignments' IN
    pg_get_functiondef('app_private.tournament_event_channel_lifecycle_update()'::regprocedure)) > 0
  AND position('registration_closed' IN
    pg_get_functiondef('app_private.tournament_event_channel_lifecycle_update()'::regprocedure)) > 0,
  'Lifecycle Updates target assigned event staff and registration-close also creates targeted in-app notices'
);

SELECT extensions.ok(
  position('group_assignment:' IN
    pg_get_functiondef('app_private.tournament_group_assignment_channel_update()'::regprocedure)) > 0
  AND position('team_members' IN
    pg_get_functiondef('app_private.tournament_group_assignment_channel_update()'::regprocedure)) > 0
  AND position('owner_user_id' IN
    pg_get_functiondef('app_private.tournament_group_assignment_channel_update()'::regprocedure)) > 0,
  'Group assignment Updates target the assigned team roster and owner idempotently'
);

SELECT extensions.ok(
  position('%-idp' IN
    pg_get_functiondef('app_private.tournament_group_assignment_channel_update()'::regprocedure)) > 0
  AND position('#schedule' IN
    pg_get_functiondef('app_private.tournament_group_assignment_channel_update()'::regprocedure)) > 0,
  'Group assignment notices point users to their private IDP channel and the Schedule channel'
);

SELECT extensions.ok(
  position('stage_schedule:' IN
    pg_get_functiondef('app_private.tournament_stage_schedule_channel_update()'::regprocedure)) > 0
  AND position('event_group_teams' IN
    pg_get_functiondef('app_private.tournament_stage_schedule_channel_update()'::regprocedure)) > 0,
  'Published stage schedules create deduplicated per-group Updates for affected participants'
);

SELECT extensions.ok(
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.event_group_teams'::regclass
      AND tgname='event_group_teams_tournament_channel_update'
      AND NOT tgisinternal
  )
  AND EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.event_rounds'::regclass
      AND tgname='event_rounds_tournament_schedule_channel_update'
      AND NOT tgisinternal
  ),
  'Group assignment and published schedule triggers are installed'
);

SELECT extensions.ok(
  position('p_channel_name NOT IN' IN
    pg_get_functiondef('app_private.enqueue_event_channel_announcement(uuid,text,text,text,uuid[])'::regprocedure)) > 0
  AND position('@everyone' IN
    pg_get_functiondef('app_private.enqueue_event_channel_announcement(uuid,text,text,text,uuid[])'::regprocedure)) = 0
  AND position('@here' IN
    pg_get_functiondef('app_private.enqueue_event_channel_announcement(uuid,text,text,text,uuid[])'::regprocedure)) = 0,
  'The enqueue helper does not add broad channel-wide mentions'
);

SELECT * FROM extensions.finish();
ROLLBACK;
