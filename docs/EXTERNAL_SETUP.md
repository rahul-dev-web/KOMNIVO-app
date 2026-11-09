# KOMNIVO — external service setup

This document lists the service configuration that cannot be safely fabricated in source code. Never send private keys, OAuth client secrets, service-role keys, signing files or LiveKit secrets in chat or commit them to GitHub.

## 1. Supabase — required

Create a **new project named KOMNIVO** in the Mumbai region (`ap-south-1`). Do not reuse RDS-NEARBY, Saathi-ai or another app's database.

After the project is created:

1. Open the project Dashboard and copy its project reference and project URL.
2. Apply migrations in this order:
   - `supabase/migrations/202611090001_komnivo_core.sql`
   - `supabase/migrations/202611090002_rls_scoring_corrections.sql`
   - `supabase/migrations/202611090003_integrity_messaging_hardening.sql`
   - `supabase/migrations/202611090004_trigger_and_storage_hardening.sql`
   - `supabase/migrations/202611090005_product_workflows_and_scoring.sql`
   - `supabase/migrations/202611090006_invite_and_messaging_security.sql`
   - `supabase/migrations/202611090007_roster_and_group_automation.sql`
   - `supabase/migrations/202611090008_match_and_dispute_guardrails.sql`
   - `supabase/migrations/202611090009_private_rpc_implementations.sql`
3. Deploy all functions under `supabase/functions/`. Keep the shared helper file at `_shared/http.ts` when deploying dependent functions.
4. In Project Settings / API, copy the **publishable** key (`sb_publishable_...`). Use this in the Flutter app. Do not use the service-role key in a client.
5. In Authentication URL configuration, add the app redirect URL:
   - Android: `in.komnivo.app://login-callback`
   - Web: the exact GitHub Pages or custom domain origin/path that will host the app.
   - Local development: the local origin/port used by the developer.
6. Confirm `public` is an exposed Data API schema in Project Settings → API → Data API, and verify the new tables are enabled for Data API access. The SQL migrations grant the required table privileges and enable RLS; project-level Data API exposure is a separate setting.
7. Enable Realtime for the `messages` table if it is not already included in the `supabase_realtime` publication.

### Edge Function secrets

Set these under Dashboard → Edge Functions → Secrets. Supabase reserves the `SUPABASE_` prefix, so use the names below exactly:

| Secret | Needed for | Where it comes from |
| --- | --- | --- |
| `FREEFIRE_API_KEY` | Free Fire UID profile lookup | Approved API provider account |
| `FREEFIRE_API_BASE_URL` | Optional provider base URL override | Provider docs; omit to use the documented default |
| `LIVEKIT_URL` | Voice rooms | LiveKit Cloud project URL |
| `LIVEKIT_API_KEY` | Voice-room token issuance | LiveKit Cloud API key |
| `LIVEKIT_API_SECRET` | Voice-room token signing | LiveKit Cloud secret |
| `PUSH_WEBHOOK_SECRET` | Authenticates the database-to-push webhook | Generate a long random value locally |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | Server-side FCM HTTP v1 access | Google Cloud service account JSON (keep private) |
| `FIREBASE_PROJECT_ID` | FCM project routing | Firebase project settings |

Supabase injects its own `SUPABASE_URL`, `SUPABASE_ANON_KEY` and service-role environment variables into Edge Functions. Never copy those into Flutter.

### Configure notification delivery

The database writes user notifications to `public.notifications`. To deliver those records to FCM:

1. Deploy the `notification-push` Edge Function.
2. In Supabase Database Webhooks, create an INSERT webhook for `public.notifications`.
3. Set the webhook URL to `https://YOUR_PROJECT_REF.supabase.co/functions/v1/notification-push`.
4. Add an HTTP header `x-webhook-secret` with exactly the same value as `PUSH_WEBHOOK_SECRET`.
5. Create a Google Cloud service account with the Firebase Cloud Messaging API permission and store the full JSON document as `FIREBASE_SERVICE_ACCOUNT_JSON` in Edge Function Secrets.
6. Test by generating a notification for a user who has signed in on an Android device and granted notification permission.

Do not enable the database webhook until the Edge Function secret is saved. The webhook endpoint disables JWT verification only because it authenticates the private webhook header itself.

## 2. Google Cloud OAuth — required for Google sign-in

1. Open Google Cloud Console and create/select a project dedicated to KOMNIVO.
2. Configure Google Auth Platform branding and audience. Add the app name, support contact and authorised domains when the public domain is known.
3. Create an OAuth Client ID of type **Web application**.
4. Add this exact Supabase callback to **Authorised redirect URIs**:

   `https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback`

5. Add the final web origin to **Authorised JavaScript origins** (for example, the GitHub Pages origin after it is enabled).
6. Copy the OAuth Client ID and Client Secret into Supabase Dashboard → Authentication → Sign In / Providers → Google.
7. Enable Google as a Supabase provider and save.
8. Do not put the Google Client Secret in Flutter, GitHub source, a public environment variable or a support message.

The OAuth callback belongs to Supabase. The app's Android deep link is a separate redirect URL and must also be allow-listed in Supabase Auth URL configuration.

## 3. Firebase Cloud Messaging — required for push notifications

1. Create a Firebase project for KOMNIVO.
2. Add an Android app with package ID **`in.komnivo.app`**.
3. Add a Web app if web push is required.
4. Collect the Firebase app configuration values listed in `.env.example`:
   - `FIREBASE_API_KEY`
   - `FIREBASE_APP_ID`
   - `FIREBASE_MESSAGING_SENDER_ID`
   - `FIREBASE_PROJECT_ID`
   - `FIREBASE_STORAGE_BUCKET` (if configured)
   - `FIREBASE_AUTH_DOMAIN` (for web, if configured)
   - `FIREBASE_VAPID_KEY` (for web push)
5. Supply these as build-time `--dart-define` values; they are Firebase client identifiers, not server credentials.
6. For Android push, verify the app is registered under the exact package ID and that FCM is enabled.
7. Web push additionally requires a Firebase Messaging service worker, HTTPS hosting and a browser notification permission flow. The first complete push path is Android; finish and test the web worker before promising web push.

The Flutter app stores its FCM registration token in the user's private `device_tokens` record after sign-in. Supabase Database Webhooks forward new `notifications` records to the server-side FCM delivery function.

## 4. Free Fire profile provider — required only for game-profile sync

The code currently integrates the documented Free Fire Community API as a replaceable **unofficial** provider candidate. Obtain an API key and confirm its current quota, commercial-use permission, terms and compatibility before production. Set only `FREEFIRE_API_KEY` as a Supabase Edge Function secret.

The provider is not Garena. A UID lookup only fetches third-party data; it does not prove account ownership or confer an official verification badge.

## 5. LiveKit — required for voice rooms

1. Create a LiveKit Cloud project (or prepare a separately operated LiveKit server).
2. Copy the server URL, API key and API secret into Supabase Edge Function Secrets as `LIVEKIT_URL`, `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET`.
3. Never place the API secret in Flutter or in GitHub.
4. The app requests a short-lived room token from the authenticated `create-livekit-token` Edge Function. Voice rooms work only after the secrets and provider project are configured.

## 6. Cloud staging and public web app

A GitHub Pages workflow is included. To enable staging:

1. Open this GitHub repository → Settings → Pages.
2. Under Build and deployment, set Source to **GitHub Actions**.
3. Add the repository Actions variables:
   - `SUPABASE_URL`
   - `SUPABASE_PUBLISHABLE_KEY`
   - `SUPABASE_REDIRECT_URL` (the final Pages URL, including repository path)
4. Add optional Firebase client configuration as Actions variables if web notification work is being tested.
5. Push to `main`; the workflow builds Flutter Web and publishes the Pages artifact.
6. Add the resulting HTTPS origin/path to Supabase Auth redirect URLs and Google OAuth authorised origins.
8. Set repository Actions variable `ENABLE_GITHUB_PAGES` to `true`. The Pages deploy job is intentionally gated until Pages has been enabled and this variable is set.

Initial Pages URL format:
`https://rahul-dev-web.github.io/KOMNIVO-app/`

A custom production domain can be connected later. The repository CI workflow separately builds an Android APK and the Web bundle and retains the files as GitHub Actions artifacts.

## 7. Android release and Play Store

1. Generate an upload keystore locally; never commit it.
2. Configure release signing in the local Android Gradle file or a secured CI signing workflow.
3. Register `in.komnivo.app` as the application ID in Play Console.
4. Prepare a public privacy policy, terms, community standards, grievance contact, age policy and data deletion route.
5. Complete Google Play's user-generated-content declarations, Data Safety form and permissions review.
6. Run Android 13+ LiveOps screen-capture testing on real devices. Screen capture requires explicit system consent and a persistent foreground service.

## 8. Flutter packages already declared

The project already declares these Flutter dependencies in `pubspec.yaml`: `supabase_flutter`, `firebase_core`, `firebase_messaging`, `livekit_client`, `flutter_tts` and `file_picker`. You do not need to install a separate ChatGPT plugin for these packages.

## 9. External items still requiring owner action

- Choose which Supabase organisation owns the new KOMNIVO project.
- Create/configure the Google Cloud OAuth Web Client.
- Create the Firebase project and register Android/Web apps.
- Obtain/approve the Free Fire provider API key and commercial-use terms.
- Create the LiveKit project if voice rooms are required.
- Enable GitHub Pages in repository settings and set its Actions variables.
- Generate Android upload signing credentials and complete store/legal setup before publishing to Google Play.
