# KOMNIVO

**KOMNIVO — Esports Community OS**

One connected platform for gaming communities, communication, player and team identity, scrims, tournaments, match operations and same-phone LiveOps assistance.

## Product specification

The authoritative product scope, decisions, security boundaries and end-to-end delivery blueprint live in the [KOMNIVO Notion specification](https://app.notion.com/p/4121e4f822d3818c9735de4f6b9e003f?pvs=204).

## Repository layout

- `lib/` — Flutter player app and organiser experience.
- `lib/features/community` — communities and community channels.
- `lib/features/inbox` — messages, direct conversations and LiveKit voice rooms.
- `lib/features/compete` — published events and team registration.
- `lib/features/teams` — team identity and roster entry point.
- `lib/features/profile` — player identity and Free Fire UID sync.
- `lib/features/organizer` — organiser workspace and event publishing.
- `lib/features/liveops` — same-phone LiveOps controls and observation review.
- `native/android/` — Kotlin MediaProjection capture and on-device ML Kit OCR.
- `supabase/migrations/` — database schema, RLS and scoring procedures.
- `supabase/functions/` — authenticated Edge Functions and provider adapters.
- `tool/` — scripts that generate Flutter Android/Web scaffolding on the machine or CI runner.

## Local setup (Windows)

Requirements: Flutter stable (3.44.8 or newer recommended), Dart SDK bundled with Flutter, Android Studio/Android SDK, and JDK 17 for Android builds.

1. Clone this repository and open the folder containing `pubspec.yaml`.
2. Run PowerShell from the repository root:

   ```powershell
   flutter pub get
   Set-ExecutionPolicy -Scope Process Bypass
   .\tool\bootstrap-platforms.ps1
   ```

3. Create a dedicated KOMNIVO Supabase project and complete the external setup in [docs/EXTERNAL_SETUP.md](docs/EXTERNAL_SETUP.md).
4. Run the app with your project values:

   ```powershell
   flutter run -d chrome --dart-define=SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_YOUR_KEY --dart-define=SUPABASE_REDIRECT_URL=https://YOUR_WEB_ORIGIN
   ```

   For Android, use the same Dart defines and the registered deep-link redirect:

   ```powershell
   flutter run -d YOUR_DEVICE_ID --dart-define=SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_YOUR_KEY --dart-define=SUPABASE_REDIRECT_URL=in.komnivo.app://login-callback
   ```

5. Optional Firebase Messaging values are supplied with additional `--dart-define` values. See the external setup guide.

## Build and test

```powershell
flutter analyze
flutter test
flutter build apk --release --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...
flutter build web --release --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=...
```

The GitHub Actions workflow runs analysis, tests and Android/Web builds on pushes and pull requests. It generates Android/Web scaffolding on the runner; those generated folders are intentionally not committed.

## Backend and security

- Supabase Auth handles Google OAuth and platform identity.
- PostgreSQL RLS is enabled on application tables.
- Service-role and game provider secrets are used only inside Edge Functions.
- The Free Fire profile provider is unofficial. UID lookup does not prove account ownership.
- Result OCR is provisional evidence. Only authorised organiser approval writes official scoring.
- LiveOps uses user-approved Android MediaProjection and on-device text recognition. It does not tap or control Free Fire.

## Current integration status

This repository contains the integrated Flutter app foundation, core feature screens, database schema/RLS, provider Edge Functions, LiveKit token issuance and the native LiveOps capture module. Real sign-in, database-backed features, push delivery, voice service and game profile sync require the external project credentials described in the setup guide. The code has not yet completed a real-device QA run, Google OAuth test, production security audit or Play Store release review. Do not treat this commit alone as production launch approval.
