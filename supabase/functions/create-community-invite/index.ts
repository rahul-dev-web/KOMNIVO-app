import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json, readBearer } from "../_shared/http.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const authorization = readBearer(req);
  if (!authorization) return json({ error: "Authentication required" }, 401);
  const url = Deno.env.get("SUPABASE_URL")!;
  const client = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false } });
  const { data: { user }, error: authError } = await client.auth.getUser();
  if (authError || !user) return json({ error: "Invalid session" }, 401);

  try {
    const body = await req.json();
    const communityId = String(body.community_id ?? "");
    if (!communityId) return json({ error: "community_id is required" }, 400);
    const { data: manager } = await client.from("community_members").select("role")
      .eq("community_id", communityId).eq("user_id", user.id)
      .in("role", ["owner", "admin", "organiser"]).maybeSingle();
    if (!manager) return json({ error: "Only community owners, admins or organisers can create invites." }, 403);

    const token = Array.from(crypto.getRandomValues(new Uint8Array(24))).map((b) => b.toString(16).padStart(2, "0")).join("");
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
    const tokenHash = Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
    const maxUses = Number.isInteger(body.max_uses) ? Math.min(Math.max(body.max_uses, 1), 500) : null;
    const expiresAt = Number.isInteger(body.expires_in_hours)
      ? new Date(Date.now() + Math.min(Math.max(body.expires_in_hours, 1), 720) * 3600000).toISOString()
      : null;

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data, error } = await admin.from("community_invites").insert({
      community_id: communityId,
      token_hash: tokenHash,
      created_by: user.id,
      max_uses: maxUses,
      expires_at: expiresAt,
    }).select("id,expires_at,max_uses").single();
    if (error) return json({ error: error.message }, 400);
    return json({ invite: data, code: token, warning: "Copy this invite code now. It is stored as a hash and cannot be retrieved later." }, 201);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Invalid request" }, 400);
  }
});
