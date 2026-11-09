import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json, readBearer } from "../_shared/http.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const authorization = readBearer(req);
  if (!authorization) return json({ error: "Authentication required" }, 401);

  const client = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const { data: { user }, error: authError } = await client.auth.getUser();
  if (authError || !user) return json({ error: "Invalid session" }, 401);

  try {
    const body = await req.json();
    const matchId = String(body.match_id ?? "");
    if (!matchId) return json({ error: "match_id is required" }, 400);

    const { data: memberships, error: membershipError } = await client.from("team_members")
      .select("team_id").eq("user_id", user.id);
    if (membershipError) return json({ error: membershipError.message }, 400);
    const teamIds = (memberships ?? []).map((item: { team_id: string }) => item.team_id);
    if (teamIds.length === 0) return json({ error: "You are not on a registered team roster." }, 403);

    const { data: participants, error: participantError } = await client.from("match_participants")
      .select("team_id").eq("match_id", matchId).in("team_id", teamIds);
    if (participantError) return json({ error: participantError.message }, 400);
    if (!participants || participants.length === 0) {
      return json({ error: "You are not on a registered roster for this match." }, 403);
    }

    const { error } = await client.from("match_checkins").upsert({
      match_id: matchId,
      user_id: user.id,
      status: "ready",
      checked_in_at: new Date().toISOString(),
    }, { onConflict: "match_id,user_id" });
    if (error) return json({ error: error.message }, 400);
    return json({ checked_in: true, team_ids: participants.map((item: { team_id: string }) => item.team_id) });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Invalid request" }, 400);
  }
});
