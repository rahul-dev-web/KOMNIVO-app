-- Community branding logos are stored separately from member-only message media.
-- This bucket remains private; RLS allows reads only for public communities or their members.
begin;

insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
) values (
  'community-logos',
  'community-logos',
  false,
  2097152,
  array['image/jpeg','image/png','image/webp']::text[]
)
on conflict (id) do update
set
  name = excluded.name,
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists community_logos_read_visible on storage.objects;
create policy community_logos_read_visible
on storage.objects
for select
to authenticated
using (
  bucket_id = 'community-logos'
  and exists (
    select 1
    from public.communities c
    where c.id::text = (storage.foldername(name))[1]
      and (
        c.visibility = 'public'
        or c.owner_user_id = (select auth.uid())
        or exists (
          select 1
          from public.community_members cm
          where cm.community_id = c.id
            and cm.user_id = (select auth.uid())
        )
      )
  )
);

drop policy if exists community_logos_insert_manager on storage.objects;
create policy community_logos_insert_manager
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'community-logos'
  and exists (
    select 1
    from public.communities c
    where c.id::text = (storage.foldername(name))[1]
      and (
        c.owner_user_id = (select auth.uid())
        or exists (
          select 1
          from public.community_members cm
          where cm.community_id = c.id
            and cm.user_id = (select auth.uid())
            and cm.role in ('owner','admin','organiser')
        )
      )
  )
);

drop policy if exists community_logos_update_manager on storage.objects;
create policy community_logos_update_manager
on storage.objects
for update
to authenticated
using (
  bucket_id = 'community-logos'
  and exists (
    select 1
    from public.communities c
    where c.id::text = (storage.foldername(name))[1]
      and (
        c.owner_user_id = (select auth.uid())
        or exists (
          select 1
          from public.community_members cm
          where cm.community_id = c.id
            and cm.user_id = (select auth.uid())
            and cm.role in ('owner','admin','organiser')
        )
      )
  )
)
with check (
  bucket_id = 'community-logos'
  and exists (
    select 1
    from public.communities c
    where c.id::text = (storage.foldername(name))[1]
      and (
        c.owner_user_id = (select auth.uid())
        or exists (
          select 1
          from public.community_members cm
          where cm.community_id = c.id
            and cm.user_id = (select auth.uid())
            and cm.role in ('owner','admin','organiser')
        )
      )
  )
);

drop policy if exists community_logos_delete_manager on storage.objects;
create policy community_logos_delete_manager
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'community-logos'
  and exists (
    select 1
    from public.communities c
    where c.id::text = (storage.foldername(name))[1]
      and (
        c.owner_user_id = (select auth.uid())
        or exists (
          select 1
          from public.community_members cm
          where cm.community_id = c.id
            and cm.user_id = (select auth.uid())
            and cm.role in ('owner','admin','organiser')
        )
      )
  )
);

comment on table storage.buckets is 'Supabase Storage bucket registry.';
commit;
