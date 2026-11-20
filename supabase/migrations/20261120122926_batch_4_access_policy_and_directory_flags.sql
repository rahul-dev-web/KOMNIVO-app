-- Batch 4 directory privacy flags and persisted community access settings.
create or replace function public.update_community_access_policy(
 p_community_id uuid,p_visibility text,p_require_approval boolean
)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare v_uid uuid := (select auth.uid());
begin
 if v_uid is null then raise exception using errcode='28000',message='Authentication required.'; end if;
 if p_visibility not in ('public','private') then
  raise exception using errcode='22023',message='Visibility must be public or private.';
 end if;
 if not app_private.resolve_permission('community.manage_invites','community',p_community_id,null,null) then
  raise exception using errcode='42501',message='You cannot manage community access policy.';
 end if;
 update public.communities set visibility=p_visibility,join_approval_required=p_require_approval,updated_at=now()
 where id=p_community_id;
 if not found then raise exception using errcode='P0002',message='Community not found.'; end if;
 insert into public.audit_logs(actor_id,community_id,entity_type,action,metadata)
 values(v_uid,p_community_id,'community','community.access_policy.updated',
  jsonb_build_object('visibility',p_visibility,'join_approval_required',p_require_approval));
 return jsonb_build_object('saved',true,'visibility',p_visibility,'join_approval_required',p_require_approval);
end;
$function$;

revoke all on function public.update_community_access_policy(uuid,text,boolean) from public,anon;
grant execute on function public.update_community_access_policy(uuid,text,boolean) to authenticated;

drop function if exists public.get_community_member_directory(uuid);
drop function if exists app_private.get_community_member_directory(uuid);

CREATE OR REPLACE FUNCTION app_private.get_community_member_directory(p_community_id uuid)
 RETURNS TABLE(user_id uuid, role text, joined_at timestamp with time zone, muted_until timestamp with time zone, profiles jsonb, _community_roles jsonb, _game_accounts jsonb, _is_team_captain boolean, _is_event_participant boolean, _is_event_staff boolean, _is_restricted boolean, _is_recent_join boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_uid uuid := (select auth.uid());
 v_can_manage_members boolean;
begin
 if v_uid is null then raise exception using errcode='28000',message='Authentication required.'; end if;
 if p_community_id is null or not app_private.is_community_member(p_community_id) then
  raise exception using errcode='42501',message='Community membership is required to view its directory.';
 end if;
 if not app_private.resolve_permission('community.view','community',p_community_id,null,null) then
  raise exception using errcode='42501',message='You do not have permission to view this community.';
 end if;
 v_can_manage_members:=app_private.resolve_permission('community.manage_members','community',p_community_id,null,null);

 return query
 select
  cm.user_id,
  cm.role,
  cm.joined_at,
  case when v_can_manage_members or cm.user_id=v_uid then cm.muted_until else null end,
  jsonb_build_object(
   'display_name',case when p.is_public or p.id=v_uid or v_can_manage_members then p.display_name else 'Private member' end,
   'username',case when p.is_public or p.id=v_uid or v_can_manage_members then p.username else null end,
   'avatar_url',case when p.is_public or p.id=v_uid or v_can_manage_members then p.avatar_url else null end,
   'region',case when p.is_public or p.id=v_uid or v_can_manage_members then p.region else null end,
   'is_public',p.is_public
  ),
  case when v_can_manage_members or cm.user_id=v_uid then coalesce((
   select jsonb_agg(jsonb_build_object('name',cr.name,'preset_key',cr.preset_key,'colour',cr.colour)
    order by cr.position desc,cr.name)
   from public.community_member_roles cmr
   join public.community_roles cr on cr.id=cmr.role_id and cr.community_id=cmr.community_id
   where cmr.community_id=cm.community_id and cmr.user_id=cm.user_id and cr.archived_at is null
  ),'[]'::jsonb) else '[]'::jsonb end,
  case when exists(select 1 from public.game_accounts ga
    where ga.user_id=cm.user_id and ga.ownership_status='verified')
   then jsonb_build_array(jsonb_build_object('ownership_status','verified'))
   else '[]'::jsonb end,
  (exists(select 1 from public.teams t join public.team_members tm on tm.team_id=t.id
      where t.community_id=cm.community_id and tm.user_id=cm.user_id and tm.role in ('owner','captain'))
   or exists(select 1 from public.teams t where t.community_id=cm.community_id and t.owner_user_id=cm.user_id)),
  exists(
   select 1 from public.events e join public.event_registrations er on er.event_id=e.id
   where e.community_id=cm.community_id and er.status in ('approved','checked_in')
   and (er.captain_user_id=cm.user_id
     or (er.team_id is not null and exists(select 1 from public.team_members tm
       where tm.team_id=er.team_id and tm.user_id=cm.user_id))
     or exists(select 1 from public.registration_players rp
       where rp.registration_id=er.id and rp.user_id=cm.user_id))
  ),
  exists(select 1 from public.event_staff_assignments esa
   join public.events e on e.id=esa.event_id
   where e.community_id=cm.community_id and esa.user_id=cm.user_id),
  case when v_can_manage_members then exists(
   select 1 from public.community_member_restrictions r
   where r.community_id=cm.community_id and r.target_user_id=cm.user_id
    and r.revoked_at is null and (r.expires_at is null or r.expires_at>now())
  ) or (cm.muted_until is not null and cm.muted_until>now())
  else (cm.user_id=v_uid and cm.muted_until is not null and cm.muted_until>now()) end,
  cm.joined_at>now()-interval '7 days'
 from public.community_members cm
 join public.profiles p on p.id=cm.user_id
 where cm.community_id=p_community_id
 order by cm.joined_at desc,p.display_name
 limit 1000;
end;
$function$;


revoke all on function app_private.get_community_member_directory(uuid) from public,anon;
grant execute on function app_private.get_community_member_directory(uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.get_community_member_directory(p_community_id uuid)
 RETURNS TABLE(user_id uuid, role text, joined_at timestamp with time zone, muted_until timestamp with time zone, profiles jsonb, _community_roles jsonb, _game_accounts jsonb, _is_team_captain boolean, _is_event_participant boolean, _is_event_staff boolean, _is_restricted boolean, _is_recent_join boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$ select * from app_private.get_community_member_directory(p_community_id); $function$;


revoke all on function public.get_community_member_directory(uuid) from public,anon;
grant execute on function public.get_community_member_directory(uuid) to authenticated;

create index if not exists community_join_requests_reviewer_idx
 on public.community_join_requests(community_id,reviewer_id,reviewed_at desc);
create index if not exists moderation_reports_community_queue_idx
 on public.moderation_reports(community_id,status,created_at desc);
create index if not exists audit_logs_community_moderation_idx
 on public.audit_logs(community_id,created_at desc)
 where entity_type in ('moderation_action','moderation_appeal','moderation_report','community_join_request');
