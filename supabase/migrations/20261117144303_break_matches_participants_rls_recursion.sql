-- Break recursive RLS evaluation between matches and match_participants.
-- matches previously queried match_participants in its SELECT policy while
-- match_participants policies queried matches, causing SQLSTATE 42P17.
begin;

create or replace function app_private.is_match_team_participant(p_match_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.match_participants as mp
    join public.team_members as tm
      on tm.team_id = mp.team_id
    where mp.match_id = p_match_id
      and tm.user_id = (select auth.uid())
  );
$function$;

revoke all on function app_private.is_match_team_participant(uuid)
  from public, anon;
grant execute on function app_private.is_match_team_participant(uuid)
  to authenticated;

drop policy if exists matches_read_event_members on public.matches;
create policy matches_read_event_members
on public.matches
for select
to authenticated
using (
  app_private.is_event_staff(event_id)
  or app_private.is_match_team_participant(id)
);

comment on function app_private.is_match_team_participant(uuid) is
  'RLS-safe check for whether the current user belongs to a team participating in a match; runs as the trusted function owner to avoid recursive matches/match_participants policies.';

commit;
