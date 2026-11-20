import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json, readBearer } from "../_shared/http.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authorization = readBearer(req);
  if (!authorization) return json({ error: "Authentication required" }, 401);
  const url = Deno.env.get("SUPABASE_URL")!;
  const client = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const { data: { user }, error: authError } = await client.auth.getUser();
  if (authError || !user) return json({ error: "Invalid session" }, 401);

  try {
    const body = await req.json();
    const communityId = String(body.community_id ?? "");
    if (!communityId) return json({ error: "community_id is required" }, 400);

    let maxUses: number | null = null;
    if (body.max_uses !== undefined && body.max_uses !== null) {
      if (!Number.isInteger(body.max_uses) || body.max_uses < 1 || body.max_uses > 500) {
        return json({ error: "max_uses must be an integer from 1 to 500." }, 400);
      }
      maxUses = body.max_uses;
    }

    let expiresInHours: number | null = null;
    if (body.expires_in_hours !== undefined && body.expires_in_hours !== null) {
      if (!Number.isInteger(body.expires_in_hours) ||
          body.expires_in_hours < 1 || body.expires_in_hours > 720) {
        return json({ error: "expires_in_hours must be an integer from 1 to 720." }, 400);
      }
      expiresInHours = body.expires_in_hours;
    }
    const expiresAt = expiresInHours === null
      ? null
      : new Date(Date.now() + expiresInHours * 3600000).toISOString();
    const requiresApproval = body.requires_approval === true;

    // The RPC rechecks permission and locks community safety settings while creating
    // the invite, so a concurrent raid lockdown cannot race the invitation insert.
    const tokenBytes = crypto.getRandomValues(new Uint8Array(24));
    const token = Array.from(tokenBytes)
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");
    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(token),
    );
    const tokenHash = Array.from(new Uint8Array(digest))
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");

    const { data: invite, error } = await client.rpc("create_community_invite", {
      p_community_id: communityId,
      p_token_hash: tokenHash,
      p_max_uses: maxUses,
      p_expires_at: expiresAt,
      p_requires_approval: requiresApproval,
    });
    if (error) {
      const status = error.code === "42501" ? 403 : error.code === "P0002" ? 404 : 400;
      return json({ error: error.message }, status);
    }

    return json({
      invite,
      code: token,
      warning: "Copy this invite code now. Only its SHA-256 hash is stored; the code cannot be retrieved later.",
    }, 201);
  } catch (error) {
    return json({
      error: error instanceof Error ? error.message : "Invalid request",
    }, 400);
  }
});
