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
    const inviteId = String(body.invite_id ?? "");
    if (!inviteId) return json({ error: "invite_id is required" }, 400);
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data: invite, error } = await admin.from("team_invites").select("*").eq("id", inviteId).maybeSingle();
    if (error || !invite) return json({ error: "Team invitation not found." }, 404);
    if (invite.invited_user_id !== user.id) return json({ error: "This invitation belongs to another user." }, 403);
    if (invite.status !== "pending" || new Date(invite.expires_at) < new Date()) return json({ error: "This invitation has expired or has already been handled." }, 409);

    const { data: existing } = await admin.from("team_members").select("team_id").eq("team_id", invite.team_id).eq("user_id", user.id).maybeSingle();
    if (!existing) {
      const { error: addError } = await admin.from("team_members").insert({ team_id: invite.team_id, user_id: user.id, role: "member" });
      if (addError) return json({ error: addError.message }, 400);
    }
    const { error: updateError } = await admin.from("team_invites").update({ status: "accepted" }).eq("id", inviteId).eq("invited_user_id", user.id);
    if (updateError) return json({ error: updateError.message }, 400);
    return json({ accepted: true, team_id: invite.team_id });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Invalid request" }, 400);
  }
});
