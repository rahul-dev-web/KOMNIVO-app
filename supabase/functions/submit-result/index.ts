import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json, readBearer } from "../_shared/http.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const authorization = readBearer(req);
  if (!authorization) return json({ error: "Authentication required" }, 401);
  const client = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } }, auth: { persistSession: false },
  });
  const { data: { user }, error: authError } = await client.auth.getUser();
  if (authError || !user) return json({ error: "Invalid session" }, 401);
  try {
    const body = await req.json();
    const matchId = String(body.match_id ?? "");
    const teamId = String(body.team_id ?? "");
    const placement = Number(body.placement);
    const kills = Number(body.kills);
    if (!matchId || !teamId || !Number.isInteger(placement) || placement < 1 || !Number.isInteger(kills) || kills < 0) {
      return json({ error: "match_id, team_id, positive placement and non-negative kills are required." }, 400);
    }
    const { data: roster } = await client.from("team_members").select("team_id").eq("team_id", teamId).eq("user_id", user.id).maybeSingle();
    const { data: participant } = await client.from("match_participants").select("match_id").eq("match_id", matchId).eq("team_id", teamId).maybeSingle();
    if (!roster || !participant) return json({ error: "You are not authorised to submit for this match roster." }, 403);

    const { data: result, error } = await client.from("match_results").insert({
      match_id: matchId, team_id: teamId, submitted_by: user.id,
      placement, kills, status: "submitted",
      result_json: { source: "manual_submission", client_time: new Date().toISOString() },
    }).select().single();
    if (error) return json({ error: error.message }, 400);

    const evidencePaths = Array.isArray(body.evidence_paths) ? body.evidence_paths : [];
    for (const path of evidencePaths) {
      if (typeof path !== "string" || !path.startsWith(`${user.id}/`)) continue;
      await client.from("result_evidence").insert({
        result_id: result.id, uploaded_by: user.id, storage_path: path,
      });
    }
    return json({ result_id: result.id, status: "submitted", note: "Official points are assigned only after organiser approval." }, 201);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Invalid request" }, 400);
  }
});
