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
    const supplied = Array.isArray(body.member_ids) ? body.member_ids : [];
    const members = [...new Set([user.id, ...supplied.filter((id: unknown) => typeof id === "string")])];
    if (members.length < 2 || members.length > 20) return json({ error: "A conversation must have 2–20 members." }, 400);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data: profiles, error: profileError } = await admin.from("profiles").select("id,display_name").in("id", members);
    if (profileError || !profiles || profiles.length !== members.length) return json({ error: "One or more users were not found." }, 404);

    const kind = members.length === 2 ? "dm" : "group";
    const displayNames = profiles.map((profile: { display_name: string }) => profile.display_name);
    const requestedName = typeof body.name === "string" ? body.name.trim().slice(0, 60) : "";
    const name = requestedName || (kind === "dm" ? displayNames.find((_, i) => profiles[i].id !== user.id) ?? "Direct message" : displayNames.slice(0, 3).join(", "));

    const { data: channel, error: channelError } = await admin.from("channels").insert({
      community_id: null,
      name,
      kind,
      is_private: true,
      created_by: user.id,
    }).select().single();
    if (channelError) return json({ error: channelError.message }, 400);

    const { error: memberError } = await admin.from("channel_members").insert(
      members.map((userId: string) => ({ channel_id: channel.id, user_id: userId })),
    );
    if (memberError) {
      await admin.from("channels").delete().eq("id", channel.id);
      return json({ error: memberError.message }, 400);
    }
    return json({ channel }, 201);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Invalid request" }, 400);
  }
});
