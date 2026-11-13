-- Explicit fail-closed client policy for the server-only ownership challenge table.
-- The table grants already deny anon/authenticated access; this policy makes the
-- intended RLS boundary explicit and keeps the security linter satisfied.
drop policy if exists game_account_verification_challenges_deny_client_access
  on public.game_account_verification_challenges;

create policy game_account_verification_challenges_deny_client_access
on public.game_account_verification_challenges
for all
to anon, authenticated
using (false)
with check (false);