-- Batch 3 Forum search: use the existing GIN full-text index under channel RLS.
create or replace function public.search_channel_forum_posts(
  p_channel_id uuid,
  p_query text default null,
  p_status text default null,
  p_tag text default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns setof public.forum_posts
language sql
stable
security invoker
set search_path = ''
as $function$
  select p.*
  from public.forum_posts p
  where p.channel_id=p_channel_id
    and (p_status is null or p.status=p_status)
    and (p_tag is null or p_tag='All tags' or p.tag=p_tag)
    and (
      nullif(btrim(p_query),'') is null
      or to_tsvector('simple',p.title || ' ' || p.body || ' ' || p.tag)
         @@ plainto_tsquery('simple',btrim(p_query))
    )
  order by p.is_pinned desc,p.created_at desc
  limit greatest(1,least(coalesce(p_limit,100),100))
  offset greatest(coalesce(p_offset,0),0);
$function$;
revoke all on function public.search_channel_forum_posts(uuid,text,text,text,integer,integer) from public,anon;
grant execute on function public.search_channel_forum_posts(uuid,text,text,text,integer,integer) to authenticated;
