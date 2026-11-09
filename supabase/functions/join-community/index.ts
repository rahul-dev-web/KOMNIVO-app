import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json, readBearer } from "../_shared/http.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const authorization = readBearer(req);
  if (!authorization) return json({ error: "Authentication required" }, 401);

  const url = Deno.env.get("SUPABASE_URL")!;
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return json({ error: "Invalid session" }, 401);

  try {
    const body = await req.json();
    const communityId = String(body.community_id ?? "");
    if (!communityId) return json({ error: "community_id is required" }, 400);

    const { data: community, error: lookupError } = await userClient
      .from("communities").select("id,visibility").eq("id", communityId).maybeSingle();

    if (lookupError || !community) {
      // Private community rows are deliberately not selectable before membership.
      const inviteCode = typeof body.invite_code === "string" ? body.invite_code.trim() : "";
      if (inviteCode.length < 16) return json({ error: "Community not found or invite is required." }, 404);
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(inviteCode));
      const tokenHash = Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
      const { data, error } = await userClient.rpc("consume_community_invite", {
        p_community_id: communityId,
        p_token_hash: tokenHash,
      });
      if (error || data !== true) return json({ error: error?.message ?? "Invite is invalid or expired." }, 403);
      return json({ joined: true });
    }

    if (community.visibility === "private") {
      const inviteCode = typeof body.invite_code === "string" ? body.invite_code.trim() : "";
      if (inviteCode.length < 16) return json({ error: "A valid private invite is required." }, 403);
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(inviteCode));
      const tokenHash = Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
      const { data, error } = await userClient.rpc("consume_community_invite", {
        p_community_id: communityId,
        p_token_hash: tokenHash,
      });
      if (error || data !== true) return json({ error: error?.message ?? "Invite is invalid or expired." }, 403);
      return json({ joined: true });
    }

    const { error: joinError } = await userClient.from("community_members").upsert(
      { community_id: communityId, user_id: user.id, role: "member" },
      { onConflict: "community_id,user_id", ignoreDuplicates: true },
    );
    if (joinError) return json({ error: joinError.message }, 400);
    return json({ joined: true });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Invalid request" }, 400);
  }
});
