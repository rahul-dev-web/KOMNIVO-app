-- Batch 4 Checklist 1 privacy hardening.
-- Keep private profile fields and onboarding answers strictly need-to-know.

create index if not exists community_onboarding_questions_created_by_idx
  on public.community_onboarding_questions(created_by);
create index if not exists community_onboarding_questions_updated_by_idx
  on public.community_onboarding_questions(updated_by);
create index if not exists community_onboarding_responses_user_id_idx
  on public.community_onboarding_responses(user_id);

drop policy if exists community_onboarding_responses_read_self_or_manager
  on public.community_onboarding_responses;
create policy community_onboarding_responses_read_self
on public.community_onboarding_responses
for select to authenticated
using (
  user_id=(select auth.uid())
  and app_private.is_community_member(community_id)
);

create or replace function app_private.get_community_member_directory(
  p_community_id uuid
)
returns table (
  user_id uuid,
  role text,
  joined_at timestamptz,
  muted_until timestamptz,
  profiles jsonb,
  _community_roles jsonb,
  _game_accounts jsonb,
  _is_team_captain boolean,
  _is_event_participant boolean,
  _is_event_staff boolean
)
language plpgsql
stable
security definer
set search_path=''
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_can_manage_members boolean;
begin
  if v_uid is null then
    raise exception using errcode='28000',message='Authentication required.';
  end if;
  if p_community_id is null or not app_private.is_community_member(p_community_id) then
    raise exception using errcode='42501',message='Community membership is required to view its directory.';
  end if;
  if not app_private.resolve_permission('community.view','community',p_community_id,null,null) then
    raise exception using errcode='42501',message='You do not have permission to view this community.';
  end if;

  v_can_manage_members := app_private.resolve_permission(
    'community.manage_members','community',p_community_id,null,null
  );

  return query
  select
    cm.user_id,
    cm.role,
    cm.joined_at,
    cm.muted_until,
    jsonb_build_object(
      'display_name',case when p.is_public or p.id=v_uid then p.display_name else 'Private member' end,
      'username',case when p.is_public or p.id=v_uid then p.username else null end,
      'avatar_url',case when p.is_public or p.id=v_uid then p.avatar_url else null end,
      'region',case when p.is_public or p.id=v_uid then p.region else null end,
      'is_public',p.is_public
    ) as profiles,
    case when v_can_manage_members or cm.user_id=v_uid then coalesce((
      select jsonb_agg(
        jsonb_build_object('name',cr.name,'preset_key',cr.preset_key,'colour',cr.colour)
        order by cr.position desc,cr.name
      )
      from public.community_member_roles cmr
      join public.community_roles cr
        on cr.id=cmr.role_id and cr.community_id=cmr.community_id
      where cmr.community_id=cm.community_id
        and cmr.user_id=cm.user_id
        and cr.archived_at is null
    ),'[]'::jsonb) else '[]'::jsonb end as _community_roles,
    case when exists(
      select 1 from public.game_accounts ga
      where ga.user_id=cm.user_id and ga.ownership_status='verified'
    ) then jsonb_build_array(jsonb_build_object('ownership_status','verified'))
      else '[]'::jsonb
    end as _game_accounts,
    (
      exists(
        select 1 from public.teams t
        join public.team_members tm on tm.team_id=t.id
        where t.community_id=cm.community_id
          and tm.user_id=cm.user_id
          and tm.role in ('owner','captain')
      )
      or exists(
        select 1 from public.teams t
        where t.community_id=cm.community_id and t.owner_user_id=cm.user_id
      )
    ) as _is_team_captain,
    exists(
      select 1
      from public.events e
      join public.event_registrations er on er.event_id=e.id
      where e.community_id=cm.community_id
        and er.status in ('approved','checked_in')
        and (
          er.captain_user_id=cm.user_id
          or (
            er.team_id is not null
            and exists(
              select 1 from public.team_members tm
              where tm.team_id=er.team_id and tm.user_id=cm.user_id
            )
          )
          or exists(
            select 1 from public.registration_players rp
            where rp.registration_id=er.id and rp.user_id=cm.user_id
          )
        )
    ) as _is_event_participant,
    exists(
      select 1
      from public.event_staff_assignments esa
      join public.events e on e.id=esa.event_id
      where e.community_id=cm.community_id and esa.user_id=cm.user_id
    ) as _is_event_staff
  from public.community_members cm
  join public.profiles p on p.id=cm.user_id
  where cm.community_id=p_community_id
  order by cm.joined_at desc,p.display_name
  limit 1000;
end;
$function$;

revoke all on function app_private.get_community_member_directory(uuid) from public,anon;
grant execute on function app_private.get_community_member_directory(uuid) to authenticated;