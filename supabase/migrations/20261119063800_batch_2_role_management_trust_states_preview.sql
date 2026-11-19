-- Batch 2 items 2-8: scoped role lifecycle, presets, trusted states, history and preview.
alter table public.community_roles add column if not exists archived_at timestamptz;
alter table public.community_roles add column if not exists preset_key text;
create unique index if not exists community_roles_active_preset_unique on public.community_roles(community_id,preset_key) where preset_key is not null and archived_at is null;
create index if not exists community_roles_active_lookup on public.community_roles(community_id,position desc) where archived_at is null;

create table if not exists public.community_role_presets(
 preset_key text primary key,display_name text not null,description text not null,colour text not null,position integer not null,
 permissions jsonb not null default '{}'::jsonb,assignable boolean not null default true,created_at timestamptz not null default now(),
 check(preset_key in ('owner','admin','moderator','organiser')),check(jsonb_typeof(permissions)='object'));
insert into public.community_role_presets values
('owner','Owner','Full ownership; bound to community owner and cannot be delegated.','#D4AF37',1000,'{"community.manage_settings":true,"community.manage_structure":true,"community.manage_members":true,"community.manage_invites":true,"community.manage_roles":true,"community.manage_permissions":true,"community.audit.read":true,"channel.view":true,"channel.read_history":true,"channel.send_messages":true,"channel.react":true,"channel.manage_messages":true}',false,now()),
('admin','Admin','Manage community settings and members; cannot edit equal or higher authority.','#E05D44',200,'{"community.manage_settings":true,"community.manage_structure":true,"community.manage_members":true,"community.manage_invites":true,"community.manage_roles":true,"community.manage_permissions":true,"community.audit.read":true,"channel.view":true,"channel.read_history":true,"channel.send_messages":true,"channel.react":true,"channel.manage_messages":true}',true,now()),
('moderator','Moderator','Moderate members and messages without role administration.','#4A90E2',100,'{"community.manage_members":true,"channel.view":true,"channel.read_history":true,"channel.send_messages":true,"channel.react":true,"channel.manage_messages":true}',true,now()),
('organiser','Organiser','Manage community structure and invites without role administration.','#27AE60',90,'{"community.manage_structure":true,"community.manage_invites":true,"channel.view":true,"channel.read_history":true,"channel.send_messages":true,"channel.react":true}',true,now())
on conflict(preset_key) do update set display_name=excluded.display_name,description=excluded.description,colour=excluded.colour,position=excluded.position,permissions=excluded.permissions,assignable=excluded.assignable;

create table if not exists public.event_staff_role_permissions(role_key text not null,permission_key text not null,primary key(role_key,permission_key));
insert into public.event_staff_role_permissions(role_key,permission_key) select x.role_key,x.permission_key from (values
('competition_manager','event.view'),('competition_manager','event.manage'),('competition_manager','event.staff.assign'),('competition_manager','event.matches.operate'),('competition_manager','event.checkin.manage'),('competition_manager','event.matches.manage'),('competition_manager','event.room_credentials.read'),('competition_manager','event.room_credentials.release'),('competition_manager','event.registrations.manage'),('competition_manager','event.roster.lock'),('competition_manager','event.results.review'),('competition_manager','event.disputes.review'),('competition_manager','event.standings.publish'),('competition_manager','event.audit.read'),
('tournament_director','event.view'),('tournament_director','event.manage'),('tournament_director','event.staff.assign'),('tournament_director','event.matches.operate'),('tournament_director','event.checkin.manage'),('tournament_director','event.matches.manage'),('tournament_director','event.room_credentials.read'),('tournament_director','event.room_credentials.release'),('tournament_director','event.registrations.manage'),('tournament_director','event.roster.lock'),('tournament_director','event.results.review'),('tournament_director','event.disputes.review'),('tournament_director','event.standings.publish'),('tournament_director','event.audit.read'),
('match_operator','event.view'),('match_operator','match.operate'),('match_operator','match.credentials.read'),('match_operator','match.credentials.release'),
('referee','event.view'),('referee','match.view'),('referee','match.results.review'),('result_reviewer','event.view'),('result_reviewer','match.view'),('result_reviewer','match.results.review'),('result_reviewer','event.standings.publish'),
('dispute_reviewer','event.view'),('dispute_reviewer','match.view'),('dispute_reviewer','match.disputes.review'),
('support_staff','event.view'),('support_staff','stage.view'),('support_staff','group.view'),('support_staff','match.view'),
('caster','event.view'),('caster','stage.view'),('caster','group.view'),('caster','match.view'),
('streamer','event.view'),('streamer','stage.view'),('streamer','group.view'),('streamer','match.view')) x(role_key,permission_key) on conflict do nothing;

create table if not exists public.community_role_history(id bigint generated always as identity primary key,community_id uuid not null references public.communities(id) on delete cascade,role_id uuid,subject_user_id uuid,actor_user_id uuid,action text not null,before_state jsonb,after_state jsonb,created_at timestamptz not null default now());
create index if not exists community_role_history_scope_idx on public.community_role_history(community_id,created_at desc);
alter table public.community_role_history enable row level security;
drop policy if exists community_role_history_read on public.community_role_history;
create policy community_role_history_read on public.community_role_history for select to authenticated using(app_private.resolve_permission('community.audit.read','community',community_id,null,null));
revoke insert,update,delete,truncate on public.community_role_history from anon,authenticated;

create or replace function app_private.capture_community_role_history() returns trigger language plpgsql security definer set search_path='' as $$
declare v_row jsonb; v_old jsonb; v_new jsonb; v_community uuid; v_role uuid; v_subject uuid;
begin
 v_old:=case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end; v_new:=case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end; v_row:=coalesce(v_new,v_old);
 v_community:=nullif(v_row->>'community_id','')::uuid; v_role:=nullif(v_row->>'role_id','')::uuid; v_subject:=nullif(v_row->>'user_id','')::uuid;
 if tg_table_name='community_roles' then v_role:=nullif(v_row->>'id','')::uuid; end if;
 if tg_table_name='role_permissions' then select community_id into v_community from public.community_roles where id=v_role; end if;
 insert into public.community_role_history(community_id,role_id,subject_user_id,actor_user_id,action,before_state,after_state)
 values(v_community,v_role,v_subject,auth.uid(),lower(tg_table_name)||'_'||lower(tg_op),case when v_old is null then null else v_old-'created_at'-'updated_at' end,case when v_new is null then null else v_new-'created_at'-'updated_at' end);
 if tg_op='DELETE' then return old; end if; return new;
end $$;
drop trigger if exists community_role_history_roles on public.community_roles;
create trigger community_role_history_roles after insert or update or delete on public.community_roles for each row execute function app_private.capture_community_role_history();
drop trigger if exists community_role_history_assignments on public.community_member_roles;
create trigger community_role_history_assignments after insert or update or delete on public.community_member_roles for each row execute function app_private.capture_community_role_history();
drop trigger if exists community_role_history_permissions on public.role_permissions;
create trigger community_role_history_permissions after insert or update or delete on public.role_permissions for each row execute function app_private.capture_community_role_history();
create or replace function app_private.reject_role_history_mutation() returns trigger language plpgsql set search_path='' as $$ begin raise exception 'Role history is append-only'; end $$;
drop trigger if exists community_role_history_no_mutation on public.community_role_history;
create trigger community_role_history_no_mutation before update or delete on public.community_role_history for each row execute function app_private.reject_role_history_mutation();

create or replace function public.archive_community_role(p_role_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare v_community uuid; v_position integer;
begin
 select community_id,position into v_community,v_position from public.community_roles where id=p_role_id and archived_at is null and not is_system;
 if not found then raise exception 'Role not found or system role cannot be archived'; end if;
 if not app_private.resolve_permission('community.manage_roles','community',v_community,null,null) then raise exception 'You cannot archive roles in this community'; end if;
 if v_position>=app_private.community_authority_rank(v_community) then raise exception 'You cannot archive a role at or above your hierarchy level'; end if;
 delete from public.community_member_roles where role_id=p_role_id;
 update public.community_roles set archived_at=now(),updated_at=now() where id=p_role_id;
end $$;
revoke all on function public.archive_community_role(uuid) from public,anon; grant execute on function public.archive_community_role(uuid) to authenticated;

insert into public.community_roles(community_id,name,description,colour,position,is_system,created_by,preset_key)
select c.id,p.display_name,p.description,p.colour,p.position,true,c.owner_user_id,p.preset_key from public.communities c cross join public.community_role_presets p on conflict(community_id,name) do nothing;
insert into public.role_permissions(role_id,permission_key,allowed)
select cr.id,k.key,k.value::boolean from public.community_roles cr join public.community_role_presets p on p.preset_key=cr.preset_key cross join lateral jsonb_each_text(p.permissions) k(key,value) where cr.archived_at is null
on conflict(role_id,permission_key) do update set allowed=excluded.allowed;

create or replace function app_private.guard_game_account_trust_state() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is not null and (new.user_id is distinct from old.user_id or new.game_id is distinct from old.game_id or new.ownership_status is distinct from old.ownership_status or new.verification_attempts is distinct from old.verification_attempts or new.verification_locked_at is distinct from old.verification_locked_at or new.verification_last_attempt_at is distinct from old.verification_last_attempt_at) then raise exception 'Game account ownership and verification state can only be changed by the verification workflow'; end if; return new;
end $$;
drop trigger if exists game_accounts_trust_state_guard on public.game_accounts;
create trigger game_accounts_trust_state_guard before update on public.game_accounts for each row execute function app_private.guard_game_account_trust_state();

create or replace view public.my_competition_trust_states with(security_invoker=true) as
select ga.user_id,ga.game_id,ga.id game_account_id,ga.ownership_status,(ga.ownership_status='verified') is_verified_player,er.event_id,er.id registration_id,(er.status in ('approved','checked_in')) is_registered_player,mc.match_id,mc.status match_checkin_status,(mc.status='ready') is_checked_in_player
from public.game_accounts ga left join public.registration_players rp on rp.game_account_id=ga.id and rp.user_id=ga.user_id left join public.event_registrations er on er.id=rp.registration_id left join public.match_checkins mc on mc.user_id=ga.user_id;
grant select on public.my_competition_trust_states to authenticated;

create or replace function public.event_staff_effective_permissions(p_event_id uuid,p_user_id uuid)
returns table(role_key text,scope_type text,stage_id uuid,group_id uuid,match_id uuid,permission_key text) language sql stable security definer set search_path='' as $$
select a.role_key,a.scope_type,a.stage_id,a.group_id,a.match_id,rp.permission_key from public.event_staff_assignments a join public.event_staff_role_permissions rp on rp.role_key=a.role_key where a.event_id=p_event_id and a.user_id=p_user_id and (auth.uid()=p_user_id or app_private.resolve_permission('event.audit.read','event',p_event_id,null,null))
$$;
revoke all on function public.event_staff_effective_permissions(uuid,uuid) from public,anon; grant execute on function public.event_staff_effective_permissions(uuid,uuid) to authenticated;

create or replace function public.preview_community_role_permissions(p_community_id uuid,p_role_id uuid default null,p_user_id uuid default null,p_channel_id uuid default null)
returns table(permission_key text,allowed boolean,source text) language plpgsql stable security definer set search_path='' as $$
declare v_subject uuid:=coalesce(p_user_id,auth.uid());
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if not app_private.resolve_permission('community.manage_permissions','community',p_community_id,null,null) and v_subject<>auth.uid() then raise exception 'Cannot preview another member'; end if;
 if p_role_id is not null and not exists(select 1 from public.community_roles cr where cr.id=p_role_id and cr.community_id=p_community_id and cr.archived_at is null) then raise exception 'Role not in community or archived'; end if;
 if p_channel_id is not null and not exists(select 1 from public.channels c where c.id=p_channel_id and c.community_id=p_community_id and c.event_id is null) then raise exception 'Channel not in community'; end if;
 return query with keys as(select d.permission_key from app_private.permission_definitions d where d.scope_type='community'),
 grants as(select rp.permission_key,bool_or(rp.allowed) allow_grant,bool_or(not rp.allowed) deny_grant from public.role_permissions rp join public.community_member_roles cmr on cmr.role_id=rp.role_id where cmr.community_id=p_community_id and cmr.user_id=v_subject and (p_role_id is null or cmr.role_id=p_role_id) group by rp.permission_key)
 select k.permission_key,case when g.deny_grant then false else coalesce(g.allow_grant,false) end,case when g.deny_grant then 'explicit_deny' when g.allow_grant then 'role_grant' else 'not_granted' end from keys k left join grants g on g.permission_key=k.permission_key order by k.permission_key;
end $$;
revoke all on function public.preview_community_role_permissions(uuid,uuid,uuid,uuid) from public,anon; grant execute on function public.preview_community_role_permissions(uuid,uuid,uuid,uuid) to authenticated;
