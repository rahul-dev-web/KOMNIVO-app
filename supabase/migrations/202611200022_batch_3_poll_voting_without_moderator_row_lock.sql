-- Batch 3 poll voting: serialize per-voter writes without requiring poll moderation UPDATE rights.
create or replace function public.vote_channel_poll(p_poll_id uuid,p_option_ids uuid[])
returns integer
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_poll public.channel_polls%rowtype;
  v_count integer;
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  -- A voter can only race with their own ballot. Lock that tuple instead of
  -- SELECT FOR UPDATE on channel_polls, which would require moderation UPDATE
  -- permission and incorrectly block ordinary channel members.
  perform pg_advisory_xact_lock(
    hashtextextended(p_poll_id::text || ':' || v_user_id::text, 0)
  );

  select * into v_poll from public.channel_polls where id=p_poll_id;
  if not found then raise exception 'Poll not found'; end if;
  if v_poll.closes_at is not null and v_poll.closes_at <= now() then
    raise exception 'Poll is closed';
  end if;
  if not app_private.can_view_channel_resource(v_poll.channel_id) then
    raise exception 'You cannot view this poll';
  end if;
  if cardinality(p_option_ids) is null or cardinality(p_option_ids)=0 or cardinality(p_option_ids)>20 then
    raise exception 'Choose at least one option';
  end if;
  if not v_poll.allow_multiple and cardinality(p_option_ids)>1 then
    raise exception 'This poll allows one choice only';
  end if;
  if exists (select 1 from unnest(p_option_ids) x group by x having count(*)>1)
    or exists (
      select 1 from unnest(p_option_ids) x
      where not exists (
        select 1 from public.channel_poll_options o
        where o.id=x and o.poll_id=p_poll_id
      )
    ) then raise exception 'Invalid poll options'; end if;

  delete from public.channel_poll_votes
  where poll_id=p_poll_id and user_id=v_user_id;
  insert into public.channel_poll_votes(poll_id,option_id,user_id)
    select p_poll_id,x,v_user_id from unnest(p_option_ids) x;
  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;
revoke all on function public.vote_channel_poll(uuid,uuid[]) from public,anon;
grant execute on function public.vote_channel_poll(uuid,uuid[]) to authenticated;
