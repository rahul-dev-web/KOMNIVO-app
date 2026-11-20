-- Batch 4 Checklist 2: enforce raid lockdown on both approved join RPCs and direct public-member inserts.
-- The helper is SECURITY DEFINER because ordinary members cannot read the manager-only safety row.
create or replace function app_private.is_community_join_locked(p_community_id uuid)
returns boolean
language sql
stable
security definer
set search_path=''
as $function$
  select exists (
    select 1
    from public.community_safety_settings s
    where s.community_id=p_community_id
      and s.lockdown_until is not null
      and s.lockdown_until>now()
  );
$function$;
revoke all on function app_private.is_community_join_locked(uuid) from public,anon;
grant execute on function app_private.is_community_join_locked(uuid) to authenticated;

create or replace function app_private.join_community_with_invite(
 p_community_id uuid,p_token_hash text default null,p_applicant_note text default ''
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
 v_uid uuid := (select auth.uid());
 v_community public.communities%rowtype;
 v_invite public.community_invites%rowtype;
 v_request public.community_join_requests%rowtype;
 v_requires_approval boolean := false;
begin
 if v_uid is null then raise exception using errcode='28000',message='Authentication required.'; end if;
 if char_length(coalesce(p_applicant_note,''))>1000 then
  raise exception using errcode='22023',message='Application note cannot exceed 1000 characters.';
 end if;
 select * into v_community from public.communities c where c.id=p_community_id for share;
 if not found then raise exception using errcode='P0002',message='Community not found.'; end if;
 if exists(select 1 from public.community_member_restrictions r
   where r.community_id=p_community_id and r.target_user_id=v_uid
     and r.restriction_type='ban' and r.revoked_at is null
     and (r.expires_at is null or r.expires_at>now()))
 then raise exception using errcode='42501',message='You are banned from this community.'; end if;
 if app_private.is_community_join_locked(p_community_id) then
  raise exception using errcode='42501',message='New community joins are paused during raid lockdown.';
 end if;
 if exists(select 1 from public.community_members cm
   where cm.community_id=p_community_id and cm.user_id=v_uid)
 then return jsonb_build_object('status','already_member','community_id',p_community_id); end if;

 if v_community.visibility='private' or p_token_hash is not null then
  if nullif(p_token_hash,'') is null then
   raise exception using errcode='42501',message='A valid invite is required.';
  end if;
  select * into v_invite from public.community_invites i
  where i.community_id=p_community_id and i.token_hash=p_token_hash for update;
  if not found or v_invite.revoked_at is not null
    or (v_invite.expires_at is not null and v_invite.expires_at<=now())
    or (v_invite.max_uses is not null and v_invite.uses>=v_invite.max_uses)
  then
   raise exception using errcode='42501',message='Invite is invalid, revoked, expired or exhausted.';
  end if;
  v_requires_approval:=v_invite.requires_approval;
 end if;
 v_requires_approval:=v_requires_approval or v_community.join_approval_required;

 if v_requires_approval then
  select * into v_request from public.community_join_requests r
  where r.community_id=p_community_id and r.user_id=v_uid and r.status='pending' for update;
  if found then
   return jsonb_build_object('status','pending_approval','request_id',v_request.id,'community_id',p_community_id);
  end if;
  insert into public.community_join_requests(community_id,user_id,invite_id,applicant_note,status)
  values(p_community_id,v_uid,case when v_invite.id is null then null else v_invite.id end,
    btrim(coalesce(p_applicant_note,'')),'pending') returning * into v_request;
  if v_invite.id is not null then update public.community_invites set uses=uses+1 where id=v_invite.id; end if;
  insert into public.audit_logs(actor_id,community_id,entity_type,entity_id,action,metadata)
  values(v_uid,p_community_id,'community_join_request',v_request.id,'community.join_request.submitted',
    jsonb_build_object('invite_id',v_request.invite_id));
  return jsonb_build_object('status','pending_approval','request_id',v_request.id,'community_id',p_community_id);
 end if;

 insert into public.community_members(community_id,user_id,role)
 values(p_community_id,v_uid,'member') on conflict(community_id,user_id) do nothing;
 if v_invite.id is not null then update public.community_invites set uses=uses+1 where id=v_invite.id; end if;
 return jsonb_build_object('status','joined','community_id',p_community_id);
end;
$function$;
revoke all on function app_private.join_community_with_invite(uuid,text,text) from public,anon,authenticated;
grant execute on function app_private.join_community_with_invite(uuid,text,text) to authenticated;

drop policy if exists community_members_join_self on public.community_members;
create policy community_members_join_self on public.community_members for insert to authenticated
with check(
 user_id=(select auth.uid()) and role='member'
 and exists(select 1 from public.communities c
   where c.id=community_members.community_id and c.visibility='public'
     and not c.join_approval_required)
 and not app_private.is_community_join_locked(community_id)
 and not exists(select 1 from public.community_member_restrictions r
   where r.community_id=community_members.community_id
     and r.target_user_id=(select auth.uid()) and r.restriction_type='ban'
     and r.revoked_at is null and (r.expires_at is null or r.expires_at>now()))
);
