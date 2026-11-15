-- Atomic daily AI request reservation. The counter is private and writable only
-- through a service-role-only RPC to prevent concurrency races and client tampering.

create table if not exists app_private.ai_daily_usage (
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  usage_date date not null,
  request_count integer not null default 0 check (request_count >= 0),
  updated_at timestamptz not null default now(),
  primary key (owner_user_id, usage_date)
);

revoke all on app_private.ai_daily_usage from public, anon, authenticated, service_role;

create or replace function public.reserve_ai_request(
  p_user_id uuid,
  p_daily_limit integer
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_limit integer := greatest(1, least(coalesce(p_daily_limit, 25), 100));
begin
  if (select auth.role()) <> 'service_role' then
    raise exception 'service role required' using errcode = '42501';
  end if;
  if p_user_id is null then
    raise exception 'user id required' using errcode = '22023';
  end if;
  insert into app_private.ai_daily_usage (owner_user_id, usage_date, request_count)
  values (p_user_id, (now() at time zone 'UTC')::date, 1)
  on conflict (owner_user_id, usage_date)
  do update
    set request_count = app_private.ai_daily_usage.request_count + 1,
        updated_at = now()
    where app_private.ai_daily_usage.request_count < v_limit;
  return found;
end;
$function$;
revoke all on function public.reserve_ai_request(uuid, integer) from public, anon, authenticated;
grant execute on function public.reserve_ai_request(uuid, integer) to service_role;
comment on function public.reserve_ai_request(uuid, integer) is
  'Atomically reserves one UTC-day AI request for a user. Execute only with service_role.';
