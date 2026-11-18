-- Batch 1: remove legacy event-wide roster/result readers that bypass match scope.
-- Published event status does not grant access to private match participant records.
drop policy if exists participants_read_published_event on public.match_participants;

-- Result visibility is match-bound: the current match's participants and authorised
-- reviewers/host may read it, but membership in some other match in the event is not enough.
drop policy if exists results_read_participant_or_staff on public.match_results;
create policy results_read_participant_or_staff
on public.match_results
for select to authenticated
using (
  app_private.resolve_permission('match.results.review','match',match_id,null,null)
  or app_private.resolve_permission('match.disputes.review','match',match_id,null,null)
  or app_private.is_match_host(match_id)
  or app_private.is_match_team_participant(match_id)
);

comment on policy participants_read_team_or_staff on public.match_participants is
  'Roster visibility is participant/team scoped through the canonical permission resolver; published event status alone does not expose rosters.';
comment on policy results_read_participant_or_staff on public.match_results is
  'Result visibility is scoped to this match and its participants or authorised reviewers; legacy event-wide visibility is not permitted.';
