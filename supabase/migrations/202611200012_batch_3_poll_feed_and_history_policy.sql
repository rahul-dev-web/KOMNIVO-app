-- Batch 3: privacy-safe poll result feed and channel history controls.
create or replace function public.channel_poll_feed(p_channel_id uuid)
returns table(
  poll_id uuid,
  question text,
  allow_multiple boolean,
  closes_at timestamptz,
  poll_created_at timestamptz,
  option_id uuid,
  option_label text,
  option_position smallint,
  vote_count bigint,
  selected_by_me boolean
)
language sql
stable
security definer
set search_path = ''
as $function$
  select
    p.id,p.question,p.allow_multiple,p.closes_at,p.created_at,
    o.id,o.label,o.position,
    count(v.user_id) as vote_count,
    coalesce(bool_or(v.user_id=(select auth.uid())),false) as selected_by_me
  from public.channel_polls p
  join public.channel_poll_options o on o.poll_id=p.id
  left join public.channel_poll_votes v on v.poll_id=p.id and v.option_id=o.id
  where p.channel_id=p_channel_id
    and app_private.can_view_channel_resource(p.channel_id)
  group by p.id,o.id
  order by p.created_at desc,o.position;
$function$;
revoke all on function public.channel_poll_feed(uuid) from public,anon;
grant execute on function public.channel_poll_feed(uuid) to authenticated;

drop policy if exists messages_read_channel_member on public.messages;
create policy messages_read_channel_member on public.messages
for select to authenticated
using (
  exists (
    select 1
    from public.channels c
    where c.id=messages.channel_id
      and (
        (c.event_id is not null and app_private.can_access_event_channel_scope(
          c.event_id,c.stage_id,c.group_id,c.match_id,c.id
        ))
        or
        (c.event_id is null and c.community_id is not null and app_private.resolve_permission(
          'channel.view','community',c.community_id,null,c.id
        ))
        or
        (c.community_id is null and app_private.is_channel_member(c.id))
      )
      and (
        c.event_id is not null
        or c.community_id is null
        or app_private.resolve_permission('channel.read_history','community',c.community_id,null,c.id)
      )
      and (
        coalesce((select cs.keep_history from public.channel_settings cs where cs.channel_id=c.id),true)
        or messages.created_at >= now() - interval '24 hours'
        or (c.event_id is not null and app_private.can_manage_event_channel(c.id))
        or (c.community_id is not null and app_private.resolve_permission('channel.manage_messages','community',c.community_id,null,c.id))
      )
  )
);
