-- Tournament registration eligibility and event-channel policy contracts.
-- Run with: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(16);

select extensions.ok(
  to_regprocedure('app_private.is_event_registration_eligible_player(uuid,uuid,uuid)') is not null,
  'A server-side eligibility check exists for individual team members'
);
select extensions.ok(
  to_regprocedure('app_private.can_write_event_registration_channel(uuid)') is not null,
  'A server-side dynamic writer policy exists for registration channels'
);
select extensions.ok(
  not has_function_privilege(
    'authenticated','app_private.is_event_registration_eligible_player(uuid,uuid,uuid)','EXECUTE'
  ),
  'Raw team-eligibility helper is not directly callable by app clients'
);
select extensions.ok(
  has_function_privilege(
    'authenticated','app_private.can_write_event_registration_channel(uuid)','EXECUTE'
  ),
  'The channel policy helper is callable by authenticated RLS/trigger evaluation'
);

select extensions.ok(
  position('can_write_event_registration_channel(p_channel_id)' in
    pg_get_functiondef('app_private.can_send_channel_message(uuid)'::regprocedure)) > 0
  and position('not coalesce((select cs.read_only' in
    pg_get_functiondef('app_private.can_send_channel_message(uuid)'::regprocedure)) > 0,
  'Read-only channel writes are allowed only through the explicit eligibility helper'
);
select extensions.ok(
  position('v_can_write_event_registration' in
    pg_get_functiondef('app_private.guard_batch3_channel_message()'::regprocedure)) > 0
  and position('Only authorised announcement publishers can post' in
    pg_get_functiondef('app_private.guard_batch3_channel_message()'::regprocedure)) > 0,
  'The message trigger enforces both read-only and announcement publisher restrictions'
);

select extensions.ok(
  position('tm.role in (''owner'', ''captain'')' in
    pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) = 0,
  'Registration is not limited to team owners or captains'
);
select extensions.ok(
  position('Join the tournament community before registering your team' in
    pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) > 0,
  'A team registration submitter must have joined the tournament community'
);
select extensions.ok(
  position('v_joined_roster_count < v_min_roster' in
    pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) > 0
  and position('join public.community_members cm' in
    pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) > 0,
  'The team must have at least the required number of community-joined roster members'
);
select extensions.ok(
  position('when ''duo'' then 2 when ''squad'' then 4 else 1 end' in
    pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) > 0
  and position('when ''duo'' then 2 when ''squad'' then 4 else 1 end' in
    pg_get_functiondef('app_private.is_event_registration_eligible_player(uuid,uuid,uuid)'::regprocedure)) > 0,
  'Default minimum joined roster is Duo 2 and Squad 4, overridable by configured rules'
);
select extensions.ok(
  position('v_event.registration_opens_at > now()' in
    pg_get_functiondef('app_private.register_for_event(uuid,uuid)'::regprocedure)) > 0,
  'Actual event registration is rejected before its configured start time'
);
select extensions.ok(
  position('v_event.registration_closes_at <= now()' in
    pg_get_functiondef('app_private.can_write_event_registration_channel(uuid)'::regprocedure)) > 0
  and position('v_event.status NOT IN (''published'',''registration_open'')' in
    pg_get_functiondef('app_private.can_write_event_registration_channel(uuid)'::regprocedure)) > 0,
  'Test-registration writing is limited to published/registration-open events before close'
);

select extensions.ok(
  position('(5,''registration'',''Registration instructions and status.'',''announcement'',false,true)' in
    pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0,
  'Registration channel defaults to public-to-event read-only'
);
select extensions.ok(
  position('(7,''test-registration'',''Registration-system test notices. Test entries must never count as real registrations.'',''text'',false,true)' in
    pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0,
  'Test-registration channel defaults to public-to-event read-only'
);
select extensions.ok(
  position('(8,''help-desk'',''Participant questions and support.'',''text'',false,false)' in
    pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0
  and position('(9,''help-desk-voice'',''Voice support for tournament participants.'',''voice'',false,false)' in
    pg_get_functiondef('public.publish_tournament_proposal(uuid,uuid)'::regprocedure)) > 0,
  'Text and voice help-desk channels default to event-audience read/write'
);
select extensions.ok(
  position('can_access_event_channel_scope' in
    pg_get_functiondef('app_private.can_view_channel_resource(uuid)'::regprocedure)) > 0
  and position('resolve_permission(''event.view'',''event''' in
    pg_get_functiondef('app_private.can_access_event_channel_scope(uuid,uuid,uuid,uuid,uuid)'::regprocedure)) > 0,
  'Registration and test-registration remain readable by the event audience'
);

select * from extensions.finish();
rollback;
