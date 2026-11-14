import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json, readBearer } from "../_shared/http.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authorization = readBearer(req);
  if (!authorization) return json({ error: "Authentication required" }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return json({ error: "Proposal approval backend is not configured." }, 503);

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return json({ error: "Invalid or expired session." }, 401);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "Request body must be valid JSON." }, 400); }
  const proposalId = typeof body.proposal_id === "string" ? body.proposal_id.trim() : "";
  const decision = typeof body.decision === "string" ? body.decision.trim() : "";
  if (!proposalId || !["approve", "reject"].includes(decision)) {
    return json({ error: "proposal_id and decision (approve/reject) are required." }, 400);
  }

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: proposal, error: proposalError } = await admin.from("ai_proposals")
    .select("id,owner_user_id,conversation_id,action_type,status,expires_at")
    .eq("id", proposalId)
    .eq("owner_user_id", user.id)
    .maybeSingle();
  if (proposalError || !proposal) return json({ error: "Proposal not found." }, 404);
  if (proposal.action_type !== "create_event_draft") return json({ error: "Unsupported proposal action." }, 400);
  if (proposal.status !== "pending_approval") {
    // Let the database return an idempotent success for an already-completed proposal.
    if (proposal.status === "executed" && decision === "approve") {
      const { data: prior } = await admin.from("ai_actions").select("result")
        .eq("idempotency_key", `ai-proposal:${proposalId}`)
        .eq("owner_user_id", user.id).eq("status", "succeeded").maybeSingle();
      if (prior?.result) return json({ ...prior.result, already_executed: true });
    }
    return json({ error: `Proposal is ${proposal.status}, not awaiting approval.` }, 409);
  }

  const expiresAt = proposal.expires_at ? Date.parse(String(proposal.expires_at)) : null;
  if (expiresAt !== null && Number.isFinite(expiresAt) && expiresAt <= Date.now()) {
    await admin.from("ai_proposals").update({ status: "expired" })
      .eq("id", proposalId).eq("owner_user_id", user.id).eq("status", "pending_approval");
    return json({ error: "This proposal expired. Ask Organizer AI to prepare a new one.", code: "PROPOSAL_EXPIRED" }, 409);
  }

  const { data: result, error } = await admin.rpc("resolve_organizer_ai_proposal", {
    p_proposal_id: proposalId,
    p_user_id: user.id,
    p_decision: decision,
  });
  if (error) {
    const raw = String(error.message ?? "");
    const code = raw.includes("expired") ? "PROPOSAL_EXPIRED"
      : raw.includes("permission") || raw.includes("organizer") ? "PERMISSION_CHANGED"
      : raw.includes("not awaiting") ? "PROPOSAL_NOT_PENDING"
      : "PROPOSAL_RESOLUTION_FAILED";
    const status = code === "PROPOSAL_EXPIRED" || code === "PROPOSAL_NOT_PENDING" ? 409
      : code === "PERMISSION_CHANGED" ? 403 : 400;
    return json({
      error: code === "PROPOSAL_EXPIRED" ? "This proposal expired. Ask Organizer AI to prepare a new one."
        : code === "PERMISSION_CHANGED" ? "Your organiser permissions changed. This proposal cannot be approved."
        : "Proposal could not be resolved. Refresh the event and try again.",
      code,
    }, status);
  }

  return json({
    ...((result && typeof result === "object") ? result as Record<string, unknown> : { result }),
    decision,
    confirmed_by: user.id,
    published: false,
  });
});
