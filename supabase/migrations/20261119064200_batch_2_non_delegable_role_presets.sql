-- Enforce non-delegable Owner preset and protect role archive semantics.
create or replace function app_private.guard_non_assignable_community_preset()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.community_roles cr join public.community_role_presets p on p.preset_key=cr.preset_key
           where cr.id=new.role_id and cr.community_id=new.community_id and not p.assignable) then
   raise exception 'This built-in role preset is not assignable; ownership cannot be delegated';
 end if;
 if exists(select 1 from public.community_roles cr where cr.id=new.role_id and cr.community_id=new.community_id and cr.archived_at is not null) then
   raise exception 'Archived roles cannot be assigned';
 end if;
 return new;
end $$;
drop trigger if exists community_role_preset_assignment_guard on public.community_member_roles;
create trigger community_role_preset_assignment_guard before insert or update on public.community_member_roles
for each row execute function app_private.guard_non_assignable_community_preset();
