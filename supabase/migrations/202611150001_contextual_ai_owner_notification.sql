-- Context-aware AI foundation and an idempotent owner notification after community creation.
begin;

create unique index if not exists notifications_community_owner_ai_ready_unique
  on public.notifications (user_id, entity_id)
  where kind = 'community_owner_ai_ready'
    and entity_type = 'community';

create or replace function app_private.after_community_owner_ai_ready()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  -- The existing community_owner_and_channels trigger runs first alphabetically.
  -- Fail the community insert rather than silently sending an owner notification
  -- when the owner membership bootstrap did not succeed.
  if not exists (
    select 1
    from public.community_members cm
    where cm.community_id = new.id
      and cm.user_id = new.owner_user_id
      and cm.role = 'owner'
  ) then
    raise exception 'Community owner membership was not created; owner AI notification aborted';
  end if;

  insert into public.notifications (
    user_id,
    title,
    body,
    kind,
    entity_type,
    entity_id
  ) values (
    new.owner_user_id,
    'You are now a Community Owner',
    format(
      'You created %s. Ask KOMNIVO AI can help you set up and manage tournaments in this community. Your Player features remain available.',
      new.name
    ),
    'community_owner_ai_ready',
    'community',
    new.id
  )
  on conflict (user_id, entity_id)
    where kind = 'community_owner_ai_ready'
      and entity_type = 'community'
  do nothing;

  return new;
end;
$function$;

revoke all on function app_private.after_community_owner_ai_ready() from public, anon, authenticated;

drop trigger if exists zz_community_owner_ai_ready on public.communities;
create trigger zz_community_owner_ai_ready
after insert on public.communities
for each row
execute function app_private.after_community_owner_ai_ready();

comment on column public.ai_conversations.mode is
  'Legacy client conversation label (player/organizer), retained for history compatibility only. It is not an authorization source; AI capabilities are derived per request from the authenticated user and selected community/event scope.';

comment on function app_private.after_community_owner_ai_ready() is
  'Creates one idempotent in-app/push notification for the verified owner after the existing community owner membership bootstrap succeeds.';

commit;
