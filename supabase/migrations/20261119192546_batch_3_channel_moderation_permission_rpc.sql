-- Reuse the same canonical event/community moderation boundary in client UI.
create or replace function public.can_manage_channel_messages(p_channel_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $function$
  select coalesce((
    select case
      when c.event_id is not null then app_private.can_manage_event_channel(c.id)
      when c.community_id is not null then app_private.resolve_permission(
        'channel.manage_messages','community',c.community_id,null,c.id
      )
      else false
    end
    from public.channels c
    where c.id=p_channel_id and c.archived_at is null
  ),false);
$function$;
revoke all on function public.can_manage_channel_messages(uuid) from public,anon;
grant execute on function public.can_manage_channel_messages(uuid) to authenticated;
