-- Invite consumption, private-message integrity and attachment storage.
-- Apply after 202611090005_product_workflows_and_scoring.sql.

create or replace function public.consume_community_invite(
  p_community_id uuid,
  p_token_hash text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_invite public.community_invites%rowtype;
  v_visibility text;
  v_existing boolean;
  v_rows integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select visibility into v_visibility
  from public.communities
  where id = p_community_id;

  if v_visibility is null then raise exception 'Community not found'; end if;
  if v_visibility <> 'private' then raise exception 'Invite codes are only required for private communities'; end if;

  select * into v_invite
  from public.community_invites
  where community_id = p_community_id and token_hash = p_token_hash
  for update;

  if not found then raise exception 'Invite is invalid'; end if;
  if v_invite.expires_at is not null and v_invite.expires_at <= now() then
    raise exception 'Invite has expired';
  end if;
  if v_invite.max_uses is not null and v_invite.uses >= v_invite.max_uses then
    raise exception 'Invite has reached its use limit';
  end if;

  select exists (
    select 1 from public.community_members
    where community_id = p_community_id and user_id = auth.uid()
  ) into v_existing;

  if v_existing then return true; end if;

  insert into public.community_members (community_id, user_id, role)
  values (p_community_id, auth.uid(), 'member')
  on conflict (community_id, user_id) do nothing;

  get diagnostics v_rows = row_count;
  if v_rows = 1 then
    update public.community_invites set uses = uses + 1 where id = v_invite.id;
  end if;

  return true;
end;
$$;
revoke all on function public.consume_community_invite(uuid, text) from public, anon;
grant execute on function public.consume_community_invite(uuid, text) to authenticated;

-- Private conversation reactions must be restricted to conversation members.
drop policy if exists reactions_manage_self on public.message_reactions;
create policy reactions_manage_self on public.message_reactions
for all to authenticated
using (
  user_id = auth.uid()
  and exists (
    select 1 from public.messages m
    where m.id = message_id
      and (
        exists (
          select 1 from public.channels c
          where c.id = m.channel_id
            and c.community_id is not null
            and public.is_community_member(c.community_id)
            and (
              not c.is_private
              or public.can_manage_community(c.community_id)
              or exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = auth.uid())
            )
        )
        or exists (select 1 from public.channel_members cm where cm.channel_id = m.channel_id and cm.user_id = auth.uid())
      )
  )
)
with check (
  user_id = auth.uid()
  and exists (
    select 1 from public.messages m
    where m.id = message_id
      and (
        exists (
          select 1 from public.channels c
          where c.id = m.channel_id
            and c.community_id is not null
            and public.is_community_member(c.community_id)
            and (
              not c.is_private
              or public.can_manage_community(c.community_id)
              or exists (select 1 from public.channel_members cm where cm.channel_id = c.id and cm.user_id = auth.uid())
            )
        )
        or exists (select 1 from public.channel_members cm where cm.channel_id = m.channel_id and cm.user_id = auth.uid())
      )
  )
);

-- Results are visible to every registered match participant for opponent confirmation,
-- not only to the submitting team and organiser.
drop policy if exists results_read_participant_or_staff on public.match_results;
create policy results_read_participant_or_staff on public.match_results
for select to authenticated
using (
  public.is_team_member(team_id)
  or exists (
    select 1 from public.matches m
    where m.id = match_id and public.is_event_staff(m.event_id)
  )
  or exists (
    select 1 from public.match_participants mp
    where mp.match_id = match_id and public.is_team_member(mp.team_id)
  )
);

-- Private attachments live in a separate bucket. The object key starts with user UUID.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'community-media',
  'community-media',
  false,
  10485760,
  array['image/jpeg','image/png','image/webp','application/pdf']
)
on conflict (id) do nothing;

create policy community_media_upload_own on storage.objects
for insert to authenticated
with check (
  bucket_id = 'community-media'
  and (storage.foldername(name))[1] = auth.uid()::text
);

create policy community_media_read_member on storage.objects
for select to authenticated
using (
  bucket_id = 'community-media'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (
      select 1 from public.message_attachments ma
      join public.messages m on m.id = ma.message_id
      where ma.storage_path = name
        and (
          exists (select 1 from public.channels c where c.id = m.channel_id and c.community_id is not null and public.is_community_member(c.community_id))
          or exists (select 1 from public.channel_members cm where cm.channel_id = m.channel_id and cm.user_id = auth.uid())
        )
    )
  )
);

-- Message attachment records must point to the caller's private media folder.
drop policy if exists message_attachments_insert_own_message on public.message_attachments;
create policy message_attachments_insert_own_message on public.message_attachments
for insert to authenticated
with check (
  uploaded_by = auth.uid()
  and split_part(storage_path, '/', 1) = auth.uid()::text
  and exists (select 1 from public.messages m where m.id = message_id and m.sender_id = auth.uid())
);
