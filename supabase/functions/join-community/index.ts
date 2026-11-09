import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json, readBearer } from "../_shared/http.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authorization = readBearer(req);
  if (!authorization) return json({ error: "Authentication required" }, 401);
  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const client = createClient(url, anon, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false } });
  const { data: { user }, error: authError } = await client.auth.getUser();
  if (authError || !user) return json({ error: "Invalid session" }, 401);

  try {
    const { community_id, invite_code } = await req.json();
    if (typeof community_id !== "string") return json({ error: "community_id is required" }, 400);
    const { data: community, error } = await client.from("communities").select("id,visibility").eq("id", community_id).maybeSingle();
    if (error || !community) return json({ error: "Community not found or not accessible" }, 404);

    if (community.visibility === "private") {
      if (typeof invite_code !== "string" || invite_code.length < 8) return json({ error: "A valid private invite is required." }, 403);
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(invite_code));
      const tokenHash = Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
      const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
      const { data: invite } = await admin.from("community_invites").select("*").eq("community_id", community_id).eq("token_hash", tokenHash).maybeSingle();
      if (!invite || (invite.expires_at && new Date(invite.expires_at) < new Date()) || (invite.max_uses !== null && invite.uses >= invite.max_uses)) {
        return json({ error: "Invite is invalid or expired." }, 403);
      }
      const { error: joinError } = await admin.from("community_members").upsert({ community_id, user_id: user.id, role: "member" }, { onConflict: "community_id,user_id" });
      if (joinError) return json({ error: joinError.message }, 400);
      await admin.from("community_invites").update({ uses: invite.uses + 1 }).eq("id", invite.id);
      return json({ joined: true });
    }

    const { error: joinError } = await client.from("community_members").upsert(
      { community_id, user_id: user.id, role: "member" },
      { onConflict: "community_id,user_id" },
    );
    if (joinError) return json({ error: joinError.message }, 400);
    return json({ joined: true });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Invalid request" }, 400);
  }
});
