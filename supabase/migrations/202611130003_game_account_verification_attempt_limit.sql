-- Profile-wide Free Fire Bio ownership verification limit.
-- UID preparation and code generation must never contact the Free Fire provider.
-- One Verify action performs one /info request for both profile lookup and Bio match.

alter table public.game_accounts
  add column if not exists verification_attempts integer not null default 0,
  add column if not exists verification_locked_at timestamptz,
  add column if not exists verification_last_attempt_at timestamptz;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.game_accounts'::regclass
      and conname = 'game_accounts_verification_attempts_check'
  ) then
    alter table public.game_accounts
      add constraint game_accounts_verification_attempts_check
      check (verification_attempts between 0 and 3);
  end if;
end;
$$;

-- Carry forward failed attempts made by the earlier five-attempt challenge
-- implementation. Replacing or expiring a code must never reset this counter.
update public.game_accounts ga
set verification_attempts = least(3, greatest(ga.verification_attempts, old_attempts.max_attempts)),
    verification_last_attempt_at = coalesce(
      ga.verification_last_attempt_at,
      old_attempts.last_attempt_at
    ),
    verification_locked_at = case
      when least(3, greatest(ga.verification_attempts, old_attempts.max_attempts)) >= 3
        then coalesce(ga.verification_locked_at, old_attempts.last_attempt_at, now())
      else ga.verification_locked_at
    end
from (
  select
    game_account_id,
    least(3, coalesce(max(attempts), 0))::integer as max_attempts,
    max(last_attempt_at) as last_attempt_at
  from public.game_account_verification_challenges
  group by game_account_id
) old_attempts
where ga.id = old_attempts.game_account_id;

-- Generate/rotate a challenge atomically while locking the linked account row.
-- The code itself is never stored; only its SHA-256 digest is persisted.
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

-- Reserve provider attempts atomically. The row lock prevents parallel Verify
-- clicks from exceeding three /info requests or bypassing the retry interval.
create or replace function public.consume_game_verification_attempt(
  p_game_account_id uuid,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_account public.game_accounts%rowtype;
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

  if v_account.verification_attempts >= 3 then
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

  return jsonb_build_object(
    'attempt_number', v_attempt,
    'attempts_remaining', greatest(0, 3 - v_attempt),
    'locked', v_attempt >= 3
  );
end;
$$;

revoke all on function public.prepare_game_verification_challenge(uuid, uuid, text, timestamptz)
  from public, anon, authenticated;
revoke all on function public.consume_game_verification_attempt(uuid, uuid)
  from public, anon, authenticated;

grant execute on function public.prepare_game_verification_challenge(uuid, uuid, text, timestamptz)
  to service_role;
grant execute on function public.consume_game_verification_attempt(uuid, uuid)
  to service_role;

comment on column public.game_accounts.verification_attempts is
  'Profile-wide count of Free Fire provider /info verification requests. Never reset by challenge regeneration.';
comment on column public.game_accounts.verification_locked_at is
  'Set when the third provider verification request is reserved.';
comment on column public.game_accounts.verification_last_attempt_at is
  'Database-authoritative timestamp used to enforce the 15-second verification retry interval.';
