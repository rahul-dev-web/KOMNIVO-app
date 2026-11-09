# KOMNIVO — External services setup guide

Last checked: 9 November 2026

This guide is for the existing repository and the Supabase project already created for KOMNIVO. It separates what is already deployed from the credentials and dashboard steps that still need the project owner's action.

## 1. Current project — already created and connected

| Setting | Current value |
| --- | --- |
| Supabase project name | `KOMNIVO-app` |
| Project reference | `krqysdkbyhshwpfmimfw` |
| Region | Singapore — `ap-southeast-1` |
| Project URL | `https://krqysdkbyhshwpfmimfw.supabase.co` |
| Database | PostgreSQL 17.11 |
| Flutter Android package | `in.komnivo.app` |
| Android OAuth return URI | `in.komnivo.app://login-callback` |
| GitHub repository | `rahul-dev-web/KOMNIVO-app` |
| Planned Web staging URL | `https://rahul-dev-web.github.io/KOMNIVO-app/` |

The project is in Singapore because that is the region selected in the Supabase dashboard. Keep this project; there is no need to create another database solely to chase a Mumbai region option.

### Backend work already completed

- Eleven database migrations are applied, including the least-privilege Data API grants migration.
- Forty-three application tables exist in the `public` schema, and all forty-three have Row Level Security enabled.
- Anonymous table access is limited to reading the active `games` catalogue. Application tables are granted to authenticated users only, subject to RLS and column-level restrictions.
- Default table, sequence and function privileges for new `public` objects created by the postgres migration owner have been tightened. Future migrations must grant only the exact privileges they need.
- Both Storage buckets exist and are private: `community-media` and `match-evidence` (10 MB per file; JPG, PNG, WebP and PDF).
- The `messages` table is included in the `supabase_realtime` publication.
- Thirteen Edge Functions are deployed and ACTIVE.

Deployed functions: `accept-team-invite`, `approve-result`, `check-in`, `create-community-invite`, `create-community`, `create-conversation`, `create-livekit-token`, `join-community`, `notification-push`, `register-event`, `review-registration`, `submit-result`, and `sync-freefire-profile`.

All user-facing functions require JWT verification. `notification-push` is the one exception because it is called by a database webhook and checks the private `x-webhook-secret` header itself. Do not remove that header check.

## 2. What external services KOMNIVO actually uses

| Product capability | Provider / implementation | Separate API key needed? |
| --- | --- | --- |
| Google login | Google OAuth through Supabase Auth | Yes — Google Web OAuth Client ID and Client Secret, entered in Supabase Auth provider settings |
| Text chat, DMs and group text | Supabase Postgres + Supabase Realtime | No third-party chat provider |
| File and result-evidence storage | Supabase Storage | No separate provider |
| Push notifications | Firebase Cloud Messaging (FCM) | Yes — Firebase client configuration plus a server service-account JSON |
| Voice rooms | LiveKit | Yes — LiveKit URL, API key and API secret |
| Free Fire UID profile sync | Free Fire Community API (unofficial) | Yes — provider API key |
| Same-phone LiveOps screen OCR | Android MediaProjection + Google ML Kit on-device text recognition | No cloud vision API key |
| Voice prompts for LiveOps | Device text-to-speech via `flutter_tts` | No cloud voice API key |
| AI / LLM rulebook assistant | Not wired into the current code | No AI key to configure now |

Important: the Notion product specification includes future AI-assisted rulebook drafting. The current repository does not contain an OpenAI, Groq, Gemini, Anthropic or other LLM API integration. Do not purchase or paste an AI API key for KOMNIVO yet. That feature needs a deliberate provider decision and implementation first.

There is also no ChatGPT plugin that needs to be installed. These integrations are normal Flutter packages and Supabase Edge Functions already listed in the repository.

## 3. Supabase — app connection and dashboard checks

Open the Supabase dashboard and select project reference `krqysdkbyhshwpfmimfw`.

### A. Get the publishable key

1. Open **Project Settings → API Keys** (the label may appear as **API** in the dashboard).
2. Copy the active **Publishable key**, whose prefix is `sb_publishable_`.
3. Do not copy the `service_role` / secret key into Flutter, Web, GitHub Actions variables, or this guide.
4. Set the URL and publishable key as build-time values. The URL is already:
   `https://krqysdkbyhshwpfmimfw.supabase.co`.

### B. Verify Data API and Auth URLs

1. In **Project Settings → API → Data API**, make sure the `public` schema is exposed. The SQL grants and RLS policies are already prepared for this schema.
2. In **Authentication → URL Configuration**, set the Site URL to the intended Web URL when staging is ready:
   `https://rahul-dev-web.github.io/KOMNIVO-app/`.
3. Add these Redirect URLs:
   - `in.komnivo.app://login-callback` (Android)
   - `https://rahul-dev-web.github.io/KOMNIVO-app/` (GitHub Pages Web)
   - The exact local development URL you use, for example `http://localhost:55000/` (use your actual local port).
4. If the Web URL or local port changes, update the allow-list as well.

The database, RLS, private Storage buckets and messages Realtime publication have already been created. Do not rerun the original ten migrations on this project.

### C. Edge Function secrets

Open **Edge Functions → Secrets** and add the entries below. Supabase reserves the `SUPABASE_` prefix and injects its own project variables automatically; do not create your own `SUPABASE_SERVICE_ROLE_KEY` secret.

| Secret name | Required when | Value source |
| --- | --- | --- |
| `PUSH_WEBHOOK_SECRET` | Push delivery | Generate a long random value (at least 32 random bytes) |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | Push delivery | Entire Google Cloud service-account JSON document |
| `FIREBASE_PROJECT_ID` | Push delivery | Firebase project ID |
| `LIVEKIT_URL` | Voice rooms | LiveKit Cloud WebSocket URL |
| `LIVEKIT_API_KEY` | Voice rooms | LiveKit project API key |
| `LIVEKIT_API_SECRET` | Voice rooms | LiveKit project API secret |
| `FREEFIRE_API_KEY` | Free Fire profile sync | API key from the approved provider account |
| `FREEFIRE_API_BASE_URL` | Optional override | Omit it to use the code default: `https://developers.freefirecommunity.com/api/v1` |

You can save only the secrets for the services you are ready to configure. A function that lacks its required provider secret returns a clear not-configured response; the rest of the app can still be used.

## 4. Google Cloud OAuth — required for Google login

The Flutter sign-in button calls `Supabase Auth signInWithOAuth(Google)`. Google authenticates the user through Supabase; the app does not use a Google password or a separate Google sign-in API key in client code.

1. Open Google Cloud Console and create/select a project dedicated to KOMNIVO.
2. Open **Google Auth Platform** and configure the app name, support contact, audience and branding information.
3. Open **Clients → Create client** and choose **Web application**.
4. Under **Authorized JavaScript origins**, add:
   - `https://rahul-dev-web.github.io`
   - `http://localhost:<your-port>` only while testing locally.
5. Under **Authorized redirect URIs**, add this exact Supabase callback:
   `https://krqysdkbyhshwpfmimfw.supabase.co/auth/v1/callback`
6. Create the client and copy the **Client ID** and **Client Secret**.
7. In Supabase, open **Authentication → Sign In / Providers → Google**, enable Google, and paste the Client ID and Client Secret.
8. Save and test sign-in from an Android build after the Android redirect URI has been allow-listed in Supabase.

Do not paste the Google Client Secret into Flutter, `.env.example`, GitHub source, or GitHub Actions variables. The Google callback above is different from the Android app return URI `in.komnivo.app://login-callback`.

## 5. Firebase Cloud Messaging — required for Android push notifications

### A. Create and register the Firebase app

1. Open Firebase Console and create a dedicated Firebase project named **KOMNIVO**.
2. Add an **Android app** with package name `in.komnivo.app`.
3. Add a Firebase **Web app** only when you are ready to implement and test browser push. The current web build does not yet include a complete web-push service-worker flow.
4. Open **Project settings → General → Your apps** and copy the client configuration values:
   - `FIREBASE_API_KEY`
   - `FIREBASE_APP_ID`
   - `FIREBASE_MESSAGING_SENDER_ID`
   - `FIREBASE_PROJECT_ID`
   - `FIREBASE_STORAGE_BUCKET` (if provided)
   - `FIREBASE_AUTH_DOMAIN` (if provided)
   - `FIREBASE_VAPID_KEY` (only for Web push)
5. These Firebase client identifiers are supplied to Flutter with `--dart-define`. They are not the Firebase server service-account private key.

### B. Enable server-side FCM delivery

1. In Firebase Console, open **Project settings → Cloud Messaging** and enable the **Firebase Cloud Messaging API (HTTP v1)**.
2. In Google Cloud IAM, create a service account for the KOMNIVO push sender and grant it the **Firebase Cloud Messaging API Admin** role for the target Firebase project.
3. Create/download a JSON key for that service account.
4. In Supabase **Edge Functions → Secrets**, save the entire JSON contents as `FIREBASE_SERVICE_ACCOUNT_JSON` and save `FIREBASE_PROJECT_ID`.
5. Generate a random `PUSH_WEBHOOK_SECRET` and save it in the same Supabase secrets page.

### C. Connect Supabase notifications to FCM

1. In Supabase **Database → Webhooks**, create a webhook on table `public.notifications`.
2. Event: **INSERT**.
3. Type: HTTP Request.
4. URL:
   `https://krqysdkbyhshwpfmimfw.supabase.co/functions/v1/notification-push`
5. Add HTTP header:
   - Name: `x-webhook-secret`
   - Value: the exact same value saved as `PUSH_WEBHOOK_SECRET`.
6. Save the webhook only after the Edge Function secrets have been saved.
7. Sign in on an Android test device and allow notifications. Trigger a notification and verify that it appears on the device.

The `notification-push` function intentionally has JWT verification disabled because the database webhook is not a user session. It has its own mandatory secret-header check. Never remove that check or expose the webhook secret.

## 6. LiveKit — required for voice rooms

1. Create a project in LiveKit Cloud.
2. Copy the project's WebSocket URL, API key and API secret.
3. Save them in Supabase **Edge Functions → Secrets** as:
   - `LIVEKIT_URL`
   - `LIVEKIT_API_KEY`
   - `LIVEKIT_API_SECRET`
4. Do not put the API secret in Flutter, Web, GitHub variables or the repository.
5. The app requests a short-lived voice-room token from the already-deployed authenticated function `create-livekit-token`.

This turns on the configured voice-room token path. Video calls and member screen-sharing still need additional application engineering and device/browser QA; creating a LiveKit project alone does not complete those modules.

## 7. Free Fire profile provider — optional until UID sync is needed

The current adapter calls the **Free Fire Community API**, an unofficial third-party data provider. It is not Garena and it does not prove ownership of a Free Fire account.

1. Review the provider's current documentation, terms, quotas and commercial-use permissions.
2. Create the provider account and obtain an API key only after confirming that the intended use is permitted.
3. Save the key as `FREEFIRE_API_KEY` in Supabase Edge Function Secrets.
4. Leave `FREEFIRE_API_BASE_URL` unset unless the provider gives a different supported base URL.
5. Test a valid UID and an invalid UID from the app.

The India-first default region sent by the app is `ind`. The current Edge Function accepts `ind`, `sg` and `br`. A UID lookup is labelled `linked_unverified`; do not call it official or owner-verified.

## 8. GitHub Actions and Web staging

The repository already has two successful build workflows for the current source: Flutter CI (Dart analysis, tests, Android release APK and Web build) and the Web staging build artifact. The actual Pages deploy job is gated and was skipped; enabling the build alone does not publish the site.

### A. Enable GitHub Pages

1. Open [the KOMNIVO repository](https://github.com/rahul-dev-web/KOMNIVO-app).
2. Open **Settings → Pages**.
3. Under **Build and deployment → Source**, choose **GitHub Actions**.

### B. Add repository Actions variables

Open **Settings → Secrets and variables → Actions → Variables** and add:

| Variable | Value |
| --- | --- |
| `SUPABASE_URL` | `https://krqysdkbyhshwpfmimfw.supabase.co` |
| `SUPABASE_PUBLISHABLE_KEY` | Active `sb_publishable_...` key copied from Supabase |
| `SUPABASE_REDIRECT_URL` | `https://rahul-dev-web.github.io/KOMNIVO-app/` |
| `FIREBASE_API_KEY` | Firebase app config value |
| `FIREBASE_APP_ID` | Firebase app config value |
| `FIREBASE_MESSAGING_SENDER_ID` | Firebase app config value |
| `FIREBASE_PROJECT_ID` | Firebase project ID |
| `FIREBASE_STORAGE_BUCKET` | Firebase app config value, if supplied |
| `FIREBASE_AUTH_DOMAIN` | Firebase app config value, if supplied |
| `FIREBASE_VAPID_KEY` | Only when Web push is implemented/configured |
| `ENABLE_GITHUB_PAGES` | `true` (this enables the deployment job) |

The Supabase publishable key and Firebase client identifiers are intended for client-side use. Do not store Google OAuth Client Secret, LiveKit API Secret, Free Fire API key, Firebase service-account JSON or the push webhook secret as Actions variables. Provider secrets belong in Supabase Edge Function Secrets.

### C. Deploy and verify

1. Push a commit to `main` or manually run **KOMNIVO Web Staging** from Actions.
2. Confirm the **build** and **deploy** jobs both succeed.
3. Open `https://rahul-dev-web.github.io/KOMNIVO-app/`.
4. Test Google OAuth, page refresh/deep links and authenticated data access.
5. If the Pages URL changes, update Supabase Auth Redirect URLs and Google Authorized JavaScript origins.

## 9. Local Android run command

From the repository root in PowerShell, after copying the active publishable key from Supabase:

```powershell
flutter pub get

flutter run -d <YOUR_ANDROID_DEVICE_ID> --dart-define=SUPABASE_URL=https://krqysdkbyhshwpfmimfw.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_REPLACE_WITH_YOUR_KEY --dart-define=SUPABASE_REDIRECT_URL=in.komnivo.app://login-callback
```

When Firebase is configured, add the Firebase client values as additional `--dart-define` arguments. The Android platform folders and native LiveOps bridge are generated/copied by:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\tool\bootstrap-platforms.ps1
```

The release APK currently builds in CI, but Play Store upload signing is not yet configured. Keep the upload keystore and passwords out of GitHub source and chat; configure signing through a secure local or GitHub Actions secret-based process before Play Store submission.

## 10. Current remaining checklist

- [ ] Copy the Supabase publishable key into local run/build values and GitHub Actions variable.
- [ ] Confirm `public` is exposed in Supabase Data API settings.
- [ ] Enable Google provider in Supabase and configure the Google OAuth Web Client.
- [ ] Add Firebase project/app configuration and FCM server credentials.
- [ ] Create the Supabase notification INSERT webhook with the matching private header.
- [ ] Create LiveKit Cloud project and save its three server secrets (when voice rooms are ready to test).
- [ ] Review/approve Free Fire provider terms and add its API key (when UID sync is ready to test).
- [ ] Enable GitHub Pages and set `ENABLE_GITHUB_PAGES=true`.
- [ ] Configure Android upload signing and Play Console/legal requirements before public release.

## 11. Security and implementation notes

- Never put Supabase secret/service-role keys, OAuth client secrets, LiveKit secrets, Firebase service-account JSON, provider API keys, keystores or webhook secrets into Flutter, public GitHub source, screenshots or chat.
- The database RLS policies are already enabled. Keep RLS enabled on every new table in an exposed schema and add minimum table/column/function grants deliberately.
- The security advisor reports one warning for `public.withdraw_event_registration(uuid)` because authenticated users may execute it as SECURITY DEFINER. The function checks that the caller is the registration captain or event staff and only allows allowed registration states; retain that authorization logic and review it again before production.
- Performance advisors report unindexed foreign keys and RLS/policy performance opportunities. These are tuning tasks for a later validation pass, not missing external API credentials.
- LiveOps screen capture requires an explicit Android system permission and uses on-device OCR. It does not use a cloud AI API, upload raw frames by default or control the Free Fire game client.

## 12. Official setup references

- Supabase Google OAuth: https://supabase.com/docs/guides/auth/social-sign-in/auth-google
- Supabase Auth redirect URLs: https://supabase.com/docs/guides/auth/redirect-urls
- Supabase Edge Function secrets: https://supabase.com/docs/guides/functions/secrets
- Supabase API grants and RLS: https://supabase.com/docs/guides/api/securing-your-api
- Firebase Flutter setup: https://firebase.google.com/docs/flutter/setup
- Firebase FCM server send: https://firebase.google.com/docs/cloud-messaging/send/admin-sdk
- LiveKit Cloud: https://cloud.livekit.io/
- GitHub Pages with Actions: https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site
