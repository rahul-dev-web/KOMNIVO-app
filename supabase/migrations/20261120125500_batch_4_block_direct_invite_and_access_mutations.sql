-- Batch 4: close direct REST mutation paths that bypass invite and moderation audit RPCs.

-- Invite codes may be read only by invite managers; all issuance/revocation goes through audited RPCs.
drop policy if exists community_invites_manager on public.community_invites;
create policy community_invites_read_manager
on public.community_invites
for select to authenticated
using (
  app_private.resolve_permission('community.manage_invites','community',community_id,null,null)
);
revoke insert,update,delete on public.community_invites from anon,authenticated;
grant select on public.community_invites to authenticated;

-- Member removal through the REST table endpoint is only allowed for self-leave.
-- Moderator kicks/bans use the SECURITY DEFINER action RPC and write an audit record.
drop policy if exists community_members_leave_self on public.community_members;
create policy community_members_leave_self
on public.community_members
for delete to authenticated
using (user_id=(select auth.uid()));

create or replace function app_private.guard_community_access_policy_columns()
returns trigger
language plpgsql
security invoker
set search_path=''
as $function$
begin
  if (
    old.visibility is distinct from new.visibility
    or old.join_approval_required is distinct from new.join_approval_required
  ) and current_user not in ('postgres','service_role') then
    raise exception using errcode='42501',
      message='Community visibility and join-approval policy can only be changed through the audited access-policy RPC.';
  end if;
  return new;
end;
$function$;

revoke all on function app_private.guard_community_access_policy_columns() from public,anon,authenticated;

drop trigger if exists communities_batch4_guard_access_policy on public.communities;
create trigger communities_batch4_guard_access_policy
before update of visibility,join_approval_required on public.communities
for each row
execute function app_private.guard_community_access_policy_columns();
