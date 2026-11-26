-- The temporary ownership bypass applies only to isolated test registrations.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT extensions.plan(10);

SELECT extensions.ok(
  to_regclass('app_private.registration_test_settings') IS NOT NULL,
  'The private test-registration settings table exists'
);

SELECT extensions.ok(
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='app_private'
      AND table_name='registration_test_settings'
      AND column_name='allow_unverified_uid_for_test_registration'
      AND column_default='false'
  ),
  'The unverified UID test mode defaults to disabled'
);

SELECT extensions.ok(
  position('ALLOW_UNVERIFIED_UID_FOR_TEST_REGISTRATION' IN
    upper(pg_get_functiondef('app_private.submit_test_registration(uuid,uuid)'::regprocedure))) > 0,
  'Test registration reads the runtime bypass switch'
);

SELECT extensions.ok(
  position('IS_EVENT_TEST_REGISTRATION_ELIGIBLE_PLAYER' IN
    upper(pg_get_functiondef('app_private.submit_test_registration(uuid,uuid)'::regprocedure))) > 0,
  'Test registration uses its dedicated unverified-UID eligibility path'
);

SELECT extensions.ok(
  position('IS_EVENT_REGISTRATION_ELIGIBLE_PLAYER' IN
    upper(pg_get_functiondef('app_private.submit_test_registration(uuid,uuid)'::regprocedure))) > 0,
  'Turning the switch off restores the verified-eligibility path'
);

SELECT extensions.ok(
  position('OWNERSHIP_STATUS = ''VERIFIED''' IN
    upper(pg_get_functiondef('app_private.is_event_test_registration_eligible_player(uuid,uuid,uuid)'::regprocedure))) = 0,
  'Test eligibility does not require ownership_status verified'
);

SELECT extensions.ok(
  position('OWNERSHIP_STATUS <> ''REJECTED''' IN
    upper(pg_get_functiondef('app_private.is_event_test_registration_eligible_player(uuid,uuid,uuid)'::regprocedure))) > 0,
  'Test eligibility still requires linked non-rejected UIDs where required'
);

SELECT extensions.ok(
  position('INSERT INTO PUBLIC.EVENT_TEST_REGISTRATIONS' IN
    upper(pg_get_functiondef('app_private.submit_test_registration(uuid,uuid)'::regprocedure))) > 0,
  'Test submissions write to the isolated test-registration table'
);

SELECT extensions.ok(
  position('INSERT INTO PUBLIC.EVENT_REGISTRATIONS' IN
    upper(pg_get_functiondef('app_private.submit_test_registration(uuid,uuid)'::regprocedure))) = 0,
  'Test submissions never create real event registrations'
);

SELECT extensions.ok(
  position('CONSUMES_REAL_SLOT' IN
    upper(pg_get_functiondef('app_private.submit_test_registration(uuid,uuid)'::regprocedure))) > 0
  AND position('AFFECTS_STANDINGS' IN
    upper(pg_get_functiondef('app_private.submit_test_registration(uuid,uuid)'::regprocedure))) > 0,
  'The test response marks slot and standings isolation'
);

SELECT * FROM extensions.finish();
ROLLBACK;
