-- Published-event spectator reads.
-- Event schedules and participating team names may be visible to authenticated spectators.
-- Room credentials, registration PII, check-in identities and private evidence remain protected.

drop policy if exists matches_read_published_event on public.matches;
create policy matches_read_published_event
on public.matches for select to authenticated
using (exists (
  select 1 from public.events e
  where e.id = event_id and e.status in ('published','registration_open','registration_closed','live','completed')
));

drop policy if exists participants_read_published_event on public.match_participants;
create policy participants_read_published_event
on public.match_participants for select to authenticated
using (exists (
  select 1 from public.matches m
  join public.events e on e.id = m.event_id
  where m.id = match_id and e.status in ('published','registration_open','registration_closed','live','completed')
));

-- Event rounds/groups are already restricted to published events or event staff.
-- This migration intentionally does not broaden room_credentials or event_registrations.
