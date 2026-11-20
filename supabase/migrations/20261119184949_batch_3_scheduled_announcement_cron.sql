-- Enable automatic publishing of due channel announcements through pg_cron.
create extension if not exists pg_cron with schema pg_catalog;

create or replace function public.publish_due_channel_announcements(p_limit integer default 100)
returns integer language plpgsql security definer set search_path = ''
as $function$
declare v_row record; v_message_id uuid; v_count integer := 0;
begin
  if current_user <> 'postgres' and coalesce(auth.role(),'') <> 'service_role' then
    raise exception 'Service role required';
  end if;
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
revoke all on function public.publish_due_channel_announcements(integer) from public,anon,authenticated;
grant execute on function public.publish_due_channel_announcements(integer) to service_role;

-- A database-owned cron session runs as postgres; ordinary clients cannot invoke
-- this RPC because execute is revoked from anon/authenticated.
select cron.unschedule(jobid) from cron.job where jobname='komnivo-batch3-announcements';
select cron.schedule(
  'komnivo-batch3-announcements',
  '* * * * *',
  'select public.publish_due_channel_announcements(100);'
);
