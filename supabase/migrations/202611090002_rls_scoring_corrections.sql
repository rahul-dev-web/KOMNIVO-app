-- Security and organiser scoring policy corrections for the initial KOMNIVO schema.
-- RLS predicates use tightly-scoped SECURITY DEFINER helpers to avoid recursive policy evaluation.

create or replace function public.is_community_member(p_community_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.community_members cm
    where cm.community_id = p_community_id and cm.user_id = auth.uid()
  )
$$;
revoke all on function public.is_community_member(uuid) from public, anon;
grant execute on function public.is_community_member(uuid) to authenticated;

create or replace function public.can_manage_community(p_community_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.community_members cm
    where cm.community_id = p_community_id and cm.user_id = auth.uid()
      and cm.role in ('owner', 'admin', 'moderator', 'organiser')
  )
$$;
revoke all on function public.can_manage_community(uuid) from public, anon;
grant execute on function public.can_manage_community(uuid) to authenticated;

create or replace function public.is_team_member(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.team_members tm
    where tm.team_id = p_team_id and tm.user_id = auth.uid()
  )
$$;
revoke all on function public.is_team_member(uuid) from public, anon;
grant execute on function public.is_team_member(uuid) to authenticated;

create or replace function public.is_event_staff(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.events e
    where e.id = p_event_id and (
      e.organizer_id = auth.uid()
      or (e.community_id is not null and public.can_manage_community(e.community_id))
    )
  )
$$;
revoke all on function public.is_event_staff(uuid) from public, anon;
grant execute on function public.is_event_staff(uuid) to authenticated;

-- Approval updates a submitted result; all score writes remain restricted to event staff.
drop policy if exists match_results_update_staff on public.match_results;
create policy match_results_update_staff on public.match_results
for update to authenticated
using (exists (
  select 1 from public.matches m where m.id = match_id and public.is_event_staff(m.event_id)
))
with check (exists (
  select 1 from public.matches m where m.id = match_id and public.is_event_staff(m.event_id)
));

-- The approval RPC inserts/updates official standings and its audit entry.
drop policy if exists standings_write_staff on public.event_standings;
create policy standings_write_staff on public.event_standings
for all to authenticated
using (public.is_event_staff(event_id))
with check (public.is_event_staff(event_id));

drop policy if exists audit_logs_insert_staff on public.audit_logs;
create policy audit_logs_insert_staff on public.audit_logs
for insert to authenticated
with check (
  (event_id is not null and public.is_event_staff(event_id))
  or (community_id is not null and public.can_manage_community(community_id))
);

-- A user cannot add themselves to a private or unrelated DM channel by guessing its UUID.
drop policy if exists channel_members_add_self on public.channel_members;
create policy channel_members_add_self on public.channel_members
for insert to authenticated
with check (
  user_id = auth.uid()
  and exists (
    select 1 from public.channels c
    where c.id = channel_id and c.community_id is not null
      and not c.is_private and public.is_community_member(c.community_id)
  )
);

grant select, insert, update on public.event_standings to authenticated;
grant insert on public.audit_logs to authenticated;
