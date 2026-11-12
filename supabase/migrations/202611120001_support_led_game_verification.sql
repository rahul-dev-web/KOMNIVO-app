-- Support-led Free Fire ownership verification.
-- Game profile lookup remains public-data discovery; only platform Support can
-- organise 48-player solo-room batches and record ownership outcomes.
-- Apply after 202611090009_private_rpc_implementations.sql.

create table if not exists app_private.platform_staff (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  staff_role text not null check (staff_role in ('support_agent', 'support_admin')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id)
);
revoke all on app_private.platform_staff from public, anon, authenticated;

create or replace function public.is_platform_support()
returns boolean language sql stable security definer
set search_path = app_private, public, pg_temp
as $$
  select exists (
    select 1 from app_private.platform_staff s
    where s.user_id = auth.uid() and s.is_active
  );
$$;
revoke all on function public.is_platform_support() from public, anon;
grant execute on function public.is_platform_support() to authenticated;

create table if not exists app_private.support_verification_batches (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id),
  region text not null default 'ind',
  capacity integer not null default 48 check (capacity = 48),
  status text not null default 'forming'
    check (status in ('forming', 'ready_for_room', 'scheduled', 'in_progress', 'completed', 'cancelled')),
  created_by uuid not null references public.profiles(id),
  scheduled_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists app_private.support_verification_room_secrets (
  batch_id uuid primary key references app_private.support_verification_batches(id) on delete cascade,
  room_id text not null,
  room_password text not null,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.game_account_verification_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  game_account_id uuid not null references public.game_accounts(id) on delete cascade,
  batch_id uuid references app_private.support_verification_batches(id) on delete set null,
  status text not null default 'pending'
    check (status in ('pending', 'batched', 'scheduled', 'verified', 'rejected', 'cancelled')),
  submitted_at timestamptz not null default now(),
  verified_at timestamptz,
  rejected_at timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists game_verification_requests_user_time_idx
  on public.game_account_verification_requests(user_id, submitted_at desc);
create index if not exists game_verification_requests_status_time_idx
  on public.game_account_verification_requests(status, submitted_at);
create unique index if not exists game_verification_one_open_request_per_account_idx
  on public.game_account_verification_requests(game_account_id)
  where status in ('pending', 'batched', 'scheduled');

create table if not exists app_private.support_verification_batch_members (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references app_private.support_verification_batches(id) on delete cascade,
  request_id uuid not null references public.game_account_verification_requests(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  game_account_id uuid not null references public.game_accounts(id) on delete cascade,
  slot_number integer not null check (slot_number between 1 and 48),
  outcome text not null default 'pending'
    check (outcome in ('pending', 'verified', 'rejected', 'no_show')),
  staff_notes text not null default '',
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (batch_id, slot_number),
  unique (batch_id, game_account_id),
  unique (request_id)
);
revoke all on app_private.support_verification_batches from public, anon, authenticated;
revoke all on app_private.support_verification_room_secrets from public, anon, authenticated;
revoke all on app_private.support_verification_batch_members from public, anon, authenticated;

alter table public.game_account_verification_requests enable row level security;
drop policy if exists game_verification_requests_read_owner_or_support
  on public.game_account_verification_requests;
create policy game_verification_requests_read_owner_or_support
on public.game_account_verification_requests for select to authenticated
using (user_id = auth.uid() or public.is_platform_support());
revoke insert, update, delete on public.game_account_verification_requests from anon, authenticated;
grant select on public.game_account_verification_requests to authenticated;

-- Prevent clients from self-approving game ownership or inserting arbitrary game
-- profile rows. The signed-in Edge Function verifies identity; its service-role
-- writer persists provider data. Ownership state changes only through trusted RPCs.
revoke insert, update, delete on public.game_accounts from authenticated;
grant select on public.game_accounts to authenticated;
revoke insert, update, delete on public.game_profile_snapshots from authenticated;
grant select on public.game_profile_snapshots to authenticated;

-- Stop if legacy records already contain conflicting UID claims.
do $$
begin
  if exists (
    select 1 from public.game_accounts
    group by game_id, lower(region), uid
    having count(*) > 1
  ) then
    raise exception 'Duplicate game UID claims exist. Resolve duplicate game_accounts rows before applying the unique ownership index.';
  end if;
end;
$$;
create unique index if not exists game_accounts_unique_game_region_uid_idx
  on public.game_accounts(game_id, lower(region), uid);

drop trigger if exists set_game_account_verification_requests_updated_at
  on public.game_account_verification_requests;
create trigger set_game_account_verification_requests_updated_at
before update on public.game_account_verification_requests
for each row execute procedure app_private.set_updated_at();

create or replace function public.request_game_account_verification(p_game_account_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, app_private, pg_temp
as $$
declare
  v_account public.game_accounts%rowtype;
  v_request public.game_account_verification_requests%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_account from public.game_accounts
  where id = p_game_account_id and user_id = auth.uid() for update;
  if not found then raise exception 'Game account was not found for this KOMNIVO user'; end if;
  if v_account.sync_status <> 'synced' then
    raise exception 'Fetch the game profile successfully before requesting ownership verification';
  end if;
  if v_account.ownership_status = 'verified' then
    return jsonb_build_object('request_id', null, 'account_id', v_account.id,
      'status', 'verified', 'message', 'This game account is already verified by KOMNIVO Support.');
  end if;

  select * into v_request from public.game_account_verification_requests
  where game_account_id = v_account.id and status in ('pending', 'batched', 'scheduled')
  order by submitted_at desc limit 1;
  if found then
    return jsonb_build_object('request_id', v_request.id, 'account_id', v_account.id,
      'status', v_request.status, 'message', 'Your ownership verification request is already in progress.');
  end if;

  insert into public.game_account_verification_requests(user_id, game_account_id, status)
  values (auth.uid(), v_account.id, 'pending') returning * into v_request;
  update public.game_accounts set ownership_status = 'proof_pending', updated_at = now()
  where id = v_account.id;

  insert into public.notifications(user_id, title, body, kind, entity_type, entity_id)
  values (
    auth.uid(), 'Game account verification pending',
    'Your UID profile was found. KOMNIVO Support will contact you after a 48-player solo verification room batch is ready. Please allow a few working days; timing can vary with batch availability.',
    'verification', 'game_account_verification', v_request.id
  );

  return jsonb_build_object('request_id', v_request.id, 'account_id', v_account.id,
    'status', 'pending',
    'message', 'Verification Pending. The KOMNIVO Support Team will contact you in a few working days after a 48-player solo-room batch is ready.');
end;
$$;

create or replace function public.get_my_game_account_verification()
returns jsonb language plpgsql stable security definer
set search_path = public, app_private, pg_temp
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select jsonb_build_object(
    'request_id', r.id, 'account_id', ga.id, 'uid', ga.uid, 'nickname', ga.nickname,
    'region', ga.region, 'ownership_status', ga.ownership_status, 'status', r.status,
    'submitted_at', r.submitted_at, 'batch_status', b.status, 'scheduled_at', b.scheduled_at,
    'message', case r.status
      when 'pending' then 'Verification Pending. Our Support Team will contact you when 48 unique players are ready for a solo verification room. Please allow a few working days; timing may vary with batch availability.'
      when 'batched' then 'Your place is reserved in a 48-player solo verification batch. Our Support Team is arranging the in-game room and will contact you with the next steps.'
      when 'scheduled' then 'Your solo-room verification is scheduled. Our Support Team will contact you using the contact details available on your KOMNIVO account. Ownership remains pending until the in-game UID check is complete.'
      when 'verified' then 'Your game account ownership has been verified by the KOMNIVO Support Team.'
      when 'rejected' then 'The Support Team could not verify this game account. Please contact KOMNIVO Support for next steps.'
      else 'Your game account verification request is no longer active.'
    end
  ) into v_result
  from public.game_account_verification_requests r
  join public.game_accounts ga on ga.id = r.game_account_id
  left join app_private.support_verification_batches b on b.id = r.batch_id
  where r.user_id = auth.uid()
  order by r.submitted_at desc limit 1;

  if v_result is not null then return v_result; end if;

  select jsonb_build_object(
    'status', 'not_submitted', 'account_id', ga.id, 'uid', ga.uid, 'nickname', ga.nickname,
    'region', ga.region, 'ownership_status', ga.ownership_status,
    'message', 'Your game profile is linked, but ownership verification has not been submitted yet.'
  ) into v_result
  from public.game_accounts ga
  where ga.user_id = auth.uid()
  order by ga.updated_at desc limit 1;

  return coalesce(v_result, jsonb_build_object(
    'status', 'not_submitted',
    'message', 'Enter your game UID to look up your profile and request ownership verification.'
  ));
end;
$$;

create or replace function public.list_support_verification_requests(p_status text default 'pending')
returns jsonb language plpgsql stable security definer
set search_path = public, app_private, auth, pg_temp
as $$
declare v_result jsonb;
begin
  if not public.is_platform_support() then raise exception 'Platform Support access required'; end if;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.submitted_at), '[]'::jsonb)
  into v_result
  from (
    select r.id as request_id, r.status, r.submitted_at, r.batch_id,
      ga.id as game_account_id, ga.uid, ga.nickname, ga.region, ga.provider,
      p.display_name, u.email as contact_email
    from public.game_account_verification_requests r
    join public.game_accounts ga on ga.id = r.game_account_id
    join public.profiles p on p.id = r.user_id
    left join auth.users u on u.id = r.user_id
    where (p_status = 'all' or r.status = p_status)
      and r.status in ('pending', 'batched', 'scheduled')
    order by r.submitted_at limit 250
  ) q;
  return v_result;
end;
$$;

create or replace function public.list_support_verification_batches()
returns jsonb language plpgsql stable security definer
set search_path = public, app_private, pg_temp
as $$
declare v_result jsonb;
begin
  if not public.is_platform_support() then raise exception 'Platform Support access required'; end if;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc), '[]'::jsonb)
  into v_result
  from (
    select b.id as batch_id, b.status, b.region, b.capacity, b.scheduled_at, b.created_at,
      (select count(*)::integer from app_private.support_verification_batch_members m where m.batch_id = b.id) as participant_count,
      s.room_id, s.room_password
    from app_private.support_verification_batches b
    left join app_private.support_verification_room_secrets s on s.batch_id = b.id
    where b.status <> 'cancelled'
    order by b.created_at desc limit 50
  ) q;
  return v_result;
end;
$$;

create or replace function public.create_support_verification_batch()
returns jsonb language plpgsql security definer
set search_path = public, app_private, pg_temp
as $$
declare v_game_id uuid; v_batch app_private.support_verification_batches%rowtype;
begin
  if not public.is_platform_support() then raise exception 'Platform Support access required'; end if;
  select id into v_game_id from public.games where code = 'free_fire_max' and is_active limit 1;
  if v_game_id is null then raise exception 'Free Fire game catalogue entry is missing'; end if;
  insert into app_private.support_verification_batches(game_id, region, capacity, status, created_by)
  values (v_game_id, 'ind', 48, 'forming', auth.uid()) returning * into v_batch;
  return jsonb_build_object('batch_id', v_batch.id, 'status', v_batch.status,
    'capacity', v_batch.capacity, 'participant_count', 0);
end;
$$;

create or replace function public.assign_support_verification_request(p_request_id uuid, p_batch_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, app_private, pg_temp
as $$
declare
  v_request public.game_account_verification_requests%rowtype;
  v_batch app_private.support_verification_batches%rowtype;
  v_game_account public.game_accounts%rowtype;
  v_count integer;
  v_slot integer;
  v_member app_private.support_verification_batch_members%rowtype;
begin
  if not public.is_platform_support() then raise exception 'Platform Support access required'; end if;
  select * into v_request from public.game_account_verification_requests
  where id = p_request_id for update;
  if not found then raise exception 'Verification request not found'; end if;
  if v_request.status <> 'pending' then raise exception 'Only pending requests can be assigned to a batch'; end if;
  select * into v_batch from app_private.support_verification_batches
  where id = p_batch_id for update;
  if not found then raise exception 'Verification batch not found'; end if;
  if v_batch.status <> 'forming' then raise exception 'This batch is no longer accepting players'; end if;
  select * into v_game_account from public.game_accounts where id = v_request.game_account_id;
  if v_game_account.game_id <> v_batch.game_id or lower(v_game_account.region) <> lower(v_batch.region) then
    raise exception 'The player game and region do not match this batch';
  end if;
  select count(*)::integer into v_count from app_private.support_verification_batch_members where batch_id = v_batch.id;
  if v_count >= 48 then raise exception 'All 48 slots in this solo-room batch are filled'; end if;

  select s into v_slot
  from generate_series(1, 48) s
  where not exists (
    select 1 from app_private.support_verification_batch_members m
    where m.batch_id = v_batch.id and m.slot_number = s
  )
  order by s limit 1;

  insert into app_private.support_verification_batch_members(batch_id, request_id, user_id, game_account_id, slot_number)
  values (v_batch.id, v_request.id, v_request.user_id, v_request.game_account_id, v_slot)
  returning * into v_member;
  update public.game_account_verification_requests
  set batch_id = v_batch.id, status = 'batched', updated_at = now()
  where id = v_request.id;

  v_count := v_count + 1;
  if v_count = 48 then
    update app_private.support_verification_batches
    set status = 'ready_for_room', updated_at = now()
    where id = v_batch.id;
  end if;
  return jsonb_build_object('batch_id', v_batch.id, 'member_id', v_member.id,
    'slot_number', v_slot, 'participant_count', v_count, 'capacity', 48,
    'batch_status', case when v_count = 48 then 'ready_for_room' else 'forming' end);
end;
$$;

create or replace function public.schedule_support_verification_batch(
  p_batch_id uuid, p_scheduled_at timestamptz, p_room_id text, p_room_password text
)
returns jsonb language plpgsql security definer
set search_path = public, app_private, pg_temp
as $$
declare v_batch app_private.support_verification_batches%rowtype; v_count integer;
begin
  if not public.is_platform_support() then raise exception 'Platform Support access required'; end if;
  if p_scheduled_at <= now() then raise exception 'Choose a future solo-room date and time'; end if;
  if length(trim(coalesce(p_room_id, ''))) = 0 then raise exception 'Room ID is required'; end if;
  if length(trim(coalesce(p_room_password, ''))) = 0 then raise exception 'Room password is required'; end if;
  select * into v_batch from app_private.support_verification_batches
  where id = p_batch_id for update;
  if not found then raise exception 'Verification batch not found'; end if;
  if v_batch.status <> 'ready_for_room' then raise exception 'A solo room can be scheduled only after all 48 slots are filled'; end if;
  select count(*)::integer into v_count from app_private.support_verification_batch_members where batch_id = p_batch_id;
  if v_count <> 48 then raise exception 'Exactly 48 unique players are required before scheduling the solo room'; end if;

  insert into app_private.support_verification_room_secrets(batch_id, room_id, room_password, created_by)
  values (p_batch_id, trim(p_room_id), trim(p_room_password), auth.uid())
  on conflict (batch_id) do update
    set room_id = excluded.room_id, room_password = excluded.room_password,
        created_by = excluded.created_by, created_at = now();
  update app_private.support_verification_batches
  set status = 'scheduled', scheduled_at = p_scheduled_at, updated_at = now()
  where id = p_batch_id;
  update public.game_account_verification_requests
  set status = 'scheduled', updated_at = now() where batch_id = p_batch_id;

  insert into public.notifications(user_id, title, body, kind, entity_type, entity_id)
  select r.user_id, 'Solo verification room scheduled',
    'The KOMNIVO Support Team has scheduled your 48-player solo verification room. The team will contact you using the contact details available on your KOMNIVO account. Your ownership remains pending until the in-game UID check is completed.',
    'verification', 'game_account_verification', r.id
  from public.game_account_verification_requests r where r.batch_id = p_batch_id;

  return jsonb_build_object('batch_id', p_batch_id, 'status', 'scheduled',
    'scheduled_at', p_scheduled_at, 'participant_count', 48);
end;
$$;

create or replace function public.start_support_verification_batch(p_batch_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, app_private, pg_temp
as $$
begin
  if not public.is_platform_support() then raise exception 'Platform Support access required'; end if;
  update app_private.support_verification_batches
  set status = 'in_progress', started_at = now(), updated_at = now()
  where id = p_batch_id and status = 'scheduled';
  if not found then raise exception 'Only a scheduled support verification batch can be started'; end if;
  return jsonb_build_object('batch_id', p_batch_id, 'status', 'in_progress');
end;
$$;

create or replace function public.list_support_verification_batch_members(p_batch_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, app_private, auth, pg_temp
as $$
declare v_result jsonb;
begin
  if not public.is_platform_support() then raise exception 'Platform Support access required'; end if;
  if not exists (select 1 from app_private.support_verification_batches where id = p_batch_id) then
    raise exception 'Verification batch not found';
  end if;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.slot_number), '[]'::jsonb)
  into v_result
  from (
    select m.id as member_id, m.slot_number, m.outcome, m.staff_notes,
      r.id as request_id, r.status as request_status, m.user_id,
      p.display_name, ga.uid, ga.nickname, ga.region, u.email as contact_email
    from app_private.support_verification_batch_members m
    join public.game_account_verification_requests r on r.id = m.request_id
    join public.game_accounts ga on ga.id = m.game_account_id
    join public.profiles p on p.id = m.user_id
    left join auth.users u on u.id = m.user_id
    where m.batch_id = p_batch_id
  ) q;
  return v_result;
end;
$$;

create or replace function public.record_support_verification_result(
  p_member_id uuid, p_outcome text, p_notes text default ''
)
returns jsonb language plpgsql security definer
set search_path = public, app_private, pg_temp
as $$
declare
  v_member app_private.support_verification_batch_members%rowtype;
  v_batch app_private.support_verification_batches%rowtype;
  v_request public.game_account_verification_requests%rowtype;
  v_message text;
begin
  if not public.is_platform_support() then raise exception 'Platform Support access required'; end if;
  if p_outcome not in ('verified', 'rejected', 'no_show') then
    raise exception 'Outcome must be verified, rejected or no_show';
  end if;
  select * into v_member from app_private.support_verification_batch_members
  where id = p_member_id for update;
  if not found then raise exception 'Batch player slot not found'; end if;
  if v_member.outcome <> 'pending' then raise exception 'This slot has already been reviewed'; end if;
  select * into v_batch from app_private.support_verification_batches
  where id = v_member.batch_id for update;
  if v_batch.status <> 'in_progress' then raise exception 'Start the solo room before reviewing player slots'; end if;
  select * into v_request from public.game_account_verification_requests
  where id = v_member.request_id for update;

  update app_private.support_verification_batch_members
  set outcome = p_outcome, staff_notes = left(coalesce(p_notes, ''), 1000),
      reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_member_id;

  if p_outcome = 'verified' then
    update public.game_account_verification_requests
    set status = 'verified', verified_at = now(), updated_at = now()
    where id = v_request.id;
    update public.game_accounts set ownership_status = 'verified', updated_at = now()
    where id = v_member.game_account_id;
    v_message := 'Your Free Fire game-account ownership has been verified by the KOMNIVO Support Team.';
  elsif p_outcome = 'rejected' then
    update public.game_account_verification_requests
    set status = 'rejected', rejected_at = now(), updated_at = now()
    where id = v_request.id;
    update public.game_accounts set ownership_status = 'rejected', updated_at = now()
    where id = v_member.game_account_id;
    v_message := 'The KOMNIVO Support Team could not verify the game account. Please contact Support for next steps.';
  else
    update public.game_account_verification_requests
    set status = 'pending', batch_id = null, updated_at = now()
    where id = v_request.id;
    v_message := 'Your verification slot was missed. Your request has returned to the pending queue for a future 48-player room.';
  end if;

  insert into public.notifications(user_id, title, body, kind, entity_type, entity_id)
  values (
    v_member.user_id,
    case p_outcome when 'verified' then 'Game account verified'
      when 'rejected' then 'Verification needs support' else 'Verification rescheduled' end,
    v_message, 'verification', 'game_account_verification', v_request.id
  );

  update app_private.support_verification_batches b
  set status = 'completed', completed_at = now(), updated_at = now()
  where b.id = v_batch.id and not exists (
    select 1 from app_private.support_verification_batch_members m
    where m.batch_id = b.id and m.outcome = 'pending'
  );

  insert into public.audit_logs(actor_id, entity_type, entity_id, action, reason, metadata)
  values (auth.uid(), 'game_account_verification', v_request.id, 'support_' || p_outcome,
    left(coalesce(p_notes, ''), 500),
    jsonb_build_object('batch_id', v_batch.id, 'slot_number', v_member.slot_number,
      'game_account_id', v_member.game_account_id));

  return jsonb_build_object('request_id', v_request.id, 'outcome', p_outcome, 'batch_id', v_batch.id);
end;
$$;

revoke all on function public.request_game_account_verification(uuid) from public, anon;
revoke all on function public.get_my_game_account_verification() from public, anon;
revoke all on function public.list_support_verification_requests(text) from public, anon;
revoke all on function public.list_support_verification_batches() from public, anon;
revoke all on function public.create_support_verification_batch() from public, anon;
revoke all on function public.assign_support_verification_request(uuid, uuid) from public, anon;
revoke all on function public.schedule_support_verification_batch(uuid, timestamptz, text, text) from public, anon;
revoke all on function public.start_support_verification_batch(uuid) from public, anon;
revoke all on function public.list_support_verification_batch_members(uuid) from public, anon;
revoke all on function public.record_support_verification_result(uuid, text, text) from public, anon;
grant execute on function public.request_game_account_verification(uuid) to authenticated;
grant execute on function public.get_my_game_account_verification() to authenticated;
grant execute on function public.list_support_verification_requests(text) to authenticated;
grant execute on function public.list_support_verification_batches() to authenticated;
grant execute on function public.create_support_verification_batch() to authenticated;
grant execute on function public.assign_support_verification_request(uuid, uuid) to authenticated;
grant execute on function public.schedule_support_verification_batch(uuid, timestamptz, text, text) to authenticated;
grant execute on function public.start_support_verification_batch(uuid) to authenticated;
grant execute on function public.list_support_verification_batch_members(uuid) to authenticated;
grant execute on function public.record_support_verification_result(uuid, text, text) to authenticated;

-- Bootstrap the initial platform support administrators manually in the Supabase
-- SQL editor after their KOMNIVO users have signed in:
-- insert into app_private.platform_staff (user_id, staff_role)
-- values ('<auth user UUID>', 'support_admin')
-- on conflict (user_id) do update set staff_role = excluded.staff_role, is_active = true;
