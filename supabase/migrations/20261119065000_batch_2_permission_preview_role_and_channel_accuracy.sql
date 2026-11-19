create or replace function public.preview_community_role_permissions(p_community_id uuid,p_role_id uuid default null,p_user_id uuid default null,p_channel_id uuid default null)
returns table(permission_key text,allowed boolean,source text)
language plpgsql stable security definer set search_path='' as $$
declare v_subject uuid:=coalesce(p_user_id,auth.uid()); v_category uuid; v_has_channel_override boolean:=false;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if not app_private.resolve_permission('community.manage_permissions','community',p_community_id,null,null) and v_subject<>auth.uid() then raise exception 'Cannot preview another member'; end if;
 if p_role_id is not null and not exists(select 1 from public.community_roles cr where cr.id=p_role_id and cr.community_id=p_community_id and cr.archived_at is null) then raise exception 'Role not in community or archived'; end if;
 if p_channel_id is not null then
   select c.category_id into v_category from public.channels c where c.id=p_channel_id and c.community_id=p_community_id and c.event_id is null;
   if not found then raise exception 'Channel not in community'; end if;
   if p_role_id is null then raise exception 'A role must be selected for channel override preview'; end if;
   select exists(select 1 from public.channel_permission_overrides o where o.community_id=p_community_id and o.channel_id=p_channel_id and o.role_id=p_role_id) into v_has_channel_override;
 end if;
 return query
 with keys as(select d.permission_key from app_private.permission_definitions d where d.scope_type='community'),
 grants as(
   select rp.permission_key,bool_or(rp.allowed) allow_grant,bool_or(not rp.allowed) deny_grant
   from public.role_permissions rp
   where (p_role_id is not null and rp.role_id=p_role_id)
      or (p_role_id is null and exists(select 1 from public.community_member_roles cmr where cmr.role_id=rp.role_id and cmr.community_id=p_community_id and cmr.user_id=v_subject))
   group by rp.permission_key
 ),
 overrides as(
   select o.permission_key,bool_or(o.effect='allow') allow_override,bool_or(o.effect='deny') deny_override
   from (select cpo.permission_key,cpo.effect from public.channel_permission_overrides cpo
         where p_channel_id is not null and v_has_channel_override and cpo.community_id=p_community_id and cpo.channel_id=p_channel_id and cpo.role_id=p_role_id
         union all
         select cpo.permission_key,cpo.effect from public.category_permission_overrides cpo
         where p_channel_id is not null and not v_has_channel_override and v_category is not null and cpo.community_id=p_community_id and cpo.category_id=v_category and cpo.role_id=p_role_id) o
   group by o.permission_key
 )
 select k.permission_key,
   case when o.deny_override then false when o.allow_override then true when g.deny_grant then false else coalesce(g.allow_grant,false) end,
   case when o.deny_override then 'channel_or_category_deny' when o.allow_override then 'channel_or_category_allow' when g.deny_grant then 'explicit_deny' when g.allow_grant then 'role_grant' else 'not_granted' end
 from keys k left join grants g on g.permission_key=k.permission_key left join overrides o on o.permission_key=k.permission_key
 order by k.permission_key;
end $$;
revoke all on function public.preview_community_role_permissions(uuid,uuid,uuid,uuid) from public,anon;
grant execute on function public.preview_community_role_permissions(uuid,uuid,uuid,uuid) to authenticated;