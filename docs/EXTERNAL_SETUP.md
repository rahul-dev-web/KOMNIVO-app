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
| Production Web URL | `https://komnivo-app.pages.dev/` (Cloudflare Pages production alias; deployment-specific URL: `https://4ee6d318.komnivo-app.pages.dev/`) |

The project is in Singapore because that is the region selected in the Supabase dashboard. Keep this project; there is no need to create another database solely to chase a Mumbai region option.

### Backend work already completed

- Fifteen database migrations are applied, including the Bio challenge, challenge-table RLS guard, three-attempt verification controls and in-flight challenge concurrency guard.
- Forty-four application tables exist in the `public` schema, and all forty-four have Row Level Security enabled.
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
| Push notifications | Firebase Cloud Messaging (FCM) directly from Supabase Edge Functions | Yes — Firebase client configuration plus a dedicated Google OAuth client and refresh token scoped to `firebase.messaging`; no downloaded service-account JSON key or Cloud Run billing |
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
2. In **Authentication → URL Configuration**, after the Cloudflare Pages first deploy, set the Site URL to the exact production URL, for example:
   `https://<cloudflare-project-name>.pages.dev/` (replace the placeholder with the actual assigned hostname).
3. Add these Redirect URLs:
   - `in.komnivo.app://login-callback` (Android — already tested successfully)
   - `https://<cloudflare-project-name>.pages.dev/` (Cloudflare Pages Web — replace with the actual assigned hostname)
   - The exact local development URL only if local Web OAuth testing is needed.
4. Do not use a GitHub Pages URL. The Cloudflare dashboard confirms the Production environment and lists `komnivo-app.pages.dev` as the project domain. The hash-prefixed URL `https://4ee6d318.komnivo-app.pages.dev/` is the deployment-specific URL; use the stable `https://komnivo-app.pages.dev/` production alias for auth redirects.

The database, RLS, private Storage buckets and messages Realtime publication have already been created. Do not rerun the original ten migrations on this project.

### C. Edge Function secrets

Open **Edge Functions → Secrets** and add the entries below. Supabase reserves the `SUPABASE_` prefix and injects its own project variables automatically; do not create your own `SUPABASE_SERVICE_ROLE_KEY` secret.

| Secret name | Required when | Value source |
| --- | --- | --- |
| `PUSH_WEBHOOK_SECRET` | Push delivery | Generate a long random value (at least 32 random bytes) |
| `FCM_SENDER_URL` | Push delivery | HTTPS base URL of the deployed Cloud Run sender |
| `FCM_SENDER_SECRET` | Push delivery | Random high-entropy shared secret also stored in Cloud Run Secret Manager |

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
   - `https://komnivo-app.pages.dev`
   - `http://localhost:<your-port>` only while testing locally.
5. Under **Authorized redirect URIs**, add this exact Supabase callback:
   `https://krqysdkbyhshwpfmimfw.supabase.co/auth/v1/callback`
6. Create the client and copy the **Client ID** and **Client Secret**.
7. In Supabase, open **Authentication → Sign In / Providers → Google**, enable Google, and paste the Client ID and Client Secret.
8. Save and test sign-in from an Android build after the Android redirect URI has been allow-listed in Supabase.

Do not paste the Google Client Secret into Flutter, `.env.example`, GitHub source, or GitHub Actions variables. The Google callback above is different from the Android app return URI `in.komnivo.app://login-callback`.

## 5. Firebase Cloud Messaging — required for Android and browser Web Push

### A. Create and register the Firebase app

1. Open Firebase Console and create a dedicated Firebase project named **KOMNIVO**.
2. Add an **Android app** with package name `in.komnivo.app`.
3. The Firebase **Web app** has been registered. Its public Web app configuration and the Web Push VAPID public key must be supplied to the Cloudflare Pages build environment to enable browser push.
4. Open **Project settings → General → Your apps** and copy the client configuration values:
   - `FIREBASE_API_KEY`
   - `FIREBASE_APP_ID`
   - `FIREBASE_MESSAGING_SENDER_ID`
   - `FIREBASE_PROJECT_ID`
   - `FIREBASE_STORAGE_BUCKET` (if provided)
   - `FIREBASE_AUTH_DOMAIN` (if provided)
   - `FIREBASE_VAPID_KEY` (only for Web push)
5. These Firebase client identifiers and the VAPID public key are public browser configuration, supplied to Flutter with `--dart-define` and injected into the browser messaging service worker at build time. They are not Firebase server credentials. Never place a service-account JSON/private key in the web build.

### B. Direct server-side FCM from Supabase (no Cloud Run, no service-account JSON)

The Google Cloud organization policy blocks service-account key creation, and Cloud Run asks for a billing account. KOMNIVO therefore sends FCM HTTP v1 directly from the existing Supabase Edge Function by using a Google OAuth **user refresh token** with only the `https://www.googleapis.com/auth/firebase.messaging` scope. This is a practical no-billing workaround for this small deployment, but it is not the ideal long-term production identity model: sending is tied to the Google user whose OAuth consent is stored in Supabase. Revoke that OAuth grant in the Google Account if it must be disabled.

1. Confirm **Firebase Cloud Messaging API (HTTP v1)** is enabled. This is already enabled for project `komnivo-app`.
2. In Google Cloud Console → **Google Auth Platform → Clients**, create a separate OAuth Client ID of type **Desktop app** for the server-side FCM sender. Do not reuse the public Android/Web app configuration.
3. In **Google Auth Platform → Data Access**, add only this scope: `https://www.googleapis.com/auth/firebase.messaging`. The Google account used for authorization must have the `cloudmessaging.messages.create` permission on project `komnivo-app`; `Firebase Cloud Messaging API Admin` (`roles/firebasecloudmessaging.admin`) is sufficient. Use an account that has this role.
4. For ongoing use, the OAuth app must not remain in External **Testing** mode: Google expires refresh tokens after 7 days for external apps in Testing mode when non-basic scopes are requested. Set the app to **In production** and complete whatever verification Google requires for this scope. An unverified-app warning may be shown during consent.
5. Install Google Cloud CLI on a trusted Windows machine. Run `gcloud auth application-default login --client-id-file="C:\\path\\to\\desktop-oauth-client.json" --scopes="https://www.googleapis.com/auth/firebase.messaging" --disable-quota-project`. Sign in as the Google account that has the FCM IAM role and approve the FCM messaging scope.
6. The ADC credentials file is saved at `%APPDATA%\\gcloud\\application_default_credentials.json`. It contains a long-lived `refresh_token`, `client_id`, and `client_secret`. Keep that file private and never upload it to GitHub or send it in chat.
7. In Supabase **Edge Functions → Secrets**, add the following values from that local ADC JSON file:
   - `GOOGLE_OAUTH_CLIENT_ID` = `client_id`
   - `GOOGLE_OAUTH_CLIENT_SECRET` = `client_secret`
   - `GOOGLE_OAUTH_REFRESH_TOKEN` = `refresh_token`
   - `FIREBASE_PROJECT_ID` = `komnivo-app`
   - `PUSH_WEBHOOK_SECRET` = a separate random value of at least 32 random bytes
8. The deployed `notification-push` Edge Function refreshes a short-lived Google access token when needed and calls `https://fcm.googleapis.com/v1/projects/komnivo-app/messages:send` directly. It caches the short-lived access token in memory per Edge Function isolate and never logs the OAuth credentials or device tokens.

Do not put any Google OAuth client secret or refresh token in Flutter, GitHub source, Cloudflare Pages variables, screenshots, or chat. The old `komnivo-fcm-sender` service account created during the earlier attempt is not used by this direct OAuth route; it can be kept unused for now.



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

### D. OAuth consent-screen branding and public policy URLs

The public KOMNIVO information pages are maintained in `native/web/about`, `native/web/privacy` and `native/web/terms`. The platform bootstrap scripts copy them into the Flutter Web output so Cloudflare Pages can serve them as static pages.

Use these values in Google Auth Platform → Branding after the Cloudflare deployment containing these files is successful:

| Field | Value |
| --- | --- |
| App name | `KOMNIVO` |
| User support email | `jarahul989@gmail.com` |
| Application home page | `https://komnivo-app.pages.dev/about/` |
| Privacy policy | `https://komnivo-app.pages.dev/privacy/` |
| Terms of service | `https://komnivo-app.pages.dev/terms/` |
| Authorized domain candidate | `komnivo-app.pages.dev` |

The 120 × 120 PNG app icon is supplied separately as `komnivo-logo-120.png`. Do not upload the SVG directly where the console requires PNG/JPG/BMP.

**Important domain ownership check:** Google requires the homepage and policy pages to be on a domain you own and can verify in Search Console. `pages.dev` is a Cloudflare-provided shared domain, not a custom domain registered by the project owner. We can try a URL-prefix Search Console verification for `https://komnivo-app.pages.dev/`, but Google may reject the shared-host domain for OAuth verification. The durable production solution is to connect a custom domain you control, then update all three URLs and the Authorized domain to that domain before submitting branding/scope verification. Do not claim that domain ownership is verified until Search Console confirms it.

The homepage must be publicly accessible without logging in and must explain what KOMNIVO does; do not use the sign-in-only app screen as the homepage. The privacy policy and terms pages must match the same origin as the homepage.

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

## 8. Cloudflare Pages Web deployment

GitHub remains the source-code repository; **Cloudflare Pages is the selected Web host**. Do not enable GitHub Pages for this project.

### A. Repository and build configuration

The repository contains `tool/cloudflare-build.sh`. Cloudflare Pages' standard build image does not list Flutter as a preinstalled SDK, so this script downloads the pinned Flutter 3.44.8 Linux SDK from Google's official Flutter release archive, verifies its SHA-256 checksum, generates the ignored Flutter Android/Web scaffolding, resolves Dart packages and builds the release Web bundle.

1. In the Cloudflare dashboard, open **Workers & Pages → Create application → Pages → Connect to Git**.
2. Connect GitHub and select `rahul-dev-web/KOMNIVO-app`. Grant access only to this repository if GitHub's authorization screen offers that scope.
3. Set the production branch to `main`.
4. Choose **None / No framework preset** if asked for a framework preset.
5. Use these build settings:
   - Root directory: `/` (repository root; leave the default if blank means root)
   - Build command: `bash tool/cloudflare-build.sh`
   - Build output directory: `build/web`
6. Add these build environment variables for Production:
   - `SUPABASE_URL` = `https://krqysdkbyhshwpfmimfw.supabase.co`
   - `SUPABASE_PUBLISHABLE_KEY` = the active `sb_publishable_...` key from Supabase Project Settings → API Keys.
7. Add these Firebase Web client values as Cloudflare Pages Production build variables:
   - `FIREBASE_API_KEY` = the Web app `apiKey`
   - `FIREBASE_APP_ID` = the Web app `appId`
   - `FIREBASE_AUTH_DOMAIN` = the Web app `authDomain`
   - `FIREBASE_MESSAGING_SENDER_ID` = the Web app `messagingSenderId`
   - `FIREBASE_PROJECT_ID` = `komnivo-app`
   - `FIREBASE_STORAGE_BUCKET` = the Web app `storageBucket` value (if provided)
   - `FIREBASE_VAPID_KEY` = the **public** Web Push certificate key from Firebase Cloud Messaging settings
8. Add the same Firebase values to Preview only if you intend to test push on Preview deployments. After saving the variables, trigger a new Cloudflare Pages deployment. The build script passes these values as Dart defines and injects the public Firebase config into `web/firebase-cloud-messaging-push-scope/firebase-messaging-sw.js`.
9. Do not add a Supabase `service_role` key, Google OAuth Client Secret, LiveKit API secret, Firebase service-account JSON/private key, Free Fire provider key or webhook secret to Cloudflare Pages. The Firebase Web app config and VAPID public key are intentionally public client values; all server credentials remain in Supabase Edge Function Secrets.

The Web release output is `build/web`; Flutter's Web build places its `index.html` and assets there. The script currently pins Flutter 3.44.8 to match the locally tested developer environment.

### B. First deploy and record the hostname

1. Select **Save and Deploy**.
2. Wait for the first build and deployment to finish. If it fails, capture the failed build log; do not change several settings at once.
3. Copy the exact production hostname Cloudflare assigns, in the form `https://komnivo-app.pages.dev/`. The project name may need to be adjusted if that hostname is already taken.
4. Open the URL on desktop Chrome and verify the KOMNIVO sign-in/preview screen loads.

### C. Finish Web Google OAuth after deployment

Only after the real `pages.dev` hostname is known:

1. In Supabase **Authentication → URL Configuration**, set Site URL to the exact production origin with trailing slash and add that same URL to Redirect URLs. Keep `in.komnivo.app://login-callback` for Android.
2. In Google Cloud **Google Auth Platform → Clients → your Web client → Authorized JavaScript origins**, add the exact Cloudflare production origin without a path (for example, `https://komnivo-app.pages.dev`).
3. Keep the Supabase callback URI unchanged:
   `https://krqysdkbyhshwpfmimfw.supabase.co/auth/v1/callback`.
4. Test Google OAuth on desktop Web and then iPhone Safari only after both allowlists are saved. The browser Web redirect is derived from the deployed Web origin by the Flutter app.

Cloudflare references:
- Git integration: https://developers.cloudflare.com/pages/get-started/git-integration/
- Build configuration: https://developers.cloudflare.com/pages/configuration/build-configuration/
- Build image: https://developers.cloudflare.com/pages/configuration/build-image/

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
- [x] Register Firebase Android/Web apps, configure direct FCM HTTP v1 credentials and the Supabase notifications INSERT webhook; Android, Desktop Chrome and iPhone Home Screen push have been device-tested.
- [ ] Create the Supabase notification INSERT webhook with the matching private header.
- [ ] Create LiveKit Cloud project and save its three server secrets (when voice rooms are ready to test).
- [ ] Confirm the Free Fire provider key and provider terms/quotas. Run the real India Bio round-trip test after confirming the key is active.
- [x] Connect `rahul-dev-web/KOMNIVO-app` to Cloudflare Pages; production is deployed at `https://komnivo-app.pages.dev/`. Remaining: custom domain and Google Search Console/OAuth branding verification.
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
- Cloudflare Pages Git integration: https://developers.cloudflare.com/pages/get-started/git-integration/


## Free Fire Bio-code ownership verification

The previous 48-player solo-room Support workflow is retired. The Free Fire API response supplied during implementation confirms that the profile Bio is returned at \`socialInfo.signature\` (not in \`basicInfo\`). The Edge Function reads that exact nested field.

1. The player enters a 5–15 digit UID and taps Generate verification code. KOMNIVO stores the UID/challenge in Supabase and returns a 128-bit \`KOMNIVO-...\` code. This step makes **zero Free Fire provider API requests**.
2. The player replaces the entire Free Fire India Bio with only the code, saves it, returns to KOMNIVO and checks the confirmation box.
3. Tapping Verify makes exactly one Free Fire \`/info\` request. The same response supplies \`basicInfo\` (nickname, level, likes, rank, region), \`clanBasicInfo\`, \`profileInfo\`, and \`socialInfo.signature\`. No separate \`/stats\` request is made in this flow.
4. The server hashes the exact \`socialInfo.signature\` string without trimming or normalising and compares it to the challenge hash. Only an exact match marks the linked account Verified. The player may restore their old Bio immediately afterwards.
5. The challenge expires after 30 minutes. Verification attempts are enforced by an atomic Postgres counter on the linked game account: maximum **three provider requests per profile**, including after code regeneration, and at least 15 seconds between requests. A fourth request is blocked and the player is told to contact KOMNIVO Support.
6. The challenge code is returned to the owner by the authenticated Edge Function and only its SHA-256 hash is stored. Raw Bio/signature is stripped from saved profile snapshots. The challenge table is unavailable to \`anon\` and \`authenticated\`; only the server-side Edge Function can access it.

Live backend state: migrations \`202611130001\` through \`202611130004\` are applied; \`sync-freefire-profile\` v9 is ACTIVE with JWT verification. The database reserves attempts atomically, permits at most three provider requests per linked profile, enforces a 15-second retry interval, and prevents a replacement code while a provider request is in flight. A real Free Fire India Bio round-trip remains the final integration test. The corresponding migrations and code live in the GitHub repository.
