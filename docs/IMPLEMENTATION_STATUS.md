# KOMNIVO implementation status

This document separates what is present in the repository from what still depends on external providers or needs engineering/QA. It does not change the agreed full-product scope in Notion.

## Implemented in source

- Flutter app shell, dark responsive visual system, Google sign-in entry point and local preview.
- Community creation/discovery/join entry points and default channels.
- Direct/group conversation creation, persistent realtime text messages and LiveKit voice-room token flow.
- Player profile editing and server-side Free Fire UID lookup through a replaceable provider adapter.
- Team creation, member invitations and invitation acceptance.
- Event publishing, public event discovery, team registration, event details, match schedule and player match detail.
- Match-level check-in, time-released room credentials, evidence upload, opponent confirmation/dispute and player result submission.
- Organiser registration review, roster locking, balanced group allocation, match creation, room setup, dispute review, result approval and standings.
- Supabase schema, RLS policies, audit records, private evidence/media buckets and privileged tournament RPC implementations in the non-exposed `app_private` schema.
- Server-side Edge Functions for community actions, invitations, DMs/groups, team invitations, Free Fire lookup, check-in, result submission/approval, LiveKit token issuance and FCM webhook delivery.
- Android Kotlin MediaProjection bridge and one-frame-per-second starting-point local ML Kit text recognition. Extracted screen text is currently a local preview and is not uploaded as official match evidence.
- GitHub Actions workflows for Flutter analysis/test/build and Web staging artifact generation.

## Still dependent on owner setup

- A dedicated KOMNIVO Supabase project and application of migrations 001–009.
- Google Cloud OAuth Web Client creation and adding its ID/secret to Supabase Auth.
- Firebase project and Android app registration for FCM; server service-account JSON and webhook secret must be added to Edge Function secrets.
- LiveKit Cloud project and its URL/key/secret for voice rooms.
- Free Fire provider API key and confirmation of current terms, quotas and commercial-use permission. The integration is unofficial and is not affiliated with Garena.
- GitHub Pages enablement in repository settings and `ENABLE_GITHUB_PAGES=true` Actions variable.
- Android app signing credentials and Play Console configuration.

## Remaining product engineering before production launch

- Complete community features: threads, reactions and attachment presentation, message search, pins, mentions, read receipts/presence, notification preference UI, full moderation queue and member/role administration.
- Complete member-to-member media: video calls and member-initiated screen/stream sharing with correct Android permission, foreground-service, WebRTC and abuse/report controls.
- Complete tournament configuration breadth: custom game modes, all rule fields, AI-assisted rulebook/roadmap parsing with source citations, flexible rounds/brackets, schedule review, registration correction workflows, explicit substitutes and advanced qualification/tie-breaker policies.
- Complete result integrity UI: evidence preview, opponent confirmation details, full dispute decision workflow, correction history and result versioning.
- Complete LiveOps: screen-state classification, supported lobby/result templates, local roster matching, local candidate extraction, vibration and optional overlay; benchmark CPU, memory, battery and temperature on the Android 13 low-end pilot device.
- Add deeper automated tests for SQL/RLS and Edge Functions, security/advisor review, account deletion/retention paths, accessibility and device/browser testing.

## Important boundaries

- Google sign-in authenticates a KOMNIVO account; it does not prove the owner of a Free Fire UID.
- OCR and AI observations are provisional. Only authorised organiser review and server-side deterministic scoring can create official results.
- The host operates the game manually. No macros, simulated taps, hidden/private game APIs, reverse engineering or anti-cheat bypass are part of the design.
- Android 13 screen capture may include the full display, including visible notifications. Capture starts only after explicit user action and system consent; raw screen frames are not uploaded by default.
