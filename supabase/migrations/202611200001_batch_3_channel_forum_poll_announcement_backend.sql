-- Batch 3: persistent channel configuration, forums, polls and scheduled announcements.
-- All writes remain scoped to the owning community and channel permissions.
create table if not exists public.channel_settings (
  channel_id uuid primary key references public.channels(id) on delete cascade,
  community_id uuid not null references public.communities(id) on delete cascade,
  read_only boolean not null default false,
  slow_mode_seconds integer not null default 0 check (slow_mode_seconds between 0 and 21600),
  allow_attachments boolean not null default true,
  allow_links boolean not null default true,
  allow_embeds boolean not null default true,
  allow_everyone_mention boolean not null default false,
  allow_role_mentions boolean not null default true,
  allow_user_mentions boolean not null default true,
  announcement_publishers_only boolean not null default false,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  constraint channel_settings_channel_community_fkey
    foreign key (channel_id, community_id)
    references public.channels(id, community_id) on delete cascade
);
create index if not exists channel_settings_community_idx on public.channel_settings(community_id);

create table if not exists public.channel_category_preferences (
  category_id uuid not null references public.channel_categories(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  is_collapsed boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (category_id, user_id)
);

create table if not exists public.forum_posts (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null references public.channels(id) on delete cascade,
  community_id uuid not null references public.communities(id) on delete cascade,
  author_id uuid not null references public.profiles(id),
  title text not null check (char_length(title) between 3 and 180),
  body text not null check (char_length(body) between 1 and 12000),
  tag text not null default 'General' check (char_length(tag) between 1 and 40),
  status text not null default 'Open' check (status in ('Open','In discussion','Filled','Closed')),
  is_pinned boolean not null default false,
  is_locked boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint forum_posts_channel_community_fkey
    foreign key (channel_id, community_id)
    references public.channels(id, community_id) on delete cascade
);
create index if not exists forum_posts_channel_created_idx on public.forum_posts(channel_id, created_at desc);
create index if not exists forum_posts_channel_status_idx on public.forum_posts(channel_id, status, created_at desc);
create index if not exists forum_posts_search_idx on public.forum_posts using gin (to_tsvector('simple', title || ' ' || body || ' ' || tag));

create table if not exists public.forum_post_replies (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.forum_posts(id) on delete cascade,
  author_id uuid not null references public.profiles(id),
  body text not null check (char_length(body) between 1 and 6000),
  created_at timestamptz not null default now()
);
create index if not exists forum_post_replies_post_created_idx on public.forum_post_replies(post_id, created_at);

create table if not exists public.channel_polls (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null references public.channels(id) on delete cascade,
  community_id uuid not null references public.communities(id) on delete cascade,
  created_by uuid not null references public.profiles(id),
  question text not null check (char_length(question) between 3 and 240),
  allow_multiple boolean not null default false,
  closes_at timestamptz,
  created_at timestamptz not null default now(),
  constraint channel_polls_channel_community_fkey
    foreign key (channel_id, community_id)
    references public.channels(id, community_id) on delete cascade
);
create table if not exists public.channel_poll_options (
  id uuid primary key default gen_random_uuid(),
  poll_id uuid not null references public.channel_polls(id) on delete cascade,
  label text not null check (char_length(label) between 1 and 120),
  position smallint not null check (position between 0 and 19),
  unique (poll_id, position),
  unique (id, poll_id)
);
create table if not exists public.channel_poll_votes (
  poll_id uuid not null references public.channel_polls(id) on delete cascade,
  option_id uuid not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (poll_id, option_id, user_id),
  foreign key (option_id, poll_id)
    references public.channel_poll_options(id, poll_id) on delete cascade
);
create index if not exists channel_poll_votes_user_idx on public.channel_poll_votes(user_id, poll_id);

create table if not exists public.scheduled_channel_announcements (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null references public.channels(id) on delete cascade,
  community_id uuid not null references public.communities(id) on delete cascade,
  created_by uuid not null references public.profiles(id),
  body text not null check (char_length(body) between 1 and 12000),
  publish_at timestamptz not null,
  status text not null default 'scheduled' check (status in ('scheduled','published','cancelled','failed')),
  published_message_id uuid references public.messages(id) on delete set null,
  published_at timestamptz,
  failure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint scheduled_announcements_channel_community_fkey
    foreign key (channel_id, community_id)
    references public.channels(id, community_id) on delete cascade,
  check ((status <> 'published') or (published_message_id is not null and published_at is not null))
);
create index if not exists scheduled_announcements_due_idx
  on public.scheduled_channel_announcements(publish_at) where status='scheduled';

create or replace function app_private.can_manage_channel(p_channel_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists (
    select 1 from public.channels c
    where c.id=p_channel_id and c.community_id is not null
      and app_private.resolve_permission('community.manage_structure','community',c.community_id,null,null)
  );
$function$;
revoke all on function app_private.can_manage_channel(uuid) from public, anon;
grant execute on function app_private.can_manage_channel(uuid) to authenticated;

create or replace function app_private.can_view_channel_resource(p_channel_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists (
    select 1 from public.channels c
    where c.id=p_channel_id and c.community_id is not null
      and app_private.resolve_permission('channel.view','community',c.community_id,null,c.id)
  );
$function$;
revoke all on function app_private.can_view_channel_resource(uuid) from public, anon;
grant execute on function app_private.can_view_channel_resource(uuid) to authenticated;

create or replace function app_private.can_send_channel_message(p_channel_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists (
    select 1 from public.channels c
    where c.id=p_channel_id and c.community_id is not null
      and c.archived_at is null
      and app_private.resolve_permission('channel.send_messages','community',c.community_id,null,c.id)
  ) and not coalesce((select cs.read_only from public.channel_settings cs where cs.channel_id=p_channel_id),false);
$function$;
revoke all on function app_private.can_send_channel_message(uuid) from public, anon;
grant execute on function app_private.can_send_channel_message(uuid) to authenticated;

create or replace function app_private.guard_batch3_channel_message()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_settings public.channel_settings%rowtype;
  v_last_sent timestamptz;
  v_kind text;
begin
  select * into v_settings from public.channel_settings where channel_id=new.channel_id;
  select kind into v_kind from public.channels where id=new.channel_id and archived_at is null;
  if v_kind is null then raise exception 'Channel is unavailable or archived'; end if;
  if v_settings.channel_id is not null and v_settings.read_only
    and not app_private.resolve_permission('channel.manage_messages','community',v_settings.community_id,null,new.channel_id)
  then raise exception 'This channel is read-only'; end if;
  if not app_private.can_send_channel_message(new.channel_id)
    and not app_private.resolve_permission('channel.manage_messages','community',
      (select community_id from public.channels where id=new.channel_id),null,new.channel_id)
  then raise exception 'You cannot send messages in this channel'; end if;
  if v_settings.channel_id is not null and v_settings.slow_mode_seconds > 0
    and not app_private.resolve_permission('channel.manage_messages','community',v_settings.community_id,null,new.channel_id)
  then
    select max(m.created_at) into v_last_sent from public.messages m
    where m.channel_id=new.channel_id and m.sender_id=new.sender_id and m.deleted_at is null;
    if v_last_sent is not null and v_last_sent > now() - make_interval(secs => v_settings.slow_mode_seconds)
    then raise exception 'Slow mode is active. Please wait before sending again'; end if;
  end if;
  return new;
end;
$function$;
revoke all on function app_private.guard_batch3_channel_message() from public, anon, authenticated;
drop trigger if exists messages_batch3_channel_guard on public.messages;
create trigger messages_batch3_channel_guard before insert on public.messages
for each row execute function app_private.guard_batch3_channel_message();

create or replace function public.set_forum_post_status(p_post_id uuid,p_status text,p_locked boolean default null,p_pinned boolean default null)
returns public.forum_posts language plpgsql security invoker set search_path = ''
as $function$
declare v_post public.forum_posts%rowtype;
begin
  if p_status not in ('Open','In discussion','Filled','Closed') then raise exception 'Invalid forum status'; end if;
  select * into v_post from public.forum_posts where id=p_post_id for update;
  if not found then raise exception 'Forum post not found'; end if;
  if not app_private.resolve_permission('channel.manage_messages','community',v_post.community_id,null,v_post.channel_id)
    then raise exception 'You cannot moderate this forum'; end if;
  update public.forum_posts set status=p_status,
    is_locked=coalesce(p_locked,is_locked), is_pinned=coalesce(p_pinned,is_pinned),updated_at=now()
  where id=p_post_id returning * into v_post;
  return v_post;
end;
$function$;
revoke all on function public.set_forum_post_status(uuid,text,boolean,boolean) from public, anon;
grant execute on function public.set_forum_post_status(uuid,text,boolean,boolean) to authenticated;

create or replace function public.vote_channel_poll(p_poll_id uuid,p_option_ids uuid[])
returns integer language plpgsql security invoker set search_path = ''
as $function$
declare v_poll public.channel_polls%rowtype; v_count integer;
begin
  select * into v_poll from public.channel_polls where id=p_poll_id for update;
  if not found then raise exception 'Poll not found'; end if;
  if v_poll.closes_at is not null and v_poll.closes_at <= now() then raise exception 'Poll is closed'; end if;
  if cardinality(p_option_ids) is null or cardinality(p_option_ids)=0 or cardinality(p_option_ids)>20 then raise exception 'Choose at least one option'; end if;
  if not app_private.can_view_channel_resource(v_poll.channel_id) then raise exception 'You cannot view this poll'; end if;
  if not v_poll.allow_multiple and cardinality(p_option_ids)>1 then raise exception 'This poll allows one choice only'; end if;
  if exists (select 1 from unnest(p_option_ids) x group by x having count(*)>1)
    or exists (select 1 from unnest(p_option_ids) x where not exists (
      select 1 from public.channel_poll_options o where o.id=x and o.poll_id=p_poll_id
    )) then raise exception 'Invalid poll options'; end if;
  delete from public.channel_poll_votes where poll_id=p_poll_id and user_id=auth.uid();
  insert into public.channel_poll_votes(poll_id,option_id,user_id)
    select p_poll_id,x,auth.uid() from unnest(p_option_ids) x;
  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;
revoke all on function public.vote_channel_poll(uuid,uuid[]) from public, anon;
grant execute on function public.vote_channel_poll(uuid,uuid[]) to authenticated;

create or replace function public.publish_due_channel_announcements(p_limit integer default 100)
returns integer language plpgsql security definer set search_path = ''
as $function$
declare v_row record; v_message_id uuid; v_count integer := 0;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;
  for v_row in
    select * from public.scheduled_channel_announcements
    where status='scheduled' and publish_at <= now()
    order by publish_at for update skip locked limit greatest(1,least(p_limit,500))
  loop
    begin
      insert into public.messages(channel_id,sender_id,body)
      values(v_row.channel_id,v_row.created_by,v_row.body)
      returning id into v_message_id;
      update public.scheduled_channel_announcements set status='published',
        published_message_id=v_message_id,published_at=now(),updated_at=now(),failure_reason=null
      where id=v_row.id;
      v_count := v_count+1;
    exception when others then
      update public.scheduled_channel_announcements set status='failed',
        failure_reason=left(sqlerrm,500),updated_at=now() where id=v_row.id;
    end;
  end loop;
  return v_count;
end;
$function$;
revoke all on function public.publish_due_channel_announcements(integer) from public, anon, authenticated;
grant execute on function public.publish_due_channel_announcements(integer) to service_role;

create or replace function app_private.set_channel_setting_updated_at()
returns trigger language plpgsql set search_path = ''
as $function$
begin
  new.updated_at=now();
  new.updated_by=auth.uid();
  return new;
end;
$function$;
revoke all on function app_private.set_channel_setting_updated_at() from public, anon, authenticated;
drop trigger if exists channel_settings_updated_at on public.channel_settings;
create trigger channel_settings_updated_at before update on public.channel_settings
for each row execute function app_private.set_channel_setting_updated_at();

create or replace function app_private.touch_forum_post()
returns trigger language plpgsql set search_path = ''
as $function$
begin new.updated_at=now(); return new; end;
$function$;
revoke all on function app_private.touch_forum_post() from public, anon, authenticated;
drop trigger if exists forum_posts_updated_at on public.forum_posts;
create trigger forum_posts_updated_at before update on public.forum_posts
for each row execute function app_private.touch_forum_post();

alter table public.channel_settings enable row level security;
alter table public.channel_category_preferences enable row level security;
alter table public.forum_posts enable row level security;
alter table public.forum_post_replies enable row level security;
alter table public.channel_polls enable row level security;
alter table public.channel_poll_options enable row level security;
alter table public.channel_poll_votes enable row level security;
alter table public.scheduled_channel_announcements enable row level security;

revoke all on public.channel_settings,public.channel_category_preferences,public.forum_posts,
  public.forum_post_replies,public.channel_polls,public.channel_poll_options,
  public.channel_poll_votes,public.scheduled_channel_announcements from public,anon;
grant select,insert,update,delete on public.channel_settings,public.channel_category_preferences,
  public.forum_posts,public.forum_post_replies,public.channel_polls,public.channel_poll_options,
  public.channel_poll_votes,public.scheduled_channel_announcements to authenticated;

create policy channel_settings_read on public.channel_settings for select to authenticated
using (app_private.can_view_channel_resource(channel_id));
create policy channel_settings_manage on public.channel_settings for all to authenticated
using (app_private.can_manage_channel(channel_id)) with check (app_private.can_manage_channel(channel_id));

create policy channel_category_preferences_self on public.channel_category_preferences for all to authenticated
using (user_id=auth.uid() and exists(select 1 from public.channel_categories cc where cc.id=category_id and app_private.is_community_member(cc.community_id)))
with check (user_id=auth.uid() and exists(select 1 from public.channel_categories cc where cc.id=category_id and app_private.is_community_member(cc.community_id)));

create policy forum_posts_read on public.forum_posts for select to authenticated
using (app_private.can_view_channel_resource(channel_id));
create policy forum_posts_create on public.forum_posts for insert to authenticated
with check (author_id=auth.uid() and app_private.can_send_channel_message(channel_id)
  and exists(select 1 from public.channels c where c.id=channel_id and c.kind='forum' and c.community_id=forum_posts.community_id));
create policy forum_posts_author_update on public.forum_posts for update to authenticated
using (author_id=auth.uid() and app_private.can_send_channel_message(channel_id) and not is_locked)
with check (author_id=auth.uid());
create policy forum_posts_moderate on public.forum_posts for update to authenticated
using (app_private.resolve_permission('channel.manage_messages','community',community_id,null,channel_id))
with check (app_private.resolve_permission('channel.manage_messages','community',community_id,null,channel_id));

create policy forum_replies_read on public.forum_post_replies for select to authenticated
using (exists(select 1 from public.forum_posts p where p.id=post_id and app_private.can_view_channel_resource(p.channel_id)));
create policy forum_replies_create on public.forum_post_replies for insert to authenticated
with check (author_id=auth.uid() and exists(select 1 from public.forum_posts p where p.id=post_id and not p.is_locked
  and p.status<>'Closed' and app_private.can_send_channel_message(p.channel_id)));
create policy forum_replies_author_delete on public.forum_post_replies for delete to authenticated
using (author_id=auth.uid() or exists(select 1 from public.forum_posts p where p.id=post_id
  and app_private.resolve_permission('channel.manage_messages','community',p.community_id,null,p.channel_id)));

create policy channel_polls_read on public.channel_polls for select to authenticated
using (app_private.can_view_channel_resource(channel_id));
create policy channel_polls_create on public.channel_polls for insert to authenticated
with check (created_by=auth.uid() and app_private.can_send_channel_message(channel_id));
create policy channel_polls_moderate on public.channel_polls for update to authenticated
using (app_private.resolve_permission('channel.manage_messages','community',community_id,null,channel_id))
with check (app_private.resolve_permission('channel.manage_messages','community',community_id,null,channel_id));

create policy poll_options_read on public.channel_poll_options for select to authenticated
using (exists(select 1 from public.channel_polls p where p.id=poll_id and app_private.can_view_channel_resource(p.channel_id)));
create policy poll_options_create on public.channel_poll_options for insert to authenticated
with check (exists(select 1 from public.channel_polls p where p.id=poll_id and p.created_by=auth.uid() and app_private.can_send_channel_message(p.channel_id)));
create policy poll_options_manage on public.channel_poll_options for delete to authenticated
using (exists(select 1 from public.channel_polls p where p.id=poll_id and (p.created_by=auth.uid() or app_private.resolve_permission('channel.manage_messages','community',p.community_id,null,p.channel_id))));

create policy poll_votes_read on public.channel_poll_votes for select to authenticated
using (user_id=auth.uid() or exists(select 1 from public.channel_polls p where p.id=poll_id and app_private.resolve_permission('channel.manage_messages','community',p.community_id,null,p.channel_id)));
create policy poll_votes_write on public.channel_poll_votes for all to authenticated
using (user_id=auth.uid() and exists(select 1 from public.channel_polls p where p.id=poll_id and app_private.can_view_channel_resource(p.channel_id)))
with check (user_id=auth.uid() and exists(select 1 from public.channel_polls p where p.id=poll_id and app_private.can_view_channel_resource(p.channel_id)));

create policy scheduled_announcements_read on public.scheduled_channel_announcements for select to authenticated
using (app_private.can_view_channel_resource(channel_id) and (created_by=auth.uid() or app_private.resolve_permission('channel.manage_messages','community',community_id,null,channel_id)));
create policy scheduled_announcements_create on public.scheduled_channel_announcements for insert to authenticated
with check (created_by=auth.uid() and app_private.resolve_permission('channel.manage_messages','community',community_id,null,channel_id));
create policy scheduled_announcements_update on public.scheduled_channel_announcements for update to authenticated
using (created_by=auth.uid() or app_private.resolve_permission('channel.manage_messages','community',community_id,null,channel_id))
with check (created_by=auth.uid() or app_private.resolve_permission('channel.manage_messages','community',community_id,null,channel_id));

comment on table public.channel_settings is 'Persistent channel behaviour; database trigger enforces read-only and slow mode on message writes.';
comment on table public.forum_posts is 'Persistent topic-first forum posts, status and moderation state.';
comment on table public.channel_polls is 'Persistent channel polls; votes are submitted atomically through vote_channel_poll.';
comment on table public.scheduled_channel_announcements is 'Scheduled channel posts; service-role worker calls publish_due_channel_announcements.';
