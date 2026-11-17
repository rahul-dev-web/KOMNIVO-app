-- Ensure community-media exists and authenticated clients can upload
-- objects into their own user-id folder. Community logos are uploaded as
-- binary objects; communities.icon_url stores only the object path.
begin;

insert into storage.buckets (id, name, public, file_size_limit)
values ('community-media', 'community-media', false, 10485760)
on conflict (id) do nothing;

drop policy if exists community_media_upload_own on storage.objects;
create policy community_media_upload_own
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'community-media'
  and (storage.foldername(storage.objects.name))[1] = (select auth.uid())::text
);

comment on policy community_media_upload_own on storage.objects is
  'Allows authenticated users to upload community-media objects only beneath their own user-id folder. Application-level logo uploads are limited to 2 MB and JPG, PNG or WebP.';

commit;
