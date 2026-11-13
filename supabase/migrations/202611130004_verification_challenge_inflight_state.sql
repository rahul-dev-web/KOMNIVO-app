-- Keep a challenge in an explicit in-flight state while its single provider
-- /info request is running. This prevents code regeneration from racing a
-- request already reserved for a different challenge.

alter table public.game_account_verification_challenges
  drop constraint if exists game_account_verification_challenges_status_check;

alter table public.game_account_verification_challenges
  add constraint game_account_verification_challenges_status_check
  check (status in ('pending', 'verifying', 'verified', 'expired', 'replaced', 'locked'));

create or replace function public.prepare_game_verification_challenge(
  p_game_account_id uuid,
  p_user_id uuid,
  p_challenge_hash text,
  p_expires_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account public.game_accounts%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  if p_challenge_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('error', 'invalid_challenge_hash');
  end if;

  select *
    into v_account
  from public.game_accounts
  where id = p_game_account_id
    and user_id = p_user_id
  for update;

  if not found then
    return jsonb_build_object('error', 'account_not_found');
  end if;

  if v_account.ownership_status = 'verified' then
    return jsonb_build_object('verified', true, 'attempts_remaining', 0);
  end if;

  if exists (
    select 1
    from public.game_account_verification_challenges c
    where c.game_account_id = p_game_account_id
      and c.user_id = p_user_id
      and c.status = 'verifying'
  ) then
    return jsonb_build_object(
      'in_progress', true,
      'verification_attempts', v_account.verification_attempts,
      'attempts_remaining', greatest(0, 3 - v_account.verification_attempts)
    );
  end if;

  if v_account.verification_attempts >= 3 then
    return jsonb_build_object(
      'locked', true,
      'verification_attempts', v_account.verification_attempts,
      'attempts_remaining', 0
    );
  end if;

  update public.game_account_verification_challenges
  set status = case
      when expires_at <= v_now then 'expired'
      else 'replaced'
    end,
    updated_at = v_now
  where game_account_id = p_game_account_id
    and user_id = p_user_id
    and status = 'pending';

  insert into public.game_account_verification_challenges (
    user_id,
    game_account_id,
    challenge_hash,
    status,
    attempts,
    expires_at
  )
  values (
    p_user_id,
    p_game_account_id,
    p_challenge_hash,
    'pending',
    0,
    p_expires_at
  );

  update public.game_accounts
  set ownership_status = 'proof_pending',
      updated_at = v_now
  where id = p_game_account_id
    and user_id = p_user_id;

  return jsonb_build_object(
    'prepared', true,
    'verification_attempts', v_account.verification_attempts,
    'attempts_remaining', greatest(0, 3 - v_account.verification_attempts)
  );
end;
$$;

-- Atomically reserve a specific pending challenge and mark it as verifying.
-- Only one in-flight provider request is allowed for the linked profile.
create or replace function public.reserve_game_verification_attempt(
  p_game_account_id uuid,
  p_user_id uuid,
  p_challenge_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account public.game_accounts%rowtype;
  v_challenge public.game_account_verification_challenges%rowtype;
  v_now timestamptz := clock_timestamp();
  v_attempt integer;
  v_retry integer;
begin
  select *
    into v_account
  from public.game_accounts
  where id = p_game_account_id
    and user_id = p_user_id
  for update;

  if not found then
    return jsonb_build_object('error', 'account_not_found');
  end if;

  if v_account.ownership_status = 'verified' then
    return jsonb_build_object('verified', true, 'attempts_remaining', 0);
  end if;

  select *
    into v_challenge
  from public.game_account_verification_challenges
  where id = p_challenge_id
    and game_account_id = p_game_account_id
    and user_id = p_user_id
  for update;

  if not found then
    return jsonb_build_object('error', 'challenge_not_found');
  end if;

  if v_challenge.status = 'verifying' then
    return jsonb_build_object(
      'in_progress', true,
      'attempt_number', v_account.verification_attempts,
      'attempts_remaining', greatest(0, 3 - v_account.verification_attempts)
    );
  end if;

  if v_challenge.status <> 'pending' then
    return jsonb_build_object('error', 'challenge_not_active');
  end if;

  if v_challenge.expires_at <= v_now then
    update public.game_account_verification_challenges
    set status = 'expired', updated_at = v_now
    where id = p_challenge_id;
    return jsonb_build_object(
      'expired', true,
      'attempts_remaining', greatest(0, 3 - v_account.verification_attempts)
    );
  end if;

  if v_account.verification_attempts >= 3 then
    update public.game_account_verification_challenges
    set status = 'locked', updated_at = v_now
    where id = p_challenge_id;
    return jsonb_build_object(
      'locked', true,
      'attempt_number', v_account.verification_attempts,
      'attempts_remaining', 0
    );
  end if;

  if v_account.verification_last_attempt_at is not null
     and v_now < v_account.verification_last_attempt_at + interval '15 seconds' then
    v_retry := greatest(
      1,
      ceil(extract(epoch from (
        v_account.verification_last_attempt_at + interval '15 seconds' - v_now
      )))::integer
    );
    return jsonb_build_object(
      'throttled', true,
      'retry_after_seconds', v_retry,
      'attempt_number', v_account.verification_attempts,
      'attempts_remaining', 3 - v_account.verification_attempts
    );
  end if;

  v_attempt := v_account.verification_attempts + 1;

  update public.game_accounts
  set verification_attempts = v_attempt,
      verification_last_attempt_at = v_now,
      verification_locked_at = case
        when v_attempt >= 3 then v_now
        else verification_locked_at
      end,
      updated_at = v_now
  where id = p_game_account_id
    and user_id = p_user_id;

  update public.game_account_verification_challenges
  set status = 'verifying',
      attempts = v_attempt,
      last_attempt_at = v_now,
      updated_at = v_now
  where id = p_challenge_id
    and status = 'pending';

  return jsonb_build_object(
    'attempt_number', v_attempt,
    'attempts_remaining', greatest(0, 3 - v_attempt),
    'locked', v_attempt >= 3,
    'reserved', true
  );
end;
$$;

revoke all on function public.reserve_game_verification_attempt(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.reserve_game_verification_attempt(uuid, uuid, uuid)
  to service_role;
