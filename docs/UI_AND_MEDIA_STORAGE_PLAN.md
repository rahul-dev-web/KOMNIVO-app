# KOMNIVO UI and Media Storage Plan

Updated: 15 November 2026

## Product/UI decisions

- The application keeps a near-black base and uses the current KOMNIVO shield logo palette: violet and blue/cyan accents. Red is reserved for destructive/error/warning states; it is not a replacement for the current logo palette.
- The bottom navigation contains four core destinations: Team, Community, Inbox and Compete.
- The Home destination and its generic metrics/marketing dashboard have been removed.
- Community is the initial selected destination.
- The global Organizer Desk shortcut has been removed. Community owners/managers should enter organizer workflows from the community/event they actually manage, rather than from a global placeholder workspace.
- Community directory cards are compact horizontal server-style rows with a logo/avatar, name, short description, member count, membership/public state and a concise Join/Open action.

## Community logos

- Logo uploads are optional; users can create a community without a logo.
- Supported formats: JPG/JPEG, PNG and WebP.
- App-side limit: 2 MB per logo.
- Logos use the existing private `community-media` Storage bucket; no new bucket or Cloudflare account configuration is needed.
- Object path convention: `<uploader-user-id>/<community-id>/<unique-logo-filename>`.
- The community's `icon_url` field stores the object path.
- The app creates a one-hour signed URL for display. The bucket stays private.
- Storage RLS allows logo reads only when the object path equals the community's current `icon_url`, and the community is public or the viewer is a member/owner. Existing upload RLS continues requiring the uploader's own user-id folder.
- Unselected objects do not become publicly readable. Deleting/replacing older unreferenced uploads can be added with a retention cleanup policy later.

## Current Storage inventory

At the latest database check on 15 November 2026, the project had these private buckets and zero stored objects:

| Bucket | Purpose | Current configured file limit |
|---|---|---:|
| `community-media` | Message media and community logos | 10 MB |
| `match-evidence` | Match/result evidence | 10 MB |
| `ai-documents` | Organizer AI source documents | 25 MB |

The community logo uploader applies a stricter 2 MB limit. Current configured buckets are private. Supabase Storage currently has 0 objects in the project, so there is no observed media-size or bandwidth pressure that justifies migrating to a second storage vendor yet.

## Recommendation: stay on Supabase Storage for now

Supabase Storage is already connected to the app's Auth and RLS model. That matters particularly for match evidence and private Organizer AI documents, where access is user-, event- or community-scoped. Introducing a second provider now would require a separate upload path, presigned URL workflow, cleanup lifecycle, error handling and security tests without any current scale evidence.

Supabase's published quotas depend on the organisation's plan. The Free plan currently includes 1 GB file storage and 5 GB cached egress plus 5 GB general egress. Pro includes 100 GB file storage, 250 GB cached egress and 250 GB general egress; documented overage rates currently include $0.0213/GB storage, $0.03/GB cached egress and $0.09/GB general egress. Confirm the organisation's actual plan and usage in the Supabase dashboard before relying on a quota. Sources: [Supabase pricing](https://supabase.com/pricing), [Storage pricing](https://supabase.com/docs/guides/storage/pricing), [Bandwidth and egress](https://supabase.com/docs/guides/storage/serving/bandwidth).

## When Cloudflare R2 makes sense

R2 is worth adding when public images/videos or high-volume downloads create meaningful Supabase egress cost, or when the app needs a distinct media/archive tier. Cloudflare's published R2 Standard pricing currently includes 10 GB-month storage, 1 million Class A operations and 10 million Class B operations per month; paid Standard storage is $0.015/GB-month, Class A is $4.50/million and Class B is $0.36/million. Internet egress is free. Source: [Cloudflare R2 pricing](https://developers.cloudflare.com/r2/pricing/).

Recommended future split if that threshold is reached:

- Keep private AI documents and match/result evidence in Supabase Storage, retaining the current RLS policies.
- Move only suitable public/high-volume assets (community logos, public promotional images, public thumbnails and public video files) to R2.
- Store object metadata and ownership in Postgres; do not store binary files in database columns.
- Upload through a server-side Supabase Edge Function or Cloudflare Worker that issues short-lived presigned upload URLs. Never embed R2 access keys or secret keys in Flutter/Web builds.
- Use a storage adapter in the app so a future R2 rollout does not change community/event features.
- Add lifecycle cleanup, MIME/size validation, abuse controls, signed URL expiry and cross-provider tests before production migration.

## Decision for this release

Do not create an R2 bucket or add R2 secrets yet. Continue with Supabase Storage until actual object count, stored GB and monthly egress approach the current plan limits or cost becomes measurable. Review again after real community, chat and competition media usage starts.
