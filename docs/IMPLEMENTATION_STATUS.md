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
- 24 migrations applied successfully, including the Bio challenge schema, explicit deny-all client RLS policy, profile-wide three-request counter/RPCs and challenge in-flight concurrency guard.
- 53 application tables in `public`; all 53 have RLS enabled.
- Least-privilege grants applied: anonymous users can read only the active `games` catalogue; authenticated access is granted per table and column under RLS. Future `public` tables, sequences and functions created by the postgres migration owner no longer receive broad anon/authenticated default privileges.
- Three private Storage buckets: `community-media` and `match-evidence` (10 MB, JPG/PNG/WebP/PDF), plus `ai-documents` (25 MB, document and image MIME allow-list).
- `public.messages` is enabled in the `supabase_realtime` publication.
- All 15 repository Edge Functions deployed and ACTIVE. User-facing functions have JWT verification enabled; `notification-push` uses its dedicated `x-webhook-secret` check.

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
- Deployed authenticated Edge Function `komnivo-ai` v11. It supports Cloudflare Workers AI as primary and GroqCloud as an optional fallback/provider, persists conversation/run/usage records, retrieves scope-filtered source chunks and enforces a per-user daily request cap (default 25 model attempts).
- Added Player AI entry points in the app bar and on public event cards, plus event-scoped Organizer AI entry points on organiser event cards. Recent scoped conversations restore on reopen; users can start a new chat.
- The first approved write workflow is an event-draft proposal: Organizer AI may call a typed `propose_event_draft` tool, which stores a pending proposal. The organiser must explicitly approve it; the service-role-only resolver rechecks the actor's current owner/admin/organiser rights and creates an event with `status='draft'` only. It never publishes. Other write operations (channels/roles/permissions, registrations, recurring scrims, scoring/result publication and notifications) remain required work.
- Provider credentials are not yet configured. The function will return `AI_PROVIDER_NOT_CONFIGURED` until the project owner adds `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` to Supabase Edge Function Secrets. Optional Groq secrets are `GROQ_API_KEY` and `GROQ_MODEL`.
- Follow `docs/AI_SETUP.md` for exact external setup and smoke tests.


## AI daily budget hardening — 14 November 2026

- Migration `202611140003_atomic_ai_daily_budget` creates a private per-user/per-UTC-day counter and a service-role-only reservation RPC.
- `komnivo-ai` now reserves one request atomically before model execution; concurrent requests cannot race past the configured daily limit. Failed attempts also count toward the daily cap.
- Supabase `komnivo-ai` Edge Function v13 is ACTIVE with JWT verification; `komnivo-ai-process-document` v4 and `komnivo-ai-proposal-action` v3 are also ACTIVE with JWT verification.


## Event-scoped AI context and session recovery — 14 November 2026

- Organizer AI receives a limited live event snapshot: event rules/scoring configuration, registration status/team list, matches, standings and (where applicable) community channel metadata. It does not receive player contact details or room passwords.
- Player AI receives only its own registration/team/match/check-in details for an event. Public event rules can be discussed before registration; private-event context still requires membership or registration.
- Public/private event visibility is enforced in both the Edge Function and the database RLS scope helper.
- AI chat restores the latest active conversation for the same mode/event/community after reopening. Users can start a new chat without deleting earlier conversations.
- Player AI remains read-only. Organizer AI can propose an event draft and execute only the explicitly approved draft-creation operation; no AI membership, role, channel, registration or results write is enabled.

- Public event access correction: signed-in players can ask about published events in public communities without joining the community; private communities/events remain member/participant-scoped. This is enforced by the AI Edge Function v13 and the database scope helper.

- Tournament-scale guard: player participation is checked through direct captain/roster lookups (not the first 200 event registrations). Organizer registration summaries include an exact count and indicate if the displayed team list is truncated.


## AI document ingestion — 14 November 2026

- Applied migration `202611140006_ai_document_ingestion`; created private Storage bucket `ai-documents` with 25 MB cap, allowed MIME list and owner-folder upload/download/delete policies.
- Added `public.ai_document_chunks` with RLS, source/page/sheet provenance and a GIN full-text search index. Added document visibility values: `organizer_only`, `participants`, `public`.
- Deployed JWT-protected Edge Function `komnivo-ai-process-document` v2. It extracts text from PDF (up to 120 pages), DOCX, XLSX/XLS, CSV, TXT and Markdown; screenshots PNG/JPEG/WebP use Qwen 3.8 Vision through the same Cloudflare API token and consume the user's atomic daily AI request budget.
- Organizer AI retrieves up to five relevant chunks from only the selected event/community, and the prompt requires source citations. Player AI only retrieves public documents or participant-visible documents when the player is an event participant/community member.
- Flutter Organizer AI chat now supports uploading rulebooks, schedules, spreadsheets and screenshots, choosing document visibility, uploading to private storage and starting server-side extraction.
- OCR requires the owner to configure Cloudflare token secrets. Document parsing and retrieval code is deployed but end-to-end file upload/extraction QA is pending the provider token and a signed-in organiser test account.

- Latest verified function versions: `komnivo-ai` v13, `komnivo-ai-process-document` v4 and `komnivo-ai-proposal-action` v3, both ACTIVE with JWT verification.

- Community-only AI sessions (without a specific event) now retrieve relevant chunks from the authorized community documents as well as event-scoped document retrieval.


## Organizer AI approval-gated event draft — 14 November 2026

- Applied migrations `202611140007_organizer_ai_approval_execution` and `202611140008_fix_ai_service_role_actor_check`.
- `komnivo-ai` v13 exposes one typed Organizer tool: `propose_event_draft`. It validates name, game, format, capacity, timezone-aware future start and registration close, rules/scoring object sizes, and derives community scope from the authenticated conversation—not model arguments.
- A tool call creates a pending `ai_proposals` row with a 30-minute expiry and source references. It does not create an event.
- `komnivo-ai-proposal-action` v3 requires a valid JWT and owner-matching proposal. Approval/rejection is processed by a service-role-only SQL resolver that uses the verified actor ID to recheck current event/community organiser permissions, locks the proposal, validates again, uses an idempotency key, writes `ai_actions` and `audit_logs`, and inserts a new event with status `draft` only.
- Flutter renders proposal cards with source references and explicit Approve draft / Reject controls. After approval, the organiser event list refreshes when returning from AI. The app states the event is not published.
- End-to-end provider tool-call and approval QA is pending Cloudflare token setup and a signed-in organiser test; Deno type-check/Flutter checks are run in CI.

## AI provider configuration gate — 15 November 2026

- GitHub PR #1 latest CI run `43626833317` completed successfully: Flutter analysis, tests, Android release APK build, Web release build, Deno Edge Function type-check and Windows bootstrap all passed.
- Supabase AI Edge Functions are ACTIVE with JWT verification: `komnivo-ai` v13, `komnivo-ai-process-document` v4, `komnivo-ai-proposal-action` v3.
- Cloudflare Workers AI token and account ID are still an owner-side setup step. After the owner creates the least-privilege Workers AI Read token, they must add `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_MODEL=@cf/qwen/qwen3.8-27b`, `AI_PROVIDER=cloudflare`, and `AI_DAILY_REQUEST_LIMIT=25` to Supabase Edge Function Secrets.
- Provider live smoke test, document upload/OCR end-to-end QA and event-draft tool-call/approval QA remain blocked on the secrets and signed-in test accounts. PR #1 remains open; do not call the AI feature production-complete.


## Contextual AI architecture implementation — 15 November 2026

- Product decision: one platform account and one contextual KOMNIVO AI assistant. Player capabilities are always available; organizer capabilities are resolved from the authenticated user and selected community/event permissions. A global `is_organizer` account flag is not used.
- GitHub feature branch updated with `resolveAiCapabilities`, one contextual system prompt, scope-restricted document retrieval, combined player + organizer event context, legacy conversation mode compatibility and server-derived capabilities in the response.
- Supabase Edge Function `komnivo-ai` deployed as version 15 with JWT verification enabled.
- Applied migration `202611150001_contextual_ai_owner_notification`: verifies Owner membership bootstrap, then inserts one idempotent notification for the community creator. The existing push notification trigger handles delivery. Existing communities are not backfilled.
- Flutter UI intentionally unchanged in this update; existing Player/Organizer entry points remain as legacy screens until the product owner selects a Canva design theme.
- Canva folder for the four-theme design exploration: https://www.canva.com/folder/FAHa86K9Hr4
- Latest CI run 43670839881: Edge Function type-check passed; Flutter analysis and tests passed; Windows bootstrap passed. At the time of this update, Android release build was still running and Web release build had not started. Do not describe CI as fully green until all jobs complete.
- Notion product decision recorded in AI Blueprint Section 19.
- Remaining: final CI result; unified Flutter UI/context selection; additional organizer tools (channels/categories/roles/permissions, registration, recurring scrims and standings/results); broad player workflows; end-to-end and cross-community authorization tests. AI is not production-complete.
