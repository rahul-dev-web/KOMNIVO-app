-- Qualify the Storage object column to avoid resolving "name" to communities.name.
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
    where c.id::text = (storage.foldername(storage.objects.name))[2]
      and c.icon_url = storage.objects.name
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
  'Only the logo path currently stored in communities.icon_url can be signed. Public communities and their members can read it; unrelated files in community-media do not gain access.';
commit;
