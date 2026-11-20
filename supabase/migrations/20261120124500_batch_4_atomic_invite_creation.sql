-- Atomic invite issuance: permission, lockdown check, audit and insert share one DB transaction.
create or replace function public.create_community_invite(
 p_community_id uuid,
 p_token_hash text,
 p_max_uses integer default null,
 p_expires_at timestamptz default null,
 p_requires_approval boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
 v_uid uuid := (select auth.uid());
 v_settings public.community_safety_settings%rowtype;
 v_invite public.community_invites%rowtype;
begin
 if v_uid is null then
  raise exception using errcode='28000',message='Authentication required.';
 end if;
 if p_community_id is null then
  raise exception using errcode='22023',message='Community id is required.';
 end if;
 if p_token_hash !~ '^[0-9a-f]{64}$' then
  raise exception using errcode='22023',message='Invite token hash must be a 64-character SHA-256 digest.';
 end if;
 if p_max_uses is not null and p_max_uses not between 1 and 500 then
  raise exception using errcode='22023',message='Invite usage limit must be between 1 and 500.';
 end if;
 if p_expires_at is not null and
   (p_expires_at <= now() or p_expires_at > now()+interval '30 days') then
  raise exception using errcode='22023',message='Invite expiry must be within the next 30 days.';
 end if;
 if not app_private.resolve_permission(
  'community.manage_invites','community',p_community_id,null,null
 ) then
  raise exception using errcode='42501',message='You cannot create invites in this community.';
 end if;

 insert into public.community_safety_settings(community_id)
 values(p_community_id)
 on conflict(community_id) do nothing;
 select * into v_settings
 from public.community_safety_settings
 where community_id=p_community_id
 for update;

 if v_settings.pause_invites_during_lockdown
  and v_settings.lockdown_until is not null
  and v_settings.lockdown_until>now() then
  raise exception using errcode='42501',message='Invite creation is paused during raid lockdown.';
 end if;

 insert into public.community_invites(
  community_id,token_hash,created_by,max_uses,expires_at,requires_approval
 ) values(
  p_community_id,p_token_hash,v_uid,p_max_uses,p_expires_at,coalesce(p_requires_approval,false)
 )
 returning * into v_invite;

 insert into public.audit_logs(actor_id,community_id,entity_type,entity_id,action,metadata)
 values(v_uid,p_community_id,'community_invite',v_invite.id,'community.invite.created',
  jsonb_build_object('max_uses',v_invite.max_uses,'expires_at',v_invite.expires_at,
    'requires_approval',v_invite.requires_approval));

 return jsonb_build_object(
  'id',v_invite.id,
  'expires_at',v_invite.expires_at,
  'max_uses',v_invite.max_uses,
  'requires_approval',v_invite.requires_approval,
  'created_at',v_invite.created_at
 );
end;
$function$;
revoke all on function public.create_community_invite(uuid,text,integer,timestamp with time zone,boolean) from public,anon;
grant execute on function public.create_community_invite(uuid,text,integer,timestamp with time zone,boolean) to authenticated;