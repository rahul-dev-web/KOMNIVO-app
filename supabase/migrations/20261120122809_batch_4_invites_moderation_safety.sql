-- Batch 4 Checklist 2: invitation and moderation server-side enforcement.
alter table public.communities add column if not exists join_approval_required boolean not null default false;
alter table public.community_invites
 add column if not exists revoked_at timestamptz,
 add column if not exists requires_approval boolean not null default false;

create table if not exists public.community_join_requests (
 id uuid primary key default gen_random_uuid(),
 community_id uuid not null references public.communities(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 invite_id uuid references public.community_invites(id) on delete set null,
 status text not null default 'pending' check(status in ('pending','approved','rejected','cancelled')),
 applicant_note text not null default '' check(char_length(applicant_note)<=1000),
 reviewer_id uuid references public.profiles(id) on delete set null,
 review_reason text not null default '' check(char_length(review_reason)<=1000),
 reviewed_at timestamptz, created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create unique index if not exists community_join_requests_one_pending_idx
 on public.community_join_requests(community_id,user_id) where status='pending';
create index if not exists community_join_requests_review_queue_idx
 on public.community_join_requests(community_id,status,created_at);
create index if not exists community_join_requests_user_idx on public.community_join_requests(user_id);
create index if not exists community_join_requests_invite_idx on public.community_join_requests(invite_id);
create index if not exists community_join_requests_reviewer_idx on public.community_join_requests(reviewer_id);

create table if not exists public.community_moderation_actions (
 id uuid primary key default gen_random_uuid(),
 community_id uuid not null references public.communities(id) on delete cascade,
 action_type text not null check(action_type in ('warn','delete_message','timeout','mute','restrict_channel','kick','ban','unban')),
 target_user_id uuid not null references public.profiles(id) on delete cascade,
 channel_id uuid references public.channels(id) on delete set null,
 message_id uuid references public.messages(id) on delete set null,
 reason text not null check(char_length(btrim(reason)) between 8 and 1000),
 duration_minutes integer check(duration_minutes is null or duration_minutes between 1 and 10080),
 status text not null default 'applied' check(status in ('applied','reversed','expired')),
 created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now(),
 reversed_by uuid references public.profiles(id),
 reversed_at timestamptz,
 metadata jsonb not null default '{}'::jsonb
);
create index if not exists community_moderation_actions_target_idx on public.community_moderation_actions(community_id,target_user_id,created_at desc);
create index if not exists community_moderation_actions_queue_idx on public.community_moderation_actions(community_id,status,created_at desc);
create index if not exists community_moderation_actions_channel_idx on public.community_moderation_actions(channel_id);
create index if not exists community_moderation_actions_message_idx on public.community_moderation_actions(message_id);
create index if not exists community_moderation_actions_created_by_idx on public.community_moderation_actions(created_by);
create index if not exists community_moderation_actions_reversed_by_idx on public.community_moderation_actions(reversed_by);

create table if not exists public.community_member_restrictions (
 id uuid primary key default gen_random_uuid(),
 community_id uuid not null references public.communities(id) on delete cascade,
 target_user_id uuid not null references public.profiles(id) on delete cascade,
 restriction_type text not null check(restriction_type in ('timeout','mute','channel_restriction','ban')),
 channel_id uuid references public.channels(id) on delete cascade,
 reason text not null check(char_length(btrim(reason)) between 8 and 1000),
 starts_at timestamptz not null default now(), expires_at timestamptz, revoked_at timestamptz,
 created_by uuid not null references public.profiles(id),
 moderation_action_id uuid references public.community_moderation_actions(id) on delete set null,
 created_at timestamptz not null default now(),
 check((restriction_type='channel_restriction' and channel_id is not null)
    or (restriction_type<>'channel_restriction' and channel_id is null))
);
create index if not exists community_member_restrictions_active_idx
 on public.community_member_restrictions(community_id,target_user_id,restriction_type,expires_at) where revoked_at is null;
create index if not exists community_member_restrictions_channel_idx
 on public.community_member_restrictions(channel_id,target_user_id,expires_at) where revoked_at is null and restriction_type='channel_restriction';
create index if not exists community_member_restrictions_created_by_idx on public.community_member_restrictions(created_by);
create index if not exists community_member_restrictions_action_idx on public.community_member_restrictions(moderation_action_id);

create table if not exists public.community_moderation_appeals (
 id uuid primary key default gen_random_uuid(),
 community_id uuid not null references public.communities(id) on delete cascade,
 moderation_action_id uuid not null references public.community_moderation_actions(id) on delete cascade,
 appellant_id uuid not null references public.profiles(id) on delete cascade,
 reason text not null check(char_length(btrim(reason)) between 3 and 120),
 details text not null check(char_length(btrim(details)) between 10 and 3000),
 evidence_reference text not null default '' check(char_length(evidence_reference)<=1000),
 status text not null default 'pending' check(status in ('pending','reviewing','upheld','modified','revoked','dismissed')),
 reviewer_id uuid references public.profiles(id),
 reviewer_response text not null default '' check(char_length(reviewer_response)<=2000),
 reviewed_at timestamptz, created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint community_moderation_appeals_one_per_action unique(moderation_action_id,appellant_id)
);
create index if not exists community_moderation_appeals_queue_idx on public.community_moderation_appeals(community_id,status,created_at);
create index if not exists community_moderation_appeals_appellant_idx on public.community_moderation_appeals(appellant_id);
create index if not exists community_moderation_appeals_reviewer_idx on public.community_moderation_appeals(reviewer_id);

create table if not exists public.community_safety_settings (
 community_id uuid primary key references public.communities(id) on delete cascade,
 message_burst_limit integer not null default 6 check(message_burst_limit between 1 and 60),
 message_window_seconds integer not null default 10 check(message_window_seconds between 5 and 300),
 mention_burst_limit integer not null default 4 check(mention_burst_limit between 1 and 30),
 mention_window_seconds integer not null default 60 check(mention_window_seconds between 10 and 900),
 restrict_links_for_new_members boolean not null default false,
 new_member_link_restriction_hours integer not null default 24 check(new_member_link_restriction_hours between 1 and 720),
 pause_invites_during_lockdown boolean not null default true,
 raid_join_threshold integer not null default 10 check(raid_join_threshold between 3 and 100),
 raid_window_seconds integer not null default 60 check(raid_window_seconds between 10 and 600),
 lockdown_until timestamptz,
 lockdown_reason text not null default '' check(char_length(lockdown_reason)<=500),
 updated_by uuid references public.profiles(id), updated_at timestamptz not null default now()
);
create index if not exists community_safety_settings_updated_by_idx on public.community_safety_settings(updated_by);
insert into public.community_safety_settings(community_id) select id from public.communities on conflict do nothing;

alter table public.community_join_requests enable row level security;
alter table public.community_moderation_actions enable row level security;
alter table public.community_member_restrictions enable row level security;
alter table public.community_moderation_appeals enable row level security;
alter table public.community_safety_settings enable row level security;
revoke all on public.community_join_requests,public.community_moderation_actions,public.community_member_restrictions,
 public.community_moderation_appeals,public.community_safety_settings from public,anon,authenticated;
grant select on public.community_join_requests,public.community_moderation_actions,
 public.community_moderation_appeals,public.community_safety_settings to authenticated;

drop policy if exists community_join_requests_read_self_or_reviewer on public.community_join_requests;
create policy community_join_requests_read_self_or_reviewer on public.community_join_requests for select to authenticated
using(user_id=(select auth.uid()) or app_private.resolve_permission('community.manage_members','community',community_id,null,null));
drop policy if exists community_moderation_actions_read_subject_or_manager on public.community_moderation_actions;
create policy community_moderation_actions_read_subject_or_manager on public.community_moderation_actions for select to authenticated
using(target_user_id=(select auth.uid()) or app_private.resolve_permission('community.manage_members','community',community_id,null,null));
drop policy if exists community_moderation_appeals_read_appellant_or_reviewer on public.community_moderation_appeals;
create policy community_moderation_appeals_read_appellant_or_reviewer on public.community_moderation_appeals for select to authenticated
using(appellant_id=(select auth.uid()) or app_private.resolve_permission('community.manage_members','community',community_id,null,null));
drop policy if exists community_safety_settings_read_manager on public.community_safety_settings;
create policy community_safety_settings_read_manager on public.community_safety_settings for select to authenticated
using(app_private.resolve_permission('community.manage_settings','community',community_id,null,null));

drop policy if exists moderation_reports_insert_self on public.moderation_reports;
drop policy if exists moderation_reports_read_reporter_or_staff on public.moderation_reports;
drop policy if exists moderation_reports_update_staff on public.moderation_reports;
drop policy if exists moderation_reports_read_reporter_or_moderator on public.moderation_reports;
create policy moderation_reports_read_reporter_or_moderator on public.moderation_reports for select to authenticated
using(reporter_id=(select auth.uid()) or (community_id is not null and app_private.resolve_permission('community.manage_members','community',community_id,null,null)));
revoke insert,update,delete on public.moderation_reports from anon,authenticated;
grant select on public.moderation_reports to authenticated;

drop policy if exists community_members_join_self on public.community_members;
create policy community_members_join_self on public.community_members for insert to authenticated
with check(user_id=(select auth.uid()) and role='member'
 and exists(select 1 from public.communities c where c.id=community_members.community_id
   and c.visibility='public' and not c.join_approval_required)
 and not exists(select 1 from public.community_member_restrictions r
   where r.community_id=community_members.community_id and r.target_user_id=(select auth.uid())
    and r.restriction_type='ban' and r.revoked_at is null and (r.expires_at is null or r.expires_at>now())));

CREATE OR REPLACE FUNCTION app_private.consume_community_invite(p_community_id uuid, p_token_hash text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_result jsonb;
begin
 v_result:=app_private.join_community_with_invite(p_community_id,p_token_hash,'');
 return v_result->>'status' in ('joined','already_member');
end;
$function$;


CREATE OR REPLACE FUNCTION app_private.detect_community_join_raid()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_settings public.community_safety_settings%rowtype; v_recent integer;
begin
 insert into public.community_safety_settings(community_id) values(new.community_id) on conflict do nothing;
 select * into v_settings from public.community_safety_settings
 where community_id=new.community_id for update;
 select count(*) into v_recent from public.community_members cm
 where cm.community_id=new.community_id
  and cm.joined_at>now()-make_interval(secs=>v_settings.raid_window_seconds);
 if v_recent>=v_settings.raid_join_threshold
  and (v_settings.lockdown_until is null or v_settings.lockdown_until<=now()) then
  update public.community_safety_settings set lockdown_until=now()+interval '15 minutes',
   lockdown_reason='Automatic raid response: unusual join velocity',updated_at=now()
  where community_id=new.community_id;
  insert into public.audit_logs(community_id,entity_type,action,metadata)
  values(new.community_id,'community_safety_settings','community.raid_lockdown.automatic',
   jsonb_build_object('recent_joins',v_recent,'window_seconds',v_settings.raid_window_seconds,
    'trigger_threshold',v_settings.raid_join_threshold));
 end if;
 return new;
end;
$function$;


CREATE OR REPLACE FUNCTION app_private.guard_batch4_member_restrictions()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_community_id uuid; v_settings public.community_safety_settings%rowtype;
 v_joined_at timestamptz; v_count integer; v_mentions integer;
begin
 if auth.uid() is null or app_private.is_batch3_maintenance_context() then return new; end if;
 select c.community_id into v_community_id from public.channels c
 where c.id=new.channel_id and c.archived_at is null;
 if not found or v_community_id is null then return new; end if;
 if not app_private.is_community_member(v_community_id)
 then raise exception using errcode='42501',message='Active community membership is required to send messages.'; end if;
 if app_private.resolve_permission('community.manage_members','community',v_community_id,null,null) then return new; end if;
 if exists(select 1 from public.community_member_restrictions r
  where r.community_id=v_community_id and r.target_user_id=new.sender_id and r.revoked_at is null
   and (r.expires_at is null or r.expires_at>now())
   and (r.restriction_type in ('timeout','mute','ban')
     or (r.restriction_type='channel_restriction' and r.channel_id=new.channel_id)))
 then raise exception using errcode='42501',message='An active moderation restriction prevents this message.'; end if;
 select * into v_settings from public.community_safety_settings s where s.community_id=v_community_id;
 if not found then return new; end if;
 if v_settings.lockdown_until is not null and v_settings.lockdown_until>now()
 then raise exception using errcode='42501',message='This community is temporarily in raid lockdown.'; end if;
 select cm.joined_at into v_joined_at from public.community_members cm
 where cm.community_id=v_community_id and cm.user_id=new.sender_id;
 if v_settings.restrict_links_for_new_members
  and v_joined_at>now()-make_interval(hours=>v_settings.new_member_link_restriction_hours)
  and new.body ~* '(https?://|www[.])'
 then raise exception using errcode='42501',message='Links are temporarily restricted for new community members.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(v_community_id::text||':'||new.sender_id::text,0));
 select count(*) into v_count from public.messages m join public.channels c on c.id=m.channel_id
 where c.community_id=v_community_id and m.sender_id=new.sender_id and m.deleted_at is null
  and m.created_at>now()-make_interval(secs=>v_settings.message_window_seconds);
 if v_count>=v_settings.message_burst_limit
 then raise exception using errcode='P0001',message='Community message rate limit reached. Please wait before sending again.'; end if;
 select count(*) into v_mentions
 from regexp_matches(new.body,'<@!?[0-9a-fA-F-]{36}>|@([[:alnum:]_]+)','g') matches;
 if v_mentions>0 then
  select count(*) into v_count from public.messages m join public.channels c on c.id=m.channel_id
  where c.community_id=v_community_id and m.sender_id=new.sender_id and m.deleted_at is null
   and m.body ~ '(<@!?[0-9a-fA-F-]{36}>|@[[:alnum:]_]+)'
   and m.created_at>now()-make_interval(secs=>v_settings.mention_window_seconds);
  if v_count>=v_settings.mention_burst_limit
  then raise exception using errcode='P0001',message='Community mention rate limit reached. Please wait before mentioning again.'; end if;
 end if;
 return new;
end;
$function$;


CREATE OR REPLACE FUNCTION app_private.is_community_member(p_community_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select exists(select 1 from public.community_members cm
   where cm.community_id=p_community_id and cm.user_id=(select auth.uid()))
 and not exists(select 1 from public.community_member_restrictions r
   where r.community_id=p_community_id and r.target_user_id=(select auth.uid())
     and r.restriction_type='ban' and r.revoked_at is null
     and (r.expires_at is null or r.expires_at>now()));
$function$;


CREATE OR REPLACE FUNCTION app_private.join_community_with_invite(p_community_id uuid, p_token_hash text DEFAULT NULL::text, p_applicant_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_uid uuid := (select auth.uid());
 v_community public.communities%rowtype;
 v_invite public.community_invites%rowtype;
 v_request public.community_join_requests%rowtype;
 v_requires_approval boolean := false;
begin
 if v_uid is null then raise exception using errcode='28000',message='Authentication required.'; end if;
 if char_length(coalesce(p_applicant_note,''))>1000 then raise exception using errcode='22023',message='Application note cannot exceed 1000 characters.'; end if;
 select * into v_community from public.communities c where c.id=p_community_id for share;
 if not found then raise exception using errcode='P0002',message='Community not found.'; end if;
 if exists(select 1 from public.community_member_restrictions r
   where r.community_id=p_community_id and r.target_user_id=v_uid
     and r.restriction_type='ban' and r.revoked_at is null
     and (r.expires_at is null or r.expires_at>now()))
 then raise exception using errcode='42501',message='You are banned from this community.'; end if;
 if exists(select 1 from public.community_members cm
   where cm.community_id=p_community_id and cm.user_id=v_uid)
 then return jsonb_build_object('status','already_member','community_id',p_community_id); end if;

 if v_community.visibility='private' or p_token_hash is not null then
  if nullif(p_token_hash,'') is null then raise exception using errcode='42501',message='A valid invite is required.'; end if;
  select * into v_invite from public.community_invites i
  where i.community_id=p_community_id and i.token_hash=p_token_hash for update;
  if not found or v_invite.revoked_at is not null
    or (v_invite.expires_at is not null and v_invite.expires_at<=now())
    or (v_invite.max_uses is not null and v_invite.uses>=v_invite.max_uses)
  then raise exception using errcode='42501',message='Invite is invalid, revoked, expired or exhausted.'; end if;
  v_requires_approval := v_invite.requires_approval;
 end if;
 v_requires_approval := v_requires_approval or v_community.join_approval_required;

 if v_requires_approval then
  select * into v_request from public.community_join_requests r
  where r.community_id=p_community_id and r.user_id=v_uid and r.status='pending' for update;
  if found then return jsonb_build_object('status','pending_approval','request_id',v_request.id,'community_id',p_community_id); end if;
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


CREATE OR REPLACE FUNCTION app_private.resolve_permission(p_permission_key text, p_scope_type text, p_scope_id uuid, p_related_id uuid DEFAULT NULL::uuid, p_resource_id uuid DEFAULT NULL::uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := (select auth.uid());
  v_scope_type text;
  v_owner_override boolean := false;
  v_community_owner uuid;
  v_community_visibility text;
  v_member_role text;
  v_is_member boolean := false;
  v_is_owner boolean := false;
  v_builtin_allowed boolean := false;
  v_custom_allowed boolean := false;
  v_custom_denied boolean := false;
  v_override_allowed boolean := false;
  v_override_denied boolean := false;
  v_channel_private boolean := false;
  v_category_id uuid;
  v_direct_override_found boolean := false;
  v_team_owner uuid;
  v_team_public boolean := false;
  v_event_id uuid;
  v_event_organizer uuid;
  v_event_status text;
  v_is_organizer boolean := false;
  v_is_staff_role boolean := false;
  v_match_event uuid;
  v_match_host uuid;
  v_is_match_participant boolean := false;
  v_session_operator uuid;
  v_session_match uuid;
  v_session_event uuid;
begin
  if v_uid is null or p_permission_key is null or p_scope_type is null then
    return false;
  end if;

  select d.scope_type,d.owner_override
    into v_scope_type,v_owner_override
  from app_private.permission_definitions d
  where d.permission_key = p_permission_key;

  if not found or v_scope_type <> p_scope_type then
    return false;
  end if;

  if p_scope_type = 'platform' then
    -- No platform super-user or global administrator is defined in the current product.
    return false;
  elsif p_scope_type = 'user' then
    return p_scope_id = v_uid
      and p_permission_key in ('user.self.read','user.self.manage');
  elsif p_scope_id is null then
    return false;
  end if;

  if p_scope_type = 'community' then
    select c.owner_user_id,c.visibility
      into v_community_owner,v_community_visibility
    from public.communities c where c.id = p_scope_id;
    if not found then return false; end if;

    v_is_owner := v_community_owner = v_uid;
    select cm.role into v_member_role
    from public.community_members cm
    where cm.community_id = p_scope_id and cm.user_id = v_uid;
    
    v_is_member := found or v_is_owner;
    if not v_is_owner and exists (
      select 1 from public.community_member_restrictions r
      where r.community_id=p_scope_id and r.target_user_id=v_uid
        and r.restriction_type='ban' and r.revoked_at is null
        and (r.expires_at is null or r.expires_at>now())
    ) then return false; end if;


    if p_permission_key = 'community.view' then
      return v_is_member or v_community_visibility = 'public';
    end if;

    if not v_is_member then return false; end if;

    if p_permission_key like 'channel.%' and p_resource_id is null then
      return false;
    end if;

    if p_resource_id is not null then
      select c.is_private,c.category_id
        into v_channel_private,v_category_id
      from public.channels c
      where c.id = p_resource_id and c.community_id = p_scope_id and c.event_id is null;
      if not found then return false; end if;

      -- The most specific setting wins: channel override, otherwise category inheritance.
      -- Deny wins across roles at one level. No row means Inherit.
      select exists (
        select 1 from public.channel_permission_overrides cpo
        join public.community_member_roles cmr
          on cmr.role_id=cpo.role_id and cmr.community_id=cpo.community_id and cmr.user_id=v_uid
        where cpo.community_id=p_scope_id and cpo.channel_id=p_resource_id
          and cpo.permission_key=p_permission_key
      ) into v_direct_override_found;

      if v_direct_override_found then
        select coalesce(bool_or(cpo.effect='allow'),false),
               coalesce(bool_or(cpo.effect='deny'),false)
        into v_override_allowed,v_override_denied
        from public.channel_permission_overrides cpo
        join public.community_member_roles cmr
          on cmr.role_id=cpo.role_id and cmr.community_id=cpo.community_id and cmr.user_id=v_uid
        where cpo.community_id=p_scope_id and cpo.channel_id=p_resource_id
          and cpo.permission_key=p_permission_key;
      elsif v_category_id is not null then
        select coalesce(bool_or(cpo.effect='allow'),false),
               coalesce(bool_or(cpo.effect='deny'),false)
        into v_override_allowed,v_override_denied
        from public.category_permission_overrides cpo
        join public.community_member_roles cmr
          on cmr.role_id=cpo.role_id and cmr.community_id=cpo.community_id and cmr.user_id=v_uid
        where cpo.community_id=p_scope_id and cpo.category_id=v_category_id
          and cpo.permission_key=p_permission_key;
      end if;
    end if;

    select
      coalesce(bool_or(rp.allowed),false),
      coalesce(bool_or(not rp.allowed),false)
    into v_custom_allowed,v_custom_denied
    from public.community_member_roles cmr
    join public.role_permissions rp on rp.role_id = cmr.role_id
    where cmr.community_id = p_scope_id
      and cmr.user_id = v_uid
      and rp.permission_key = p_permission_key;

    if p_permission_key = 'channel.view' then
      v_builtin_allowed :=
        (not v_channel_private)
        or v_member_role in ('owner','admin','moderator','organiser')
        or exists (
          select 1 from public.channel_members cm
          where cm.channel_id = p_resource_id and cm.user_id = v_uid
        );
    else
      v_builtin_allowed := case p_permission_key
        when 'community.manage_settings' then v_is_owner
        when 'community.manage_structure' then v_is_owner or v_member_role in ('admin','moderator','organiser')
        when 'community.manage_members' then v_is_owner or v_member_role in ('admin','moderator')
        when 'community.manage_invites' then v_is_owner or v_member_role in ('admin','organiser')
        when 'community.manage_roles' then v_is_owner or v_member_role = 'admin'
        when 'community.manage_permissions' then v_is_owner
        when 'community.audit.read' then v_is_owner
        when 'channel.read_history' then
          (not v_channel_private)
          or v_member_role in ('owner','admin','moderator','organiser')
          or exists (select 1 from public.channel_members cm where cm.channel_id = p_resource_id and cm.user_id = v_uid)
        when 'channel.send_messages' then
          (not v_channel_private or v_member_role in ('owner','admin','moderator','organiser') or exists (
            select 1 from public.channel_members cm where cm.channel_id = p_resource_id and cm.user_id = v_uid
          ))
          and not exists (
            select 1 from public.community_members cm
            where cm.community_id = p_scope_id and cm.user_id = v_uid
              and cm.muted_until is not null and cm.muted_until > now()
          )
        when 'channel.react' then
          (not v_channel_private or v_member_role in ('owner','admin','moderator','organiser') or exists (
            select 1 from public.channel_members cm where cm.channel_id = p_resource_id and cm.user_id = v_uid
          ))
        when 'channel.manage_messages' then v_is_owner or v_member_role in ('admin','moderator')
        else false
      end;
    end if;

    if (v_custom_denied or v_override_denied)
       and not (v_is_owner and v_owner_override) then
      return false;
    end if;
    if v_is_owner and v_owner_override then return true; end if;
    return v_builtin_allowed or v_custom_allowed or v_override_allowed;

  elsif p_scope_type = 'team' then
    select t.owner_user_id,t.is_public
      into v_team_owner,v_team_public
    from public.teams t where t.id = p_scope_id;
    if not found then return false; end if;
    if p_permission_key = 'team.view' then
      return v_team_public or v_team_owner = v_uid or exists (
        select 1 from public.team_members tm where tm.team_id = p_scope_id and tm.user_id = v_uid
      );
    elsif p_permission_key = 'team.manage' then
      return v_team_owner = v_uid or exists (
        select 1 from public.team_members tm
        where tm.team_id = p_scope_id and tm.user_id = v_uid and tm.role in ('owner','captain')
      );
    end if;
    return false;

  elsif p_scope_type = 'event' then
    select e.organizer_id,e.status
      into v_event_organizer,v_event_status
    from public.events e where e.id = p_scope_id;
    if not found then return false; end if;

    v_is_organizer := v_event_organizer = v_uid;
    if p_permission_key = 'event.view' then
      return v_event_status in ('published','registration_open','registration_closed','live','completed')
        or v_is_organizer
        or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
        )
        or exists (
          select 1 from public.event_registrations er
          where er.event_id = p_scope_id and (
            er.captain_user_id = v_uid
            or (er.team_id is not null and exists (
              select 1 from public.team_members tm where tm.team_id = er.team_id and tm.user_id = v_uid
            ))
            or exists (
              select 1 from public.registration_players rp
              where rp.registration_id = er.id and rp.user_id = v_uid
            )
          )
        );
    end if;

    case p_permission_key
      when 'event.manage' then
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key in ('competition_manager','tournament_director')
        );
      when 'event.staff.assign' then
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key in ('competition_manager','tournament_director')
        );
      when 'event.matches.operate','event.checkin.manage','event.matches.manage',
           'event.room_credentials.read','event.room_credentials.release' then
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array['competition_manager','tournament_director']::text[])
        );
      when 'event.registrations.manage','event.roster.lock' then
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array['competition_manager','tournament_director']::text[])
        );
      when 'event.results.review' then
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array[
              'competition_manager','tournament_director','referee','result_reviewer','dispute_reviewer'
            ]::text[])
        );
      when 'event.disputes.review' then
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array['competition_manager','tournament_director','dispute_reviewer']::text[])
        );
      when 'event.standings.publish' then
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array['competition_manager','tournament_director','result_reviewer']::text[])
        );
      when 'event.audit.read' then
        return v_is_organizer or exists (
          select 1 from public.event_staff_assignments a
          where a.event_id = p_scope_id and a.user_id = v_uid
            and a.scope_type = 'event'
            and a.role_key = any(array['competition_manager','tournament_director']::text[])
        );
      else
        return false;
    end case;

  elsif p_scope_type = 'stage' then
    select r.event_id into v_event_id
    from public.event_rounds r where r.id = p_scope_id;
    if not found then return false; end if;
    if p_permission_key = 'stage.view' then
      return exists (
        select 1 from public.events e
        where e.id = v_event_id
          and e.status in ('published','registration_open','registration_closed','live','completed')
      )
      or app_private.resolve_permission('event.manage','event',v_event_id,null,null)
      or app_private.resolve_permission('event.results.review','event',v_event_id,null,null)
      or app_private.resolve_permission('event.disputes.review','event',v_event_id,null,null)
      or app_private.has_stage_staff_scope(p_scope_id, array[
        'competition_manager','tournament_director','match_operator','referee','result_reviewer','dispute_reviewer','support_staff','caster','streamer'
      ]::text[])
      or exists (
        select 1
        from public.event_groups g
        join public.event_group_teams gt on gt.group_id = g.id
        join public.team_members tm on tm.team_id = gt.team_id
        where g.round_id = p_scope_id and tm.user_id = v_uid
      );
    elsif p_permission_key = 'stage.manage' then
      return app_private.resolve_permission('event.matches.operate','event',v_event_id,null,null);
    end if;
    return false;

  elsif p_scope_type = 'group' then
    select r.event_id into v_event_id
    from public.event_groups g
    join public.event_rounds r on r.id = g.round_id
    where g.id = p_scope_id;
    if not found then return false; end if;
    if p_permission_key = 'group.view' then
      return exists (
        select 1 from public.events e
        where e.id = v_event_id
          and e.status in ('published','registration_open','registration_closed','live','completed')
      )
      or app_private.resolve_permission('event.manage','event',v_event_id,null,null)
      or app_private.resolve_permission('event.results.review','event',v_event_id,null,null)
      or app_private.resolve_permission('event.disputes.review','event',v_event_id,null,null)
      or app_private.has_group_staff_scope(p_scope_id, array[
        'competition_manager','tournament_director','match_operator','referee','result_reviewer','dispute_reviewer','support_staff','caster','streamer'
      ]::text[])
      or app_private.is_event_group_team_member(p_scope_id);
    elsif p_permission_key = 'group.manage' then
      return app_private.resolve_permission('event.matches.operate','event',v_event_id,null,null);
    end if;
    return false;

  elsif p_scope_type = 'match' then
    select m.event_id,m.host_user_id into v_match_event,v_match_host
    from public.matches m where m.id = p_scope_id;
    if not found then return false; end if;

    select exists (
      select 1
      from public.match_participants mp
      join public.team_members tm on tm.team_id = mp.team_id
      where mp.match_id = p_scope_id and tm.user_id = v_uid
    ) into v_is_match_participant;

    select e.status into v_event_status from public.events e where e.id = v_match_event;

    case p_permission_key
      when 'match.view' then
        return v_event_status in ('published','registration_open','registration_closed','live','completed')
          or coalesce(v_match_host = v_uid,false)
          or v_is_match_participant
          or app_private.resolve_permission('event.manage','event',v_match_event,null,null)
          or app_private.resolve_permission('event.results.review','event',v_match_event,null,null)
          or app_private.resolve_permission('event.disputes.review','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array[
            'match_operator','referee','result_reviewer','dispute_reviewer','support_staff','caster','streamer'
          ]::text[]);
      when 'match.participants.view' then
        return coalesce(v_match_host = v_uid,false)
          or v_is_match_participant
          or app_private.resolve_permission('event.matches.operate','event',v_match_event,null,null)
          or app_private.resolve_permission('match.results.review','match',p_scope_id,null,null)
          or app_private.resolve_permission('match.disputes.review','match',p_scope_id,null,null);
      when 'match.operate' then
        return coalesce(v_match_host = v_uid,false)
          or app_private.resolve_permission('event.matches.operate','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array['match_operator']::text[]);
      when 'match.credentials.release' then
        return coalesce(v_match_host = v_uid,false)
          or app_private.resolve_permission('event.room_credentials.release','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array['match_operator']::text[]);
      when 'match.credentials.read' then
        return coalesce(v_match_host = v_uid,false)
          or app_private.resolve_permission('event.room_credentials.read','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array['match_operator']::text[])
          or exists (
            select 1
            from public.match_participants mp
            join public.team_members tm on tm.team_id = mp.team_id
            where mp.match_id = p_scope_id
              and mp.check_in_status = 'ready'
              and tm.user_id = v_uid
          );
      when 'match.results.review' then
        return app_private.resolve_permission('event.results.review','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array['referee','result_reviewer']::text[]);
      when 'match.disputes.review' then
        return app_private.resolve_permission('event.disputes.review','event',v_match_event,null,null)
          or app_private.has_match_staff_scope(p_scope_id, array['dispute_reviewer']::text[]);
      when 'liveops.session.manage','liveops.capture.submit' then
        return app_private.resolve_permission('match.operate','match',p_scope_id,null,null);
      when 'liveops.capture.read' then
        return coalesce(v_match_host = v_uid,false)
          or app_private.resolve_permission('event.matches.operate','event',v_match_event,null,null)
          or app_private.resolve_permission('match.results.review','match',p_scope_id,null,null)
          or app_private.resolve_permission('match.disputes.review','match',p_scope_id,null,null);
      else
        return app_private.resolve_permission(p_permission_key,'event',v_match_event,null,null);
    end case;

  elsif p_scope_type = 'participant' then
    if p_related_id is null then return false; end if;
    if not exists (
      select 1 from public.match_participants mp
      where mp.match_id = p_scope_id and mp.team_id = p_related_id
    ) then return false; end if;
    if p_permission_key = 'participant.view' then
      return exists (
        select 1 from public.team_members tm
        where tm.team_id = p_related_id and tm.user_id = v_uid
      ) or app_private.resolve_permission('match.participants.view','match',p_scope_id,null,null);
    elsif p_permission_key = 'participant.checkin' then
      return exists (
        select 1 from public.team_members tm
        where tm.team_id = p_related_id and tm.user_id = v_uid
      );
    end if;
    return false;

  elsif p_scope_type = 'liveops_session' then
    select s.operator_id,s.match_id,s.event_id
      into v_session_operator,v_session_match,v_session_event
    from public.liveops_sessions s where s.id = p_scope_id;
    if not found then return false; end if;
    if p_permission_key = 'liveops.capture.review' then
      return app_private.resolve_permission('match.results.review','match',v_session_match,null,null);
    elsif p_permission_key = 'liveops.capture.read' then
      return v_session_operator = v_uid
        or app_private.resolve_permission('liveops.capture.read','match',v_session_match,null,null);
    elsif p_permission_key = 'liveops.session.manage' then
      return v_session_operator = v_uid
        and app_private.resolve_permission('liveops.session.manage','match',v_session_match,null,null);
    end if;
    return false;
  end if;

  return false;
end;
$function$;


CREATE OR REPLACE FUNCTION public.apply_community_moderation_action(p_community_id uuid, p_action_type text, p_target_user_id uuid, p_reason text, p_duration_minutes integer DEFAULT NULL::integer, p_channel_id uuid DEFAULT NULL::uuid, p_message_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_uid uuid:=(select auth.uid()); v_action_id uuid; v_restriction_id uuid;
 v_channel_community uuid; v_sender uuid; v_effective_channel uuid;
 v_expires timestamptz;
begin
 if v_uid is null then raise exception using errcode='28000',message='Authentication required.'; end if;
 if not app_private.resolve_permission('community.manage_members','community',p_community_id,null,null)
 then raise exception using errcode='42501',message='You cannot moderate members in this community.'; end if;
 if p_action_type not in ('warn','delete_message','timeout','mute','restrict_channel','kick','ban','unban')
 then raise exception using errcode='22023',message='Unsupported moderation action.'; end if;
 if char_length(btrim(coalesce(p_reason,'')))<8 or char_length(p_reason)>1000
 then raise exception using errcode='22023',message='A reason of 8–1000 characters is required.'; end if;
 if p_target_user_id is null then raise exception using errcode='22023',message='A target member is required.'; end if;
 if p_target_user_id=v_uid then raise exception using errcode='42501',message='Moderators cannot apply community actions to themselves.'; end if;
 if not exists(select 1 from public.community_members cm
   where cm.community_id=p_community_id and cm.user_id=p_target_user_id)
   and p_action_type<>'unban'
 then raise exception using errcode='P0002',message='Target is not an active community member.'; end if;
 if p_duration_minutes is not null and p_duration_minutes not between 1 and 10080
 then raise exception using errcode='22023',message='Duration must be between 1 minute and 7 days.'; end if;
 if p_action_type in ('timeout','mute') and p_duration_minutes is null
 then raise exception using errcode='22023',message='Timeout and mute actions require a duration.'; end if;
 if p_action_type='restrict_channel' then
  if p_channel_id is null then raise exception using errcode='22023',message='A channel is required.'; end if;
  select c.community_id into v_channel_community from public.channels c where c.id=p_channel_id and c.archived_at is null;
  if v_channel_community is distinct from p_community_id
  then raise exception using errcode='22023',message='Channel does not belong to this community.'; end if;
 end if;
 if p_action_type='delete_message' then
  if p_message_id is null then raise exception using errcode='22023',message='A message is required.'; end if;
  select m.sender_id,c.id into v_sender,v_effective_channel
  from public.messages m join public.channels c on c.id=m.channel_id
  where m.id=p_message_id and c.community_id=p_community_id and m.deleted_at is null;
  if not found then raise exception using errcode='P0002',message='Message not found or already deleted.'; end if;
  if v_sender is distinct from p_target_user_id
  then raise exception using errcode='22023',message='Message author does not match the selected target.'; end if;
  p_channel_id:=v_effective_channel;
 end if;
 v_expires:=case when p_duration_minutes is null then null else now()+make_interval(mins=>p_duration_minutes) end;
 insert into public.community_moderation_actions(
  community_id,action_type,target_user_id,channel_id,message_id,reason,duration_minutes,created_by
 ) values(p_community_id,p_action_type,p_target_user_id,p_channel_id,p_message_id,
  btrim(p_reason),p_duration_minutes,v_uid) returning id into v_action_id;

 if p_action_type='delete_message' then
  update public.messages set deleted_at=now() where id=p_message_id and deleted_at is null;
 elsif p_action_type in ('timeout','mute','restrict_channel','ban') then
  if p_action_type in ('timeout','mute') then
   update public.community_member_restrictions set revoked_at=now()
   where community_id=p_community_id and target_user_id=p_target_user_id
     and restriction_type in ('timeout','mute') and revoked_at is null;
   insert into public.community_member_restrictions(
    community_id,target_user_id,restriction_type,reason,expires_at,created_by,moderation_action_id
   ) values(p_community_id,p_target_user_id,p_action_type,btrim(p_reason),v_expires,v_uid,v_action_id)
   returning id into v_restriction_id;
   update public.community_members set muted_until=v_expires
   where community_id=p_community_id and user_id=p_target_user_id;
  elsif p_action_type='restrict_channel' then
   update public.community_member_restrictions set revoked_at=now()
   where community_id=p_community_id and target_user_id=p_target_user_id
     and restriction_type='channel_restriction' and channel_id=p_channel_id and revoked_at is null;
   insert into public.community_member_restrictions(
    community_id,target_user_id,restriction_type,channel_id,reason,expires_at,created_by,moderation_action_id
   ) values(p_community_id,p_target_user_id,'channel_restriction',p_channel_id,btrim(p_reason),v_expires,v_uid,v_action_id)
   returning id into v_restriction_id;
  elsif p_action_type='ban' then
   insert into public.community_member_restrictions(
    community_id,target_user_id,restriction_type,reason,expires_at,created_by,moderation_action_id
   ) values(p_community_id,p_target_user_id,'ban',btrim(p_reason),v_expires,v_uid,v_action_id)
   returning id into v_restriction_id;
   delete from public.community_members where community_id=p_community_id and user_id=p_target_user_id;
  end if;
 elsif p_action_type='kick' then
  delete from public.community_members where community_id=p_community_id and user_id=p_target_user_id;
 elsif p_action_type='unban' then
  update public.community_member_restrictions set revoked_at=now()
  where community_id=p_community_id and target_user_id=p_target_user_id
    and restriction_type='ban' and revoked_at is null;
  update public.community_moderation_actions set status='reversed',reversed_by=v_uid,reversed_at=now()
  where community_id=p_community_id and target_user_id=p_target_user_id
    and action_type='ban' and status='applied';
 end if;

 insert into public.audit_logs(actor_id,community_id,entity_type,entity_id,action,reason,metadata)
 values(v_uid,p_community_id,'moderation_action',v_action_id,'moderation.'||p_action_type,btrim(p_reason),
  jsonb_build_object('target_user_id',p_target_user_id,'channel_id',p_channel_id,
   'message_id',p_message_id,'duration_minutes',p_duration_minutes,'restriction_id',v_restriction_id));
 return v_action_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.join_community_with_invite(p_community_id uuid, p_token_hash text DEFAULT NULL::text, p_applicant_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select app_private.join_community_with_invite(p_community_id,p_token_hash,p_applicant_note); $function$;


CREATE OR REPLACE FUNCTION public.review_community_join_request(p_request_id uuid, p_decision text, p_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid:=(select auth.uid()); v_request public.community_join_requests%rowtype;
begin
 if v_uid is null then raise exception using errcode='28000',message='Authentication required.'; end if;
 if p_decision not in ('approve','reject') then raise exception using errcode='22023',message='Decision must be approve or reject.'; end if;
 if char_length(coalesce(p_reason,''))>1000 then raise exception using errcode='22023',message='Review reason is too long.'; end if;
 select * into v_request from public.community_join_requests where id=p_request_id for update;
 if not found then raise exception using errcode='P0002',message='Join request not found.'; end if;
 if not app_private.resolve_permission('community.manage_members','community',v_request.community_id,null,null)
 then raise exception using errcode='42501',message='You cannot review join requests in this community.'; end if;
 if v_request.status<>'pending' then raise exception using errcode='22023',message='This join request has already been reviewed.'; end if;
 if p_decision='approve' then
  if exists(select 1 from public.community_member_restrictions r
    where r.community_id=v_request.community_id and r.target_user_id=v_request.user_id
      and r.restriction_type='ban' and r.revoked_at is null and (r.expires_at is null or r.expires_at>now()))
  then raise exception using errcode='42501',message='A banned member cannot be approved.'; end if;
  insert into public.community_members(community_id,user_id,role)
  values(v_request.community_id,v_request.user_id,'member') on conflict(community_id,user_id) do nothing;
 end if;
 update public.community_join_requests
 set status=case when p_decision='approve' then 'approved' else 'rejected' end,
  reviewer_id=v_uid,review_reason=btrim(coalesce(p_reason,'')),reviewed_at=now(),updated_at=now()
 where id=p_request_id;
 insert into public.audit_logs(actor_id,community_id,entity_type,entity_id,action,reason)
 values(v_uid,v_request.community_id,'community_join_request',p_request_id,
  case when p_decision='approve' then 'community.join_request.approved' else 'community.join_request.rejected' end,
  nullif(btrim(coalesce(p_reason,'')),''));
 return jsonb_build_object('status',case when p_decision='approve' then 'approved' else 'rejected' end);
end;
$function$;


CREATE OR REPLACE FUNCTION public.review_community_moderation_appeal(p_appeal_id uuid, p_decision text, p_response text, p_new_duration_minutes integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid:=(select auth.uid()); v_appeal public.community_moderation_appeals%rowtype;
 v_action public.community_moderation_actions%rowtype;
begin
 if v_uid is null then raise exception using errcode='28000',message='Authentication required.'; end if;
 if p_decision not in ('uphold','modify','revoke','dismiss')
 then raise exception using errcode='22023',message='Unsupported appeal decision.'; end if;
 if char_length(btrim(coalesce(p_response,'')))<8 or char_length(p_response)>2000
 then raise exception using errcode='22023',message='A review response of 8–2000 characters is required.'; end if;
 if p_new_duration_minutes is not null and p_new_duration_minutes not between 1 and 10080
 then raise exception using errcode='22023',message='New duration must be between 1 minute and 7 days.'; end if;
 select * into v_appeal from public.community_moderation_appeals where id=p_appeal_id for update;
 if not found then raise exception using errcode='P0002',message='Appeal not found.'; end if;
 if not app_private.resolve_permission('community.manage_members','community',v_appeal.community_id,null,null)
 then raise exception using errcode='42501',message='You cannot review appeals in this community.'; end if;
 if v_appeal.status not in ('pending','reviewing')
 then raise exception using errcode='22023',message='This appeal has already been decided.'; end if;
 select * into v_action from public.community_moderation_actions where id=v_appeal.moderation_action_id for update;
 if p_decision='revoke' then
  update public.community_moderation_actions set status='reversed',reversed_by=v_uid,reversed_at=now() where id=v_action.id;
  update public.community_member_restrictions set revoked_at=now()
  where moderation_action_id=v_action.id and revoked_at is null;
  if v_action.action_type in ('ban','kick') and not exists(
   select 1 from public.community_member_restrictions r
   where r.community_id=v_appeal.community_id and r.target_user_id=v_appeal.appellant_id
    and r.restriction_type='ban' and r.revoked_at is null and (r.expires_at is null or r.expires_at>now())
  ) then
   insert into public.community_members(community_id,user_id,role)
   values(v_appeal.community_id,v_appeal.appellant_id,'member') on conflict do nothing;
  end if;
  update public.community_members set muted_until=null
  where community_id=v_appeal.community_id and user_id=v_appeal.appellant_id;
 elsif p_decision='modify' then
  if p_new_duration_minutes is null then raise exception using errcode='22023',message='Modified appeals require a new duration.'; end if;
  update public.community_member_restrictions
  set expires_at=now()+make_interval(mins=>p_new_duration_minutes)
  where moderation_action_id=v_action.id and revoked_at is null;
  update public.community_members
  set muted_until=now()+make_interval(mins=>p_new_duration_minutes)
  where community_id=v_appeal.community_id and user_id=v_appeal.appellant_id
   and exists(select 1 from public.community_member_restrictions r
    where r.moderation_action_id=v_action.id and r.restriction_type in ('timeout','mute') and r.revoked_at is null);
 end if;
 update public.community_moderation_appeals
 set status=case p_decision when 'uphold' then 'upheld' when 'modify' then 'modified'
   when 'revoke' then 'revoked' else 'dismissed' end,
   reviewer_id=v_uid,reviewer_response=btrim(p_response),reviewed_at=now(),updated_at=now()
 where id=p_appeal_id;
 insert into public.audit_logs(actor_id,community_id,entity_type,entity_id,action,reason,metadata)
 values(v_uid,v_appeal.community_id,'moderation_appeal',p_appeal_id,'moderation.appeal.'||p_decision,
  btrim(p_response),jsonb_build_object('moderation_action_id',v_action.id,'new_duration_minutes',p_new_duration_minutes));
 return jsonb_build_object('status',p_decision);
end;
$function$;


CREATE OR REPLACE FUNCTION public.revoke_community_invite(p_invite_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid:=(select auth.uid()); v_community_id uuid;
begin
 if v_uid is null then raise exception using errcode='28000',message='Authentication required.'; end if;
 select community_id into v_community_id from public.community_invites where id=p_invite_id for update;
 if not found then raise exception using errcode='P0002',message='Invite not found.'; end if;
 if not app_private.resolve_permission('community.manage_invites','community',v_community_id,null,null)
 then raise exception using errcode='42501',message='You cannot revoke invites in this community.'; end if;
 update public.community_invites set revoked_at=coalesce(revoked_at,now()) where id=p_invite_id;
 insert into public.audit_logs(actor_id,community_id,entity_type,entity_id,action)
 values(v_uid,v_community_id,'community_invite',p_invite_id,'community.invite.revoked');
 return jsonb_build_object('revoked',true,'invite_id',p_invite_id);
end;
$function$;


CREATE OR REPLACE FUNCTION public.save_community_safety_settings(p_community_id uuid, p_message_burst_limit integer, p_message_window_seconds integer, p_mention_burst_limit integer, p_mention_window_seconds integer, p_restrict_links_for_new_members boolean, p_new_member_link_restriction_hours integer, p_pause_invites_during_lockdown boolean, p_raid_join_threshold integer, p_raid_window_seconds integer, p_lockdown_minutes integer DEFAULT 0, p_lockdown_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid:=(select auth.uid()); v_until timestamptz;
begin
 if v_uid is null then raise exception using errcode='28000',message='Authentication required.'; end if;
 if not app_private.resolve_permission('community.manage_settings','community',p_community_id,null,null)
 then raise exception using errcode='42501',message='You cannot change community safety settings.'; end if;
 if p_message_burst_limit not between 1 and 60 or p_message_window_seconds not between 5 and 300
 or p_mention_burst_limit not between 1 and 30 or p_mention_window_seconds not between 10 and 900
 or p_new_member_link_restriction_hours not between 1 and 720
 or p_raid_join_threshold not between 3 and 100 or p_raid_window_seconds not between 10 and 600
 or p_lockdown_minutes not between 0 and 1440 or char_length(coalesce(p_lockdown_reason,''))>500
 then raise exception using errcode='22023',message='Safety policy values are outside supported limits.'; end if;
 v_until:=case when p_lockdown_minutes=0 then null else now()+make_interval(mins=>p_lockdown_minutes) end;
 insert into public.community_safety_settings(
  community_id,message_burst_limit,message_window_seconds,mention_burst_limit,mention_window_seconds,
  restrict_links_for_new_members,new_member_link_restriction_hours,pause_invites_during_lockdown,
  raid_join_threshold,raid_window_seconds,lockdown_until,lockdown_reason,updated_by,updated_at
 ) values(
  p_community_id,p_message_burst_limit,p_message_window_seconds,p_mention_burst_limit,p_mention_window_seconds,
  p_restrict_links_for_new_members,p_new_member_link_restriction_hours,p_pause_invites_during_lockdown,
  p_raid_join_threshold,p_raid_window_seconds,v_until,
  case when p_lockdown_minutes=0 then '' else btrim(coalesce(p_lockdown_reason,'')) end,v_uid,now()
 )
 on conflict(community_id) do update set
  message_burst_limit=excluded.message_burst_limit,message_window_seconds=excluded.message_window_seconds,
  mention_burst_limit=excluded.mention_burst_limit,mention_window_seconds=excluded.mention_window_seconds,
  restrict_links_for_new_members=excluded.restrict_links_for_new_members,
  new_member_link_restriction_hours=excluded.new_member_link_restriction_hours,
  pause_invites_during_lockdown=excluded.pause_invites_during_lockdown,
  raid_join_threshold=excluded.raid_join_threshold,raid_window_seconds=excluded.raid_window_seconds,
  lockdown_until=excluded.lockdown_until,lockdown_reason=excluded.lockdown_reason,
  updated_by=v_uid,updated_at=now();
 insert into public.audit_logs(actor_id,community_id,entity_type,action,metadata)
 values(v_uid,p_community_id,'community_safety_settings','community.safety_settings.updated',
  jsonb_build_object('message_burst_limit',p_message_burst_limit,'mention_burst_limit',p_mention_burst_limit,
   'lockdown_until',v_until));
 return jsonb_build_object('saved',true,'lockdown_until',v_until);
end;
$function$;


CREATE OR REPLACE FUNCTION public.submit_community_moderation_appeal(p_moderation_action_id uuid, p_reason text, p_details text, p_evidence_reference text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid:=(select auth.uid()); v_action public.community_moderation_actions%rowtype; v_appeal uuid;
begin
 if v_uid is null then raise exception using errcode='28000',message='Authentication required.'; end if;
 select * into v_action from public.community_moderation_actions
 where id=p_moderation_action_id and target_user_id=v_uid and status='applied';
 if not found then raise exception using errcode='42501',message='You can appeal only an active moderation decision applied to your account.'; end if;
 if char_length(btrim(coalesce(p_reason,'')))<3 or char_length(p_reason)>120
   or char_length(btrim(coalesce(p_details,'')))<10 or char_length(p_details)>3000
   or char_length(coalesce(p_evidence_reference,''))>1000
 then raise exception using errcode='22023',message='Appeal details are invalid.'; end if;
 insert into public.community_moderation_appeals(
  community_id,moderation_action_id,appellant_id,reason,details,evidence_reference
 ) values(v_action.community_id,v_action.id,v_uid,btrim(p_reason),btrim(p_details),btrim(coalesce(p_evidence_reference,'')))
 returning id into v_appeal;
 insert into public.audit_logs(actor_id,community_id,entity_type,entity_id,action,metadata)
 values(v_uid,v_action.community_id,'moderation_appeal',v_appeal,'moderation.appeal.submitted',
  jsonb_build_object('moderation_action_id',v_action.id));
 return v_appeal;
end;
$function$;


CREATE OR REPLACE FUNCTION public.submit_community_moderation_report(p_community_id uuid, p_target_user_id uuid DEFAULT NULL::uuid, p_message_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT 'Other'::text, p_details text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid:=(select auth.uid()); v_report_id uuid; v_target uuid:=p_target_user_id;
begin
 if v_uid is null then raise exception using errcode='28000',message='Authentication required.'; end if;
 if not app_private.is_community_member(p_community_id) then raise exception using errcode='42501',message='You must be an active community member to submit a report.'; end if;
 if p_reason not in ('Harassment or abuse','Spam or scam','Impersonation','Cheating or unfair play','Unsafe content','Other')
 then raise exception using errcode='22023',message='Unsupported report reason.'; end if;
 if char_length(coalesce(p_details,''))<8 or char_length(p_details)>1000
 then raise exception using errcode='22023',message='Report details must contain 8–1000 characters.'; end if;
 if p_target_user_id is null and p_message_id is null
 then raise exception using errcode='22023',message='A report needs a target member or message.'; end if;
 if p_target_user_id is not null and not exists(select 1 from public.community_members cm
   where cm.community_id=p_community_id and cm.user_id=p_target_user_id)
 then raise exception using errcode='22023',message='The reported member is not part of this community.'; end if;
 if p_message_id is not null then
  select m.sender_id into v_target from public.messages m
  join public.channels c on c.id=m.channel_id
  where m.id=p_message_id and c.community_id=p_community_id;
  if not found then raise exception using errcode='22023',message='The message does not belong to this community.'; end if;
 end if;
 insert into public.moderation_reports(reporter_id,target_user_id,message_id,community_id,reason,details,status)
 values(v_uid,v_target,p_message_id,p_community_id,p_reason,btrim(p_details),'open') returning id into v_report_id;
 insert into public.audit_logs(actor_id,community_id,entity_type,entity_id,action,metadata)
 values(v_uid,p_community_id,'moderation_report',v_report_id,'moderation.report.submitted',
  jsonb_build_object('reason',p_reason,'has_message',p_message_id is not null));
 return v_report_id;
end;
$function$;


CREATE OR REPLACE FUNCTION public.update_community_join_policy(p_community_id uuid, p_require_approval boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_uid uuid:=(select auth.uid());
begin
 if v_uid is null then raise exception using errcode='28000',message='Authentication required.'; end if;
 if not app_private.resolve_permission('community.manage_invites','community',p_community_id,null,null)
 then raise exception using errcode='42501',message='You cannot manage join policy in this community.'; end if;
 update public.communities set join_approval_required=p_require_approval,updated_at=now() where id=p_community_id;
 if not found then raise exception using errcode='P0002',message='Community not found.'; end if;
 insert into public.audit_logs(actor_id,community_id,entity_type,action,metadata)
 values(v_uid,p_community_id,'community','community.join_policy.updated',
  jsonb_build_object('join_approval_required',p_require_approval));
 return jsonb_build_object('saved',true,'join_approval_required',p_require_approval);
end;
$function$;


revoke all on function app_private.is_community_member(uuid) from public,anon;
grant execute on function app_private.is_community_member(uuid) to authenticated;
revoke all on function app_private.resolve_permission(text,text,uuid,uuid,uuid) from public,anon;
grant execute on function app_private.resolve_permission(text,text,uuid,uuid,uuid) to authenticated;
revoke all on function app_private.join_community_with_invite(uuid,text,text) from public,anon,authenticated;
revoke all on function app_private.guard_batch4_member_restrictions() from public,anon,authenticated;
revoke all on function app_private.detect_community_join_raid() from public,anon,authenticated;
revoke all on function app_private.consume_community_invite(uuid,text) from public,anon,authenticated;

revoke all on function public.join_community_with_invite(uuid,text,text) from public,anon;
grant execute on function public.join_community_with_invite(uuid,text,text) to authenticated;
revoke all on function public.revoke_community_invite(uuid) from public,anon;
grant execute on function public.revoke_community_invite(uuid) to authenticated;
revoke all on function public.update_community_join_policy(uuid,boolean) from public,anon;
grant execute on function public.update_community_join_policy(uuid,boolean) to authenticated;
revoke all on function public.review_community_join_request(uuid,text,text) from public,anon;
grant execute on function public.review_community_join_request(uuid,text,text) to authenticated;
revoke all on function public.submit_community_moderation_report(uuid,uuid,uuid,text,text) from public,anon;
grant execute on function public.submit_community_moderation_report(uuid,uuid,uuid,text,text) to authenticated;
revoke all on function public.apply_community_moderation_action(uuid,text,uuid,text,integer,uuid,uuid) from public,anon;
grant execute on function public.apply_community_moderation_action(uuid,text,uuid,text,integer,uuid,uuid) to authenticated;
revoke all on function public.submit_community_moderation_appeal(uuid,text,text,text) from public,anon;
grant execute on function public.submit_community_moderation_appeal(uuid,text,text,text) to authenticated;
revoke all on function public.review_community_moderation_appeal(uuid,text,text,integer) from public,anon;
grant execute on function public.review_community_moderation_appeal(uuid,text,text,integer) to authenticated;
revoke all on function public.save_community_safety_settings(uuid,integer,integer,integer,integer,boolean,integer,boolean,integer,integer,integer,text) from public,anon;
grant execute on function public.save_community_safety_settings(uuid,integer,integer,integer,integer,boolean,integer,boolean,integer,integer,integer,text) to authenticated;

drop trigger if exists messages_batch4_member_restrictions on public.messages;
create trigger messages_batch4_member_restrictions before insert on public.messages
for each row execute function app_private.guard_batch4_member_restrictions();
drop trigger if exists community_members_batch4_raid_detection on public.community_members;
create trigger community_members_batch4_raid_detection after insert on public.community_members
for each row execute function app_private.detect_community_join_raid();
