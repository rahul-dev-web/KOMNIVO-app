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
- Notification centre with read states and notification preferences; `notification-push` Edge Function v8 is deployed ACTIVE and sends FCM HTTP v1 directly through a narrowly scoped Google OAuth refresh token (no Cloud Run billing and no downloadable service-account JSON key). Supabase secrets and the `public.notifications` INSERT webhook are configured. A controlled Android test notification was displayed on the Vivo Y20G. Browser Web Push source is now committed; Cloudflare Firebase Web build variables and live browser testing remain.
- Player profile and server-side Free Fire UID lookup adapter.
- Team creation, invitations and membership acceptance.
- Event discovery/publishing, team registration, match schedule, standings, check-in, time-released room credentials, evidence upload, opponent confirmation/dispute and result submission.
- Organiser approval, roster lock, group generation, match operations, dispute review, result approval and scoring/standings backend.
- Supabase schema, RLS, audit records, private buckets and privileged tournament RPC implementations.
- Android MediaProjection bridge and local ML Kit OCR preview; the raw OCR text is not used as an official result.
- Public KOMNIVO product homepage, Privacy Policy and Terms pages are authored under `native/web/` and copied by both platform bootstrap scripts into the Cloudflare Pages output. Initial text needs owner/legal review before public launch.
- GitHub Actions build workflows for Flutter analysis/tests/Android APK/Web and a Web staging artifact workflow.

## Still requires owner-controlled external setup

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
- Browser Web Push source now includes an isolated Firebase Messaging service worker, a user-initiated browser permission/token flow, platform-aware token registration and WebPush-specific server payloads. It still needs Firebase Web config/VAPID values in Cloudflare Pages and a successful live browser delivery test; iOS Home Screen Web Push remains a separate follow-up.
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
- Google sign-in authenticates a KOMNIVO platform account; a Free Fire UID lookup does not prove game-account ownership.
- OCR and AI observations are provisional. Only authorised organiser review and deterministic server-side scoring can produce official results.
- LiveOps capture begins only after explicit Android system consent. Raw frames are not uploaded by default; the host operates the game manually.
