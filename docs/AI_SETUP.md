# KOMNIVO AI — External Provider Setup and Testing

Last updated: 14 November 2026

This guide configures the free-first AI foundation already added to the KOMNIVO repository and connected Supabase project.

## Selected provider configuration

| Purpose | Provider | Model | When used |
| --- | --- | --- | --- |
| Primary | Cloudflare Workers AI | `@cf/qwen/qwen3.8-27b` | Initial development/testing and first production candidate |
| Alternative/fallback | GroqCloud | `qwen/qwen3.8-27b` | Fallback when the primary returns a retryable quota/server error, or selectable as primary |
| Provider routing | Supabase Edge Function | `komnivo-ai` | Keeps provider keys out of Flutter/Web clients |

Cloudflare Workers Free includes 10,000 Neurons/day. Neurons measure GPU compute, not a fixed token count; actual requests per day depend on prompt/output size and model usage. The allowance resets at 00:00 UTC. Once the Free allocation is exhausted, requests fail until the reset. Workers Paid is required to go beyond that allowance; usage above the free 10,000/day is priced at $0.011 per 1,000 Neurons. Do not enable paid billing for initial tests. The selected Qwen model's published list price is $0.45 per million input tokens and $3.20 per million output tokens.

## 1. Cloudflare Workers AI — primary provider

1. Sign in to the Cloudflare account already hosting the KOMNIVO Pages project.
2. Open **Workers & Pages → AI → Workers AI** (the dashboard menu label may vary).
3. Open the Workers AI Playground and select **Qwen 3.8 27B**. The model ID must be exactly:
   `@cf/qwen/qwen3.8-27b`
4. Send a harmless test prompt in the Playground. This is only a model smoke test; it does not connect KOMNIVO.
5. Open the Cloudflare account overview for the same account that owns the `komnivo-app` Pages project and copy its **Account ID**. Do not use the Pages project name or a Zone ID.
6. In **My Profile → API Tokens → Create Token → Create Custom Token**, name it `KOMNIVO Workers AI Read`.
7. Under Permissions choose **Account → Workers AI → Read** (the permission name is `Workers AI Read` in Cloudflare's token permission list). Under Account Resources choose **Include → Specific account → Jarahul989@gmail.com's Account** only. Do not grant Zone, DNS, Workers deployment or account administration permissions.
8. Create the token and copy it immediately. Cloudflare may not show the secret again.
8. Keep both values private:
   - Account ID → `CLOUDFLARE_ACCOUNT_ID`
   - API token → `CLOUDFLARE_API_TOKEN`

The deployed Edge Function calls Cloudflare's OpenAI-compatible Chat Completions endpoint:
`https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/ai/v1/chat/completions`

The code's default model is `@cf/qwen/qwen3.8-27b`. It supports text, image/vision input, reasoning and function calling, but the current KOMNIVO chat endpoint only uses text chat; file ingestion and action tools are not yet enabled.

Official docs:
- https://developers.cloudflare.com/workers-ai/models/qwen3.8-27b/
- https://developers.cloudflare.com/workers-ai/configuration/open-ai-compatibility/
- https://developers.cloudflare.com/workers-ai/platform/pricing/

## 2. GroqCloud — alternative provider

This is optional. Configure it only if you want a second provider ready for fallback testing.

1. Open https://console.groq.com/ and sign in.
2. Open **API Keys** and create a key for KOMNIVO development.
3. Copy it once and store it securely as `GROQ_API_KEY`.
4. The default model ID is `qwen/qwen3.8-27b`; keep `GROQ_MODEL` set to that value unless the Groq console/docs show it has been retired.
5. Leave `AI_PROVIDER=cloudflare` to keep Cloudflare primary and Groq as fallback. Set `AI_PROVIDER=groq` only when deliberately testing Groq as primary.

Groq free-plan rate limits vary by model and organisation. Check the live **Rate Limits** panel in the Groq console; do not assume a permanent requests-per-day number. If only one provider is configured, the gateway uses it even if the other is selected as primary. With both configured, the code falls back only on retryable HTTP 429/5xx failures, not on invalid credentials or malformed requests.

Official docs:
- https://console.groq.com/docs/vision
- https://console.groq.com/docs/tool-use/overview
- https://console.groq.com/docs/openai
- https://console.groq.com/docs/your-data

## Provider smoke test — pending owner token

The model identifier and OpenAI-compatible endpoint are confirmed in Cloudflare's current documentation. The dedicated least-privilege API token has not yet been created, so a live request from KOMNIVO's Supabase Edge Function has not been verified. Complete the token step above, store it in Supabase, then run the app smoke test below. Do not treat the provider as connected before that test passes.

## 3. Add secrets to Supabase — required before chat can respond

Project:
- Name: `KOMNIVO-app`
- Ref: `krqysdkbyhshwpfmimfw`
- Dashboard: https://supabase.com/dashboard/project/krqysdkbyhshwpfmimfw

### Dashboard method

1. Open **Edge Functions → Secrets**.
2. Add these entries (use the actual values from Cloudflare; never paste them into GitHub or this document):

| Secret | Value |
| --- | --- |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare Account ID shown on the account overview |
| `CLOUDFLARE_API_TOKEN` | Cloudflare token with Workers AI: Read |
| `CLOUDFLARE_MODEL` | `@cf/qwen/qwen3.8-27b` |
| `AI_PROVIDER` | `cloudflare` |
| `AI_DAILY_REQUEST_LIMIT` | `25` |

3. If also configuring Groq, add:
   - `GROQ_API_KEY` = your Groq API key
   - `GROQ_MODEL` = `qwen/qwen3.8-27b`
4. Save. Supabase Edge Function secrets become available to deployed functions without a redeploy.
5. Never create a custom secret beginning with `SUPABASE_`; Supabase reserves that prefix.

### Windows PowerShell / Supabase CLI alternative

From the repository root, create a local secrets file:

```powershell
@'
CLOUDFLARE_ACCOUNT_ID=PASTE_ACCOUNT_ID_FROM_CLOUDFLARE_DASHBOARD
CLOUDFLARE_API_TOKEN=PASTE_TOKEN_HERE
CLOUDFLARE_MODEL=@cf/qwen/qwen3.8-27b
AI_PROVIDER=cloudflare
AI_DAILY_REQUEST_LIMIT=25
'@ | Set-Content -Encoding ascii .env.ai.tmp
```

Push it to the correct project:

```powershell
supabase secrets set --project-ref krqysdkbyhshwpfmimfw --env-file .env.ai.tmp
Remove-Item .env.ai.tmp
```

If the CLI asks you to log in or link the project, follow the Supabase CLI prompts. Do not commit the temporary file. The repository ignores `.env*`; still delete the temporary file after upload.

For Groq, add its values using the Dashboard, or create a temporary ignored file with `GROQ_API_KEY` and `GROQ_MODEL` and push it the same way.

## 4. What is already deployed

- Supabase migrations `202611140001_organizer_ai_foundation` and `202611140002_ai_fk_indexes` create:
  - `ai_conversations`, `ai_messages`
  - `ai_documents`
  - `ai_proposals`, `ai_runs`, `ai_actions`
  - `ai_usage_ledger`, `ai_policy`
- RLS is enabled on every AI table. The live database check confirms all eight AI tables have RLS enabled and scoped policies.
- Migrations `202611140003_atomic_ai_daily_budget`, `202611140004_player_ai_public_event_scope` and `202611140005_fix_player_ai_scope_helper` add an atomic private UTC-day request counter and enforce public/private event visibility for Player AI.
- Edge Function `komnivo-ai` version 6 is ACTIVE with JWT verification. It includes scoped event context and safe chat history.
- Organizer scope is limited to the event organiser or community owner/admin/organiser. Moderators are not granted Organizer AI access by default.
- Player event context is limited to a player's own registration/roster; community context requires membership.
- Edge Function `komnivo-ai` is deployed with JWT verification enabled.
- Flutter has event-scoped Organizer AI and Player AI entry points on their respective event cards, plus a Player AI app-bar entry point. Recent conversations restore by scope; starting a new chat preserves earlier conversations.
- Organizer AI receives an event-scoped snapshot of rules, scoring, registration summaries, matches and standings. Player AI receives only the signed-in player's own registration/team/match/check-in details. Public events can be discussed before registration; private events remain member/participant scoped.
- The Flutter chat restores the latest active conversation for the same scope and supports starting a new chat.
- The endpoint remains read-only. It does not call event/channel/role/registration/scoring tools.
- Per-user daily request caps are reserved atomically in a private database counter through a service-role-only RPC. Parallel requests cannot bypass the default 25-attempt UTC-day cap.

## 5. Smoke test

After setting Cloudflare secrets:

1. Sign in to KOMNIVO with an account that is the organiser of an existing event.
2. Open **Organiser workspace → Your events → AI sparkle icon**.
3. Ask: `Mere tournament ke liye 48 teams aur 4 groups ka setup plan batao. Missing details bhi identify karo.`
4. Confirm the response is in Hindi/Hinglish and that it does not claim to have created or changed the event.
5. Ask a normal player question through the Player AI icon.
6. Check Supabase tables `ai_conversations`, `ai_messages`, `ai_runs` and `ai_usage_ledger`. Verify the rows belong to the signed-in user and the correct event scope.
7. Test with a non-organiser account against an event-scoped Organizer AI session; it must receive HTTP 403.
8. Test without provider secrets; the function should return `AI_PROVIDER_NOT_CONFIGURED` / HTTP 503, not expose secrets.
9. Test the daily cap; default is 25 model attempts per user per UTC day. Set `AI_DAILY_REQUEST_LIMIT` to a lower number for a controlled test.

## 6. Current implementation boundary — important

This deployment is the secure AI foundation and initial chat surface, not the complete Organizer AI operating system yet.

Not implemented in this first code slice:
- PDF/DOCX/XLSX/CSV/image upload and source-linked extraction.
- Document chunking, retrieval and version comparison.
- Tool/function calling with typed action schemas.
- Approval UI and execution of channel/role/permission/event/registration/scrim operations.
- Deterministic points-table ingestion, validation and standings publication.
- Recurring scrim scheduling and notification automation.
- Additional player-context workflows outside an explicitly opened event scope (for example, cross-event upcoming schedule and notifications).
- Provider benchmark/evaluation harness and token/Neuron telemetry beyond provider-reported token counts.

These remain required product scope. Do not mark the AI system complete until those workflows are implemented and tested. The first chat endpoint deliberately refuses to claim that it can execute those operations.

## 7. Security rules

- Never put Cloudflare/Groq keys in Flutter, Web build variables, GitHub Actions, source files, screenshots, Notion or chat.
- Keep provider secrets only in Supabase Edge Function Secrets.
- Use synthetic data while testing prompts and uploaded rulebooks.
- Do not paste passwords, personal phone numbers or private roster exports into the AI chat.
- The LLM is not the source of truth for permissions, scores, qualification or event state.
- Any future write tool must re-check the signed-in actor's authority on the server, validate its JSON schema and business rules, require approval where configured, use an idempotency key and write an audit record.

## 8. Cost controls

- Start with `AI_DAILY_REQUEST_LIMIT=25` per user. The counter is atomic per user and UTC day; Cloudflare's 10,000 Neurons/day is a separate account quota.
- Do not enable Cloudflare Workers Paid or preload credits during initial testing.
- Review Cloudflare Neuron usage and Groq rate-limit metrics after test sessions.
- Before production, set community/event budgets, alerts, max prompt/output sizes and a paid-provider fallback policy.
- Re-check provider prices and data terms at the time paid billing is activated.
