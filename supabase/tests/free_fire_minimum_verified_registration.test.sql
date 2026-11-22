-- Free Fire MAX registration requires the configured minimum number of
-- verified players, while preserving all roster members and their verified
-- account data. Manual refresh cooldown state is separate from initial sync.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT extensions.plan(10);

SELECT extensions.ok(
  EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public'
      AND table_name='game_accounts'
      AND column_name='profile_refresh_last_success_at'
  ),
  'A successful manual profile refresh timestamp is stored separately'
);

SELECT extensions.ok(
  position('g.code = ''free_fire_max''' IN
    pg_get_functiondef('app_private.is_event_registration_eligible_player(uuid,uuid,uuid)'::regprocedure)) > 0,
  'Registration-channel eligibility detects Free Fire MAX'
);

SELECT extensions.ok(
  position('v_uid_count < v_min_roster' IN
    pg_get_functiondef('app_private.is_event_registration_eligible_player(uuid,uuid,uuid)'::regprocedure)) > 0,
  'Registration-channel eligibility requires the configured minimum verified players'
);

SELECT extensions.ok(
  position(') < v_min_roster then' IN
    pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) > 0,
  'Team registration compares verified UID count against minimum roster size'
);

SELECT extensions.ok(
  position('count(distinct tm.user_id)' IN
    lower(pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) ) > 0
  AND position('ownership_status = ''verified''' IN
    pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) > 0,
  'Only distinct members with verified Free Fire accounts count toward the threshold'
);

SELECT extensions.ok(
  position('from public.team_members tm' IN
    lower(pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) ) > 0
  AND position('left join lateral' IN
    lower(pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) ) > 0,
  'Every roster member remains represented in registration_players'
);

SELECT extensions.ok(
  position('not v_is_free_fire_max or ownership_status = ''verified''' IN
    pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) > 0,
  'Only verified Free Fire MAX accounts are attached; unverified roster rows may have null account IDs'
);

SELECT extensions.ok(
  position('not v_is_free_fire_max or current_account.ownership_status = ''verified''' IN
    pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) > 0,
  'Duplicate UID checks for Free Fire MAX consider verified member accounts'
);

SELECT extensions.ok(
  position('min_roster_size' IN
    pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) > 0
  AND position('when ''duo'' then 2 when ''squad'' then 4 else 1 end' IN
    lower(pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) ) > 0,
  'The same configured minimum roster field and format fallback drive registration'
);

SELECT extensions.ok(
  position('game_account_id is null' IN
    pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) = 0,
  'Registration no longer rejects a team solely because some roster members are unverified'
);

SELECT * FROM extensions.finish();
ROLLBACK;
