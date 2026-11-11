# KOMNIVO

**KOMNIVO — Esports Community OS**

One connected platform for gaming communities, player/team identity, communication, scrims, tournament operations and same-phone LiveOps assistance.

## Product specification

The authoritative product scope, rules, decisions and complete delivery blueprint are documented in the [KOMNIVO Notion specification](https://app.notion.com/p/4121e4f822d3818c9735de4f6b9e003f?pvs=204).

## Repository layout

- `lib/` — Flutter player app and organiser workspace.
- `lib/features/community` — community discovery, create/join and channel entry points.
- `lib/features/inbox` — direct/group conversations, realtime text chat, replies, emoji reactions, secure attachments, search and LiveKit voice rooms.
- `lib/features/compete` — event discovery, registration, public match schedule, match check-in, private room credentials and player result workflow.
- `lib/features/teams` — team profiles, invitations and roster membership.
- `lib/features/profile` — player identity and server-side Free Fire UID lookup.
- `lib/features/organizer` — event publishing, approval queue, roster lock, group generation, match operations, room credentials, disputes, result approval and standings.
- `lib/features/liveops` — same-phone Android capture controls and local OCR preview.
- `native/android/` — Kotlin MediaProjection capture bridge and on-device ML Kit OCR.
- `native/web/` — Flutter Web shell plus public product homepage, privacy policy, terms of service and KOMNIVO SVG brand mark.
- `supabase/migrations/` — core schema, RLS, tournament workflows, invite security and private RPC implementations.
- `supabase/functions/` — authenticated Edge Functions, FCM webhook delivery and provider adapters.
- `tool/` — local/CI scripts that generate Flutter Android and Web scaffolding (including the public policy pages), plus the pinned Flutter builder used by Cloudflare Pages.

## Local setup (Windows)

Requirements: Flutter stable (3.44.8 or newer recommended), Android Studio/Android SDK, and JDK 17 for Android builds.

1. Clone this repository and open the directory containing `pubspec.yaml`.
2. Open PowerShell in that directory:

   ```powershell
   flutter pub get
   Set-ExecutionPolicy -Scope Process Bypass
   .\tool\bootstrap-platforms.ps1
   ```

3. Create a dedicated Supabase project for KOMNIVO. Follow [docs/EXTERNAL_SETUP.md](docs/EXTERNAL_SETUP.md) to configure Google OAuth, database migrations, Edge Functions and provider secrets.
4. Start the app with your Supabase project values:

   ```powershell
   flutter run -d chrome --dart-define=SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_YOUR_KEY --dart-define=SUPABASE_REDIRECT_URL=https://YOUR_WEB_ORIGIN
   ```

   For Android, use the registered deep link:

   ```powershell
   flutter run -d YOUR_DEVICE_ID --dart-define=SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_YOUR_KEY --dart-define=SUPABASE_REDIRECT_URL=in.komnivo.app://login-callback
   ```

5. Supply Firebase client configuration as additional `--dart-define` values when Android push is configured. Do not put service-role keys, provider secrets or OAuth client secrets into Flutter.

## Build and CI

The GitHub Actions CI workflow resolves Flutter packages, analyses Dart, runs tests, builds a release Android APK and builds the Web bundle. Build artifacts are retained on the Actions run.

The selected Web host is **Cloudflare Pages**; GitHub is used only for source control. The confirmed production URL is [https://komnivo-app.pages.dev/](https://komnivo-app.pages.dev/). In Cloudflare Pages, connect this repository's `main` branch, set the build command to `bash tool/cloudflare-build.sh`, and set the output directory to `build/web`. The script installs and SHA-256 verifies the pinned Flutter 3.44.8 SDK, generates the ignored Android/Web scaffolding, resolves packages and builds the Web release using the `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` build environment variables. After the first deployment, add the assigned `*.pages.dev` origin to Supabase Auth redirect URLs and Google's Authorized JavaScript origins. The legacy GitHub Pages workflow is not the selected hosting path.

## Backend and security boundaries

- Supabase Auth is the platform identity provider; Google OAuth is configured in Supabase.
- RLS is enabled on public application tables. Privileged tournament RPC implementations live in the non-exposed `app_private` schema; public RPC entry points are invoker wrappers.
- Provider API keys, the Google OAuth refresh token/client secret used by the FCM sender, LiveKit secrets and Supabase service-role credentials belong only in their respective secret stores. Android FCM delivery is sent directly by the Supabase Edge Function using the narrowly scoped `firebase.messaging` OAuth scope; no Cloud Run service or downloaded service-account JSON key is used.
- Free Fire data lookup uses an unofficial third-party provider candidate. A UID lookup does not prove account ownership and must not be shown as official Garena verification.
- Tournament results and standings remain controlled by organiser approval and deterministic server-side scoring.
- LiveOps uses explicit Android MediaProjection consent and on-device OCR. It does not tap, click or control the Free Fire client.

## Implementation and launch status

The repository includes a connected Flutter application foundation, tournament and organiser workflows, database schema/RLS, Edge Functions, LiveKit token issuance and an Android LiveOps capture prototype. Android Google OAuth and real-device launch have been verified. Cloudflare Pages deployment, Web OAuth allowlist updates, Firebase/LiveKit configuration, final game-provider review and broader production QA remain to be completed. See [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md) and [docs/EXTERNAL_SETUP.md](docs/EXTERNAL_SETUP.md).

This commit is not a production-launch certification. Complete the external integration checks, RLS/advisor review, Android device matrix, privacy/legal documents and Play Console review before inviting public users.
