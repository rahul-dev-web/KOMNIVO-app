# Targeted @username Mentions

KOMNIVO uses targeted `@username` mentions inside the existing channel composer. There is no Tags channel, no role broadcast, and no generic community-wide fallback for a mention.

## Recipient discovery and scope

When the sender types `@...`, the client calls `channel_mention_candidates(channel_id, query)`. The server checks the sender's ability to post and the channel's `allow_user_mentions` setting, then returns only users who can currently view that exact channel. The candidate response contains a user ID plus username/display name/avatar for UI display.

Eligibility is checked server-side by channel type:

- Public/private community channels use current membership, active bans, channel/category permission overrides, and private channel membership/privileged roles.
- DMs require the target to be a member of that exact DM channel.
- Event root channels use event visibility/registration/staff scope; private root channels are organiser/event-staff only.
- Stage channels use the exact stage, stage participants and staff assignments; private stages restrict recipients to their teams and scoped staff.
- Group channels use the exact group roster and scoped staff. A private group never inherits access from another team merely because the event is published.
- Match channels use the exact Match roster, host and event/stage/group/match staff roles.

A manually typed username is checked again when the message is inserted. Unknown usernames, recipients who cannot access that channel, and mentions in a channel with mentions disabled reject the message transaction. `@everyone` and `@here` are never converted into targeted recipient rows by this feature.

## Snapshot, notification and correction

The message insert trigger parses the body and writes one `message_mentions` snapshot per (message, recipient). It stores the username/display name at mention time and a notification reference. The recipient and sender can read the snapshot; clients cannot insert or edit mention records directly.

A targeted mention creates a `notifications.kind = 'mention'` notification. The regular channel-message notification query excludes users who received an active targeted mention, avoiding a duplicate generic message notification for the same message. There is no broadcast fallback.

When the message is edited/deleted, or the recipient loses channel access, the snapshot is marked removed and a `mention_correction` notification is created. That correction uses the existing `mention_push` preference. Re-adding the same mention later is represented by the same recipient snapshot becoming active again; the original snapshot record is not silently discarded.

## Push delivery

The `notification-push` Edge Function is ACTIVE at version 12 and retains its existing webhook-secret authentication (`verify_jwt=false)). Per device, it records accepted/retryable/permanent outcomes in the service-role-only `notification_delivery_attempts` table and retries transient FCM failures up to three attempts. The ledger stores a device-token row ID, never the raw token or provider response body. A later webhook invocation skips devices with an accepted attempt.

Delivery is bounded at-least-once, not a strict exactly-once guarantee: concurrent webhook deliveries can still race before the first accepted attempt is recorded. A permanent invalid-device response removes that registered device token. Manual retry/queue scheduling beyond the current webhook invocation is not yet implemented.

## Validation and remaining release checks

- Clean Supabase install and pgTAP/RLS regression suite passed on the 21 November main revision that included the mention and delivery-ledger tests.
- Live schema has the mention RPC/table and delivery-attempt table applied.
- Flutter Dart analysis and test suite passed after adding the client composer picker; current Android APK build is being retried with a regional Maven Central mirror because the runner received HTTP 403 from the default Maven Central endpoint.
- No signed-in multi-user device test has yet sent a mention, edited/deleted that message, checked each device's FCM delivery, or exercised the recipient's correction notice. No real event/group/match fixture exists in the live project.

Do not mark the mention or notification release gate complete until the signed-in multi-user channel/event tests and real device push tests pass.
