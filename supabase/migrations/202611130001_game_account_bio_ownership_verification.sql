-- Free Fire India ownership verification through an exact profile Bio/Signature challenge.
-- Replaces the previous, never-applied 48-player solo-room Support workflow.
-- A one-time code is stored only as a SHA-256 digest and validated against /info.

do $$
begin
  if exists (
    select 1
    from public.game_accounts
    group by game_id, lower(region), uid
    having count(*) > 1
  ) then
    raise exception 'Duplicate game UID claims exist. Resolve duplicate game_accounts rows before enabling ownership verification.';
  end if;
end;
$$;

create unique index if not exists game_accounts_unique_game_region_uid_idx
  on public.game_accounts (game_id, lower(region), uid);

create table if not exists public.game_account_verification_challenges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  game_account_id uuid not null references public.game_accounts(id) on delete cascade,
  challenge_hash text not null check (challenge_hash ~ '^[0-9a-f]{64}$'),
  status text not null default 'pending'
    check (status in ('pending', 'verified', 'expired', 'replaced', 'locked')),
  attempts integer not null default 0 check (attempts between 0 and 5),
  last_attempt_at timestamptz,
  expires_at timestamptz not null,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists game_account_verification_challenges_user_created_idx
  on public.game_account_verification_challenges (user_id, created_at desc);

create index if not exists game_account_verification_challenges_account_created_idx
  on public.game_account_verification_challenges (game_account_id, created_at desc);

create unique index if not exists game_account_verification_one_pending_challenge_idx
  on public.game_account_verification_challenges (game_account_id)
  where status = 'pending';

alter table public.game_account_verification_challenges enable row level security;

-- Challenge hashes and attempt state are server-only. Mobile/web clients use
-- only the authenticated Edge Function and never read challenge rows directly.
revoke all on public.game_account_verification_challenges from public, anon, authenticated;
grant all on public.game_account_verification_challenges to service_role;

comment on table public.game_account_verification_challenges is
  'Server-only one-time Free Fire Bio/Signature ownership challenges. Stores SHA-256 hashes, never plaintext challenge codes or raw Bio text.';
comment on column public.game_account_verification_challenges.challenge_hash is
  'SHA-256 hex digest of the one-time plain-text code shown once to its owner by the authenticated Edge Function.';
comment on column public.game_account_verification_challenges.expires_at is
  'Challenge lifetime is 30 minutes from code generation.';
