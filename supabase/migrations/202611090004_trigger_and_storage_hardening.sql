-- Trigger hardening: handle DELETE safely and avoid leaking private-channel message previews.
create or replace function app_private.refresh_community_member_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_community_id uuid;
begin
  if TG_OP = 'DELETE' then
    v_community_id := old.community_id;
  else
    v_community_id := new.community_id;
  end if;

  update public.communities
    set member_count = (select count(*) from public.community_members where community_id = v_community_id)
    where id = v_community_id;

  if TG_OP = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;
revoke all on function app_private.refresh_community_member_count() from public, anon, authenticated;

create or replace function app_private.notify_channel_members()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_channel public.channels%rowtype;
begin
  select * into v_channel from public.channels where id = new.channel_id;

  if v_channel.community_id is not null and not v_channel.is_private then
    insert into public.notifications (user_id, title, body, kind, entity_type, entity_id)
    select cm.user_id, 'New message in ' || v_channel.name,
      left(new.body, 180), 'message', 'channel', new.channel_id
    from public.community_members cm
    where cm.community_id = v_channel.community_id and cm.user_id <> new.sender_id;
  else
    insert into public.notifications (user_id, title, body, kind, entity_type, entity_id)
    select cm.user_id, 'New message in ' || v_channel.name,
      left(new.body, 180), 'message', 'channel', new.channel_id
    from public.channel_members cm
    where cm.channel_id = new.channel_id and cm.user_id <> new.sender_id;
  end if;

  return new;
end;
$$;
revoke all on function app_private.notify_channel_members() from public, anon, authenticated;

-- Organisers may review evidence files attached to matches they manage.
drop policy if exists match_evidence_read_authorized on storage.objects;
create policy match_evidence_read_authorized on storage.objects
for select to authenticated
using (
  bucket_id = 'match-evidence'
  and exists (
    select 1
    from public.result_evidence re
    join public.match_results mr on mr.id = re.result_id
    join public.matches m on m.id = mr.match_id
    where re.storage_path = name
      and public.is_event_staff(m.event_id)
  )
);
