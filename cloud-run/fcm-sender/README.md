# KOMNIVO keyless FCM sender

This service sends one Firebase Cloud Messaging HTTP v1 notification per request.
It is designed to run on Google Cloud Run with the user-managed runtime service
identity `komnivo-fcm-sender@komnivo-app.iam.gserviceaccount.com`.

## Security model

- No service-account JSON key is used.
- Cloud Run Application Default Credentials authenticate as the assigned runtime
  service account.
- The Cloud Run endpoint is reachable over HTTPS and requires the high-entropy
  `FCM_SENDER_SECRET` header value on every `POST /send` request.
- Store the same random secret in Cloud Run Secret Manager and Supabase Edge
  Function Secrets. Never commit it.
- The caller must be the existing Supabase `notification-push` Edge Function,
  which already validates its separate `PUSH_WEBHOOK_SECRET` header.
- The endpoint never logs notification bodies, device tokens, access tokens or
  secret values.

## Runtime configuration

- Node.js 22 or newer
- `FIREBASE_PROJECT_ID=komnivo-app`
- `FCM_SENDER_SECRET`: injected from Secret Manager
- Runtime service identity:
  `komnivo-fcm-sender@komnivo-app.iam.gserviceaccount.com`
- The runtime service identity must have
  `roles/firebasecloudmessaging.admin` on the Firebase project.

## HTTP contract

`GET /healthz` returns a non-sensitive health response.

`POST /send` requires the `x-fcm-sender-secret` header and JSON body:

```json
{
  "token": "<device registration token>",
  "notification": {
    "title": "KOMNIVO",
    "body": "Your notification text"
  },
  "data": {
    "kind": "general",
    "entity_type": "",
    "entity_id": "",
    "notification_id": ""
  }
}
```

The response contains only delivery status and the FCM message resource name.
