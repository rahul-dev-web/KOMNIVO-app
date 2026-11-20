import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json, readBearer } from "../_shared/http.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authorization = readBearer(req);
  if (!authorization) return json({ error: "Authentication required" }, 401);
  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const client = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const { data: { user }, error: authError } = await client.auth.getUser();
  if (authError || !user) return json({ error: "Invalid session" }, 401);

  try {
    const body = await req.json();
    const communityId = String(body.community_id ?? "");
    if (!communityId) return json({ error: "community_id is required" }, 400);

    const { data: allowed, error: permissionError } = await client.rpc("has_permission", {
      p_permission_key: "community.manage_invites",
      p_scope_type: "community",
      p_scope_id: communityId,
      p_related_id: null,
      p_resource_id: null,
    });
    if (permissionError || allowed !== true) {
      return json({ error: "You do not have permission to create invites for this community." }, 403);
    }

    const tokenBytes = crypto.getRandomValues(new Uint8Array(24));
    const token = Array.from(tokenBytes).map((b) => b.toString(16).padStart(2, "0")).join("");
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
    const tokenHash = Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");

    const maxUses = Number.isInteger(body.max_uses)
      ? Math.min(Math.max(Number(body.max_uses), 1), 500)
      : null;
    const expiresInHours = Number.isInteger(body.expires_in_hours)
      ? Math.min(Math.max(Number(body.expires_in_hours), 1), 720)
      : null;
    const expiresAt = expiresInHours === null
      ? null
      : new Date(Date.now() + expiresInHours * 3600000).toISOString();
    const requiresApproval = body.requires_approval === true;

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false },
    });

    const { data: safety } = await admin.from("community_safety_settings")
      .select("pause_invites_during_lockdown,lockdown_until")
      .eq("community_id", communityId)
      .maybeSingle();
    const lockedUntil = safety?.lockdown_until ? new Date(safety.lockdown_until) : null;
    if (safety?.pause_invites_during_lockdown === true && lockedUntil && lockedUntil > new Date()) {
      return json({ error: "Invite creation is paused during raid lockdown.", lockdown_until: lockedUntil.toISOString() }, 423);
    }

    const { data, error } = await admin.from("community_invites").insert({
      community_id: communityId,
      token_hash: tokenHash,
      created_by: user.id,
      max_uses: maxUses,
      expires_at: expiresAt,
      requires_approval: requiresApproval,
    }).select("id,expires_at,max_uses,requires_approval,created_at").single();
    if (error) return json({ error: error.message }, 400);

    return json({
      invite: data,
      code: token,
      warning: "Copy this invite code now. It is stored as a hash and cannot be retrieved later.",
    }, 201);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Invalid request" }, 400);
  }
});
