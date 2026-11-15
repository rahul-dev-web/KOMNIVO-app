-- Community branding logos reuse the existing private community-media bucket.
-- Existing community_media_upload_own policy requires the uploader's user-id folder.
-- Logo path convention: <uploader-user-id>/<community-id>/<unique-logo-filename>.
begin;

drop policy if exists community_logos_read_visible on storage.objects;
create policy community_logos_read_visible
on storage.objects
for select
to authenticated
using (
  bucket_id = 'community-media'
  and exists (
    select 1
    from public.communities c
    where c.id::text = (storage.foldername(name))[2]
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

comment on policy community_logos_read_visible on storage.objects is
  'Allows authenticated users to read only logos for public communities or communities they belong to. The community-media bucket remains private; uploads remain restricted by community_media_upload_own.';
commit;
