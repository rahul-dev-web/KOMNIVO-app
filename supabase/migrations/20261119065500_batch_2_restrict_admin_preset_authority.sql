delete from public.role_permissions rp
using public.community_roles cr
where rp.role_id=cr.id and cr.preset_key='admin'
and rp.permission_key in ('community.manage_settings','community.manage_permissions','community.audit.read');
update public.community_role_presets
set description='Manage members, invites, community structure and role assignments. Cannot change owner-only settings, permission grants or audit history.',
    permissions=permissions - 'community.manage_settings' - 'community.manage_permissions' - 'community.audit.read'
where preset_key='admin';