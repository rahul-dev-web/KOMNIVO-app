# KOMNIVO implementation status

Last verified: 14 November 2026.

This file distinguishes work deployed to the connected Supabase project from owner-controlled external credentials and remaining product engineering.

## Live backend deployment

Connected Supabase project:
- Project: `KOMNIVO-app`
- Ref: `krqysdkbyhshwpfmimfw`
- Region: Singapore (`ap-southeast-1`)
- URL: `https://krqysdkbyhshwpfmimfw.supabase.co`
- Database: PostgreSQL 17.11

Verified on the project:
- 21 migrations applied successfully, including the Bio challenge schema, explicit deny-all client RLS policy, profile-wide three-request counter/RPCs and challenge in-flight concurrency guard.
- 52 application tables in `public`; all 52 have RLS enabled.
- Least-privilege grants applied: anonymous users can read only the active `games` catalogue; authenticated access is granted per table and column under RLS. Future `public` tables, sequences and functions created by the postgres migration owner no longer receive broad anon/authenticated default privileges.
- Two private Storage buckets: `community-media` and `match-evidence`, both limited to 10 MB and JPG/PNG/WebP/PDF.
- `public.messages` is enabled in the `supabase_realtime` publication.
- All 14 repository Edge Functions deployed and ACTIVE. User-facing functions have JWT verification enabled; `notification-push` uses its dedicated `x-webhook-secret` check.

## Implemented in source

- Flutter app shell, responsive dark theme, Google sign-in flow and local preview.
- Cold-start splash rendering (13 November 2026): Android shows a native OS launch splash using the existing KOMNIVO launcher mark before Flutter starts; Android 12+ system splash attributes are configured. `main()` now calls `runApp()` immediately, then initializes Supabase/Firebase after the first Flutter frame while the existing animated Flutter splash is visible. The Flutter splash waits for startup readiness and offers Retry on connection failure. Push permission/token synchronization is deferred until after authentication. Web `native/web/index.html` paints a branded HTML/CSS splash before the Flutter engine loads and removes it only after the first Flutter frame. Latest source commit `dc08f75e7c2af16b205c0af1081bd95e96d2e578`; Web Staging and Cloudflare Pages production deployment passed. Physical Vivo Y20G cold-start QA is still pending.
- Community discovery/create/join entry points and default channels.
- Direct/group conversation creation, persisted realtime text messages, replies, emoji reactions, secure attachments, local message search and LiveKit voice-room token issuance.
- Notification centre with read states and preferences; `notification-push` Edge Function v8 is ACTIVE and sends FCM HTTP v1 directly through a narrowly scoped Google OAuth refresh token. Supabase secrets and the `public.notifications` INSERT webhook are configured. Android push is verified on Vivo Y20G (foreground, background and tap navigation), Desktop Web Push is verified on Windows Chrome, and iOS Home Screen Web Push was verified on a physical iPhone on 13 November 2026. Foreground Snackbar styling remains a later UI-polishing task.
- Player profile and server-side Free Fire UID lookup adapter.
- Free Fire ownership verification uses a one-time Bio/Signature code. Entering a UID and generating the code make no Free Fire provider request. The player replaces the complete in-game Bio with only the exact 128-bit `KOMNIVO-...` code, checks the acknowledgement box, then taps Verify. That single Verify action makes exactly one provider `/info` request; its `basicInfo`, `clanBasicInfo` and `profileInfo` fields populate the game profile while the exact `socialInfo.signature` string is SHA-256 checked against the challenge hash. There is no separate `/stats` request in the verification flow. A database-locked profile-wide counter permits at most three provider verification requests across challenge regeneration, with a 15-second minimum interval. After three requests, the player must contact KOMNIVO Support. Codes expire after 30 minutes; plaintext codes and raw Bio/signature are not stored. Migrations `202611130001` through `202611130004` are applied; `sync-freefire-profile` Edge Function v10 is ACTIVE with JWT verification. The challenge has an explicit `verifying` state so concurrent requests cannot replace a code during an in-flight provider check; concurrent Verify calls return an in-progress state, and failed requests release the in-flight state without refunding the consumed attempt. A real Free Fire India Bio round-trip test remains outstanding.
- UID refresh integrity: the profile sync preserves an existing `ownership_status` (so a previously verified account remains verified) and rejects an in-place UID/region swap. Public profile refresh never changes ownership state; a separate controlled account-relink flow is required for any future UID change.
- Team creation, invitations and membership acceptance.
- Event discovery/publishing, team registration, match schedule, standings, check-in, time-released room credentials, evidence upload, opponent confirmation/dispute and result submission.
- Organiser approval, roster lock, group generation, match operations, dispute review, result approval and scoring/standings backend.
- Supabase schema, RLS, audit records, private buckets and privileged tournament RPC implementations.
- Android MediaProjection bridge and local ML Kit OCR preview; the raw OCR text is not used as an official result.
- Public KOMNIVO product homepage, Privacy Policy and Terms pages are authored under `native/web/` and copied by both platform bootstrap scripts into the Cloudflare Pages output. Initial text needs owner/legal review before public launch.
- GitHub Actions build workflows for Flutter analysis/tests/Android APK/Web and a Web staging artifact workflow.

## Still requires owner-controlled external setup

- Confirm `FREEFIRE_API_KEY` is configured as a Supabase Edge Function secret and that the chosen provider plan/usage terms permit KOMNIVO's intended use. Do not expose the key in Flutter, GitHub or this chat.
- Test UID entry → code generation with zero Free Fire provider requests → full Bio replacement → checkbox → one `/info` request for both profile mapping and Bio check → exact `socialInfo.signature` match → Verified notification → Bio restoration. Also test mismatched Bio, provider cache delay, 15-second throttling, three-request lock across regenerated codes, code expiry, duplicate UID claims and preservation of an already-verified account.

- Google Cloud OAuth Web Client ID/Secret and enabling Google provider in Supabase Auth.
- Active Supabase publishable key supplied as local build value and GitHub Actions variable.
- Firebase Android and Web apps are registered. Direct FCM sender credentials, Supabase Edge Function secrets and the notification INSERT webhook are configured. Android, Windows Chrome and iOS Home Screen Web Push have passed end-to-end device tests. Broader device/browser coverage and foreground Snackbar visual polish remain.
- LiveKit Cloud project URL/API key/API secret if voice rooms are to be tested.
- Free Fire provider API key and confirmation of current terms, quotas and commercial-use permissions.
- Cloudflare Pages deployment of the public homepage/policy pages and Google Search Console domain ownership verification (custom domain may be required; do not assume the shared `pages.dev` hostname will pass Google OAuth verification).
- Android upload-keystore/release signing and Play Console/legal setup.

See [EXTERNAL_SETUP.md](EXTERNAL_SETUP.md) for the owner configuration walkthrough.

## Not currently integrated

- No OpenAI, Groq, Gemini, Anthropic or other hosted LLM API is wired into this repository. Do not provision an AI API key yet.
- Rulebook-to-event AI drafting remains product engineering work.
- Desktop Browser Web Push and iOS Home Screen Web Push are verified end-to-end with the isolated Firebase Messaging worker, user-initiated permission/token flow and platform-aware token registration. Physical iPhone delivery was confirmed on 13 November 2026; wider iOS device coverage remains QA.
- Video calls and member-initiated screen/stream sharing require further LiveKit/WebRTC UI, permission and device/browser work.
- LiveOps screen-state classification, lobby/result extraction and low-end-device benchmarking remain incomplete.
- Full moderation queue, self-service account deletion/retention workflows, and legal review of the initial public Privacy Policy/Terms still need completion.

## Build verification

Latest checked source commit: `dc08f75e7c2af16b205c0af1081bd95e96d2e578`. GitHub Actions run #110 has passed Dart analysis and Flutter tests; the Android release APK build is still in progress at the time of this status update. Web Staging run #110 passed. Cloudflare Pages production deployment `11a8a2f3` completed successfully from the same commit at `https://11a8a2f3.komnivo-app.pages.dev/`; stable production origin: `https://komnivo-app.pages.dev/`. The full Android APK build and physical Vivo Y20G cold-start verification are still pending. A passing Web staging/deployment is not production-launch certification.

The legacy GitHub Pages deploy job remains skipped because Cloudflare Pages is the selected production host.

## Security and performance review notes

- Supabase security advisor reports one warning for `public.withdraw_event_registration(uuid)`, which is intentionally callable by authenticated users as a SECURITY DEFINER RPC. The function validates caller identity, checks captain/event-staff authorization and restricts allowed statuses. Keep these checks intact and re-review before launch.
- Performance advisors report unindexed foreign keys, some RLS expressions that can be optimized, and overlapping permissive policies. Review and tune before scaling.
- Google sign-in authenticates a KOMNIVO platform account; UID lookup alone does not prove game-account ownership. Ownership becomes Verified only when the authenticated user places the one-time challenge as the complete in-game Bio/Signature and the server confirms an exact match in the provider's `socialInfo.signature` field. The checkbox is a UI acknowledgement, not proof by itself.
- OCR and AI observations are provisional. Only authorised organiser review and deterministic server-side scoring can produce official results.
- LiveOps capture begins only after explicit Android system consent. Raw frames are not uploaded by default; the host operates the game manually.


## AI foundation — 14 November 2026

- Added and applied migration `202611140001_organizer_ai_foundation`: eight AI tables with RLS, explicit owner/scope access, least-privilege grants and private helper functions.
- Deployed authenticated Edge Function `komnivo-ai` v1. It supports Cloudflare Workers AI as primary and GroqCloud as an optional fallback/provider, persists conversation/run/usage records and enforces a per-user daily request cap (default 25 model attempts).
- Added Player AI entry points in the app bar and on public event cards, plus event-scoped Organizer AI entry points on organiser event cards. Recent scoped conversations restore on reopen; users can start a new chat.
- The endpoint is deliberately read-only. It does not yet ingest uploaded files, retrieve live tournament records, execute typed actions, create channels/roles/events, approve registrations or publish results. These remain required product scope and must not be marked complete.
- Provider credentials are not yet configured. The function will return `AI_PROVIDER_NOT_CONFIGURED` until the project owner adds `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` to Supabase Edge Function Secrets. Optional Groq secrets are `GROQ_API_KEY` and `GROQ_MODEL`.
- Follow `docs/AI_SETUP.md` for exact external setup and smoke tests.


## AI daily budget hardening — 14 November 2026

- Migration `202611140003_atomic_ai_daily_budget` creates a private per-user/per-UTC-day counter and a service-role-only reservation RPC.
- `komnivo-ai` now reserves one request atomically before model execution; concurrent requests cannot race past the configured daily limit. Failed attempts also count toward the daily cap.
- Supabase `komnivo-ai` Edge Function version 8 is ACTIVE with JWT verification.


## Event-scoped AI context and session recovery — 14 November 2026

- Organizer AI receives a limited live event snapshot: event rules/scoring configuration, registration status/team list, matches, standings and (where applicable) community channel metadata. It does not receive player contact details or room passwords.
- Player AI receives only its own registration/team/match/check-in details for an event. Public event rules can be discussed before registration; private-event context still requires membership or registration.
- Public/private event visibility is enforced in both the Edge Function and the database RLS scope helper.
- AI chat restores the latest active conversation for the same mode/event/community after reopening. Users can start a new chat without deleting earlier conversations.
- These assistants remain read-only. No AI-generated event or membership operation is executed yet.

- Public event access correction: signed-in players can ask about published events in public communities without joining the community; private communities/events remain member/participant-scoped. This is enforced by the AI Edge Function v7 and the database scope helper.

- Tournament-scale guard: player participation is checked through direct captain/roster lookups (not the first 200 event registrations). Organizer registration summaries include an exact count and indicate if the displayed team list is truncated.
