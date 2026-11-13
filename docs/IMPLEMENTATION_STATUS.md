# KOMNIVO implementation status

Last verified: 12 November 2026.

This file distinguishes work deployed to the connected Supabase project from owner-controlled external credentials and remaining product engineering.

## Live backend deployment

Connected Supabase project:
- Project: `KOMNIVO-app`
- Ref: `krqysdkbyhshwpfmimfw`
- Region: Singapore (`ap-southeast-1`)
- URL: `https://krqysdkbyhshwpfmimfw.supabase.co`
- Database: PostgreSQL 17.11

Verified on the project:
- 11 migrations applied successfully.
- 43 application tables in `public`; all 43 have RLS enabled.
- Least-privilege grants applied: anonymous users can read only the active `games` catalogue; authenticated access is granted per table and column under RLS. Future `public` tables, sequences and functions created by the postgres migration owner no longer receive broad anon/authenticated default privileges.
- Two private Storage buckets: `community-media` and `match-evidence`, both limited to 10 MB and JPG/PNG/WebP/PDF.
- `public.messages` is enabled in the `supabase_realtime` publication.
- All 13 repository Edge Functions deployed and ACTIVE. User-facing functions have JWT verification enabled; `notification-push` uses its dedicated `x-webhook-secret` check.

## Implemented in source

- Flutter app shell, responsive dark theme, Google sign-in flow and local preview.
- Community discovery/create/join entry points and default channels.
- Direct/group conversation creation, persisted realtime text messages, replies, emoji reactions, secure attachments, local message search and LiveKit voice-room token issuance.
- Notification centre with read states and notification preferences; `notification-push` Edge Function v8 is deployed ACTIVE and sends FCM HTTP v1 directly through a narrowly scoped Google OAuth refresh token. Supabase secrets and the `public.notifications` INSERT webhook are configured. Android push is verified on Vivo Y20G (foreground Snackbar, background system notification and tap navigation); Desktop Web Push is verified on Windows Chrome. UI styling of the foreground Snackbar is deferred to the later UI-polishing pass.
- Player profile and server-side Free Fire UID lookup adapter.
- Free Fire ownership verification now uses a one-time profile Bio/Signature challenge instead of the 48-player solo-room queue. UID lookup fetches the public profile and generates a 128-bit `KOMNIVO-...` code; the player must paste only that code into the full in-game Bio/Signature, tick the confirmation checkbox, and request verification. The server re-fetches `/info`, compares the SHA-256 digest of `socialInfo.signature` against the stored hash, enforces a 30-minute expiry, five attempts and 15-second retry spacing, then marks the game account `verified`. Plaintext codes are returned once and never stored; raw Bio/signature is excluded from stored profile snapshots. Migration and updated Edge Function are committed but not yet applied/deployed to live Supabase.
- UID refresh integrity: the profile sync preserves an existing `ownership_status` (so a previously verified account remains verified) and rejects an in-place UID/region swap. Public profile refresh never changes ownership state; a separate controlled account-relink flow is required for any future UID change.
- Team creation, invitations and membership acceptance.
- Event discovery/publishing, team registration, match schedule, standings, check-in, time-released room credentials, evidence upload, opponent confirmation/dispute and result submission.
- Organiser approval, roster lock, group generation, match operations, dispute review, result approval and scoring/standings backend.
- Supabase schema, RLS, audit records, private buckets and privileged tournament RPC implementations.
- Android MediaProjection bridge and local ML Kit OCR preview; the raw OCR text is not used as an official result.
- Public KOMNIVO product homepage, Privacy Policy and Terms pages are authored under `native/web/` and copied by both platform bootstrap scripts into the Cloudflare Pages output. Initial text needs owner/legal review before public launch.
- GitHub Actions build workflows for Flutter analysis/tests/Android APK/Web and a Web staging artifact workflow.

## Still requires owner-controlled external setup

- Apply `supabase/migrations/202611130001_game_account_bio_ownership_verification.sql` to the connected Supabase project and deploy the updated `sync-freefire-profile` Edge Function. No Platform Support staff bootstrap is required for this ownership-verification path.
- Test UID lookup → one-time code → full Bio replacement → checkbox-gated verify → exact API signature match → Verified notification → Bio restoration. Also test expired/replaced codes, incorrect Bio, provider cache delay, five-attempt lock, duplicate UID claims and preservation of an already-verified account.

- Google Cloud OAuth Web Client ID/Secret and enabling Google provider in Supabase Auth.
- Active Supabase publishable key supplied as local build value and GitHub Actions variable.
- Firebase Android and Web apps are registered. Direct FCM sender credentials, Supabase Edge Function secrets and the notification INSERT webhook are configured. Android test delivery has been observed on the Vivo Y20G. Browser delivery still needs Cloudflare Pages Firebase Web config/VAPID build variables and end-to-end browser QA.
- LiveKit Cloud project URL/API key/API secret if voice rooms are to be tested.
- Free Fire provider API key and confirmation of current terms, quotas and commercial-use permissions.
- Cloudflare Pages deployment of the public homepage/policy pages and Google Search Console domain ownership verification (custom domain may be required; do not assume the shared `pages.dev` hostname will pass Google OAuth verification).
- Android upload-keystore/release signing and Play Console/legal setup.

See [EXTERNAL_SETUP.md](EXTERNAL_SETUP.md) for the owner configuration walkthrough.

## Not currently integrated

- No OpenAI, Groq, Gemini, Anthropic or other hosted LLM API is wired into this repository. Do not provision an AI API key yet.
- Rulebook-to-event AI drafting remains product engineering work.
- Desktop Browser Web Push is verified end-to-end with the existing isolated Firebase Messaging worker, user-initiated permission/token flow and platform-aware token registration. iOS Home Screen PWA support is being prepared separately with an iOS-compatible manifest, Home Screen metadata, app icons and an install-aware permission flow; physical iPhone delivery still requires validation.
- Video calls and member-initiated screen/stream sharing require further LiveKit/WebRTC UI, permission and device/browser work.
- LiveOps screen-state classification, lobby/result extraction and low-end-device benchmarking remain incomplete.
- Full moderation queue, self-service account deletion/retention workflows, and legal review of the initial public Privacy Policy/Terms still need completion.

## Build verification

The latest checked GitHub Actions run for commit `bc829b9e277d84eb50c488aae0e933c468c6c22a` passed:
- Dart analysis.
- Flutter tests.
- Android release APK build.
- Flutter Web release build.
- Web staging artifact build.

The GitHub Pages deploy job was skipped because the repository gate is still disabled/not configured. A passing build is not production-launch certification.

## Security and performance review notes

- Supabase security advisor reports one warning for `public.withdraw_event_registration(uuid)`, which is intentionally callable by authenticated users as a SECURITY DEFINER RPC. The function validates caller identity, checks captain/event-staff authorization and restricts allowed statuses. Keep these checks intact and re-review before launch.
- Performance advisors report unindexed foreign keys, some RLS expressions that can be optimized, and overlapping permissive policies. Review and tune before scaling.
- Google sign-in authenticates a KOMNIVO platform account; UID lookup alone does not prove game-account ownership. Ownership becomes Verified only when the authenticated user places the one-time challenge as the complete in-game Bio/Signature and the server confirms an exact match in the provider's `socialInfo.signature` field. The checkbox is a UI acknowledgement, not proof by itself.
- OCR and AI observations are provisional. Only authorised organiser review and deterministic server-side scoring can produce official results.
- LiveOps capture begins only after explicit Android system consent. Raw frames are not uploaded by default; the host operates the game manually.
