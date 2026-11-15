-- Limit logo reads to the exact object path set by an authorized community manager.
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
      and c.icon_url = name
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
  'Allows reads only for the current icon_url object belonging to a public community or a community the user belongs to. Uploads continue using the existing user-owned media policy.';
commit;
