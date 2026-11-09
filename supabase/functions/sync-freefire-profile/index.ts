import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json, readBearer } from "../_shared/http.ts";

const PROVIDER = "Free Fire Community API (unofficial)";
const BASE_URL = "https://developers.freefirecommunity.com/api/v1";

function pick(source: Record<string, unknown>, ...keys: string[]): unknown {
  for (const key of keys) if (source[key] !== undefined && source[key] !== null) return source[key];
  return undefined;
}

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

  const apiKey = Deno.env.get("FREEFIRE_API_KEY");
  if (!apiKey) return json({ error: "Game profile provider is not configured on the server." }, 503);

  try {
    const body = await req.json();
    const uid = String(body.uid ?? "").trim();
    const region = String(body.region ?? "ind").toLowerCase();
    if (!/^\d{5,15}$/.test(uid)) return json({ error: "UID must contain 5–15 digits." }, 400);
    if (!["ind", "sg", "br"].includes(region)) return json({ error: "Unsupported region." }, 400);

    const headers = {
      "x-api-key": apiKey,
      "User-Agent": "KOMNIVO/0.1 (+https://komnivo.app)",
    };
    const query = new URLSearchParams({ region, uid });
    const [infoResponse, statsResponse] = await Promise.all([
      fetch(`${BASE_URL}/info?${query.toString()}`, { headers }),
      fetch(`${BASE_URL}/stats?${query.toString()}`, { headers }),
    ]);

    if (infoResponse.status === 404) return json({ error: "Player UID was not found in the selected region." }, 404);
    if (!infoResponse.ok) {
      const detail = await infoResponse.text();
      return json({ error: `Game provider returned ${infoResponse.status}.`, provider_detail: detail.slice(0, 300) }, 502);
    }
    const info = await infoResponse.json() as Record<string, unknown>;
    const stats = statsResponse.ok ? await statsResponse.json() as Record<string, unknown> : {};
    const account = (pick(info, "AccountInfo", "accountInfo", "account_info", "profileInfo", "profile") ?? info) as Record<string, unknown>;
    const profile = {
      nickname: pick(account, "AccountName", "nickname", "name") ?? pick(info, "nickname", "name"),
      level: pick(account, "AccountLevel", "level"),
      likes: pick(account, "AccountLikes", "likes"),
      rank: pick(account, "BrMaxRank", "brRank", "rank"),
      avatar_id: pick((pick(info, "AccountProfileInfo", "profileInfo") ?? {}) as Record<string, unknown>, "avatarId", "avatar_id"),
    };

    const { data: game } = await client.from("games").select("id").eq("code", "free_fire_max").single();
    if (!game) return json({ error: "Free Fire MAX game catalog entry is missing." }, 500);

    const profilePayload = {
      user_id: user.id,
      game_id: game.id,
      uid,
      region,
      nickname: profile.nickname?.toString() ?? null,
      level: Number.isFinite(Number(profile.level)) ? Number(profile.level) : null,
      rank_label: profile.rank?.toString() ?? null,
      provider: PROVIDER,
      ownership_status: "linked_unverified",
      sync_status: "synced",
      last_synced_at: new Date().toISOString(),
      raw_profile: info,
      raw_stats: stats,
    };
    const { data: accountRow, error: upsertError } = await client.from("game_accounts")
      .upsert(profilePayload, { onConflict: "user_id,game_id" })
      .select().single();
    if (upsertError) return json({ error: upsertError.message }, 400);

    await client.from("game_profile_snapshots").insert({
      user_id: user.id,
      game_account_id: accountRow.id,
      provider: PROVIDER,
      region,
      profile_json: info,
      stats_json: stats,
    });

    return json({
      account_id: accountRow.id,
      ownership_status: "linked_unverified",
      provider: PROVIDER,
      last_synced_at: profilePayload.last_synced_at,
      profile,
      stats,
      notice: "This third-party API is unofficial and does not verify ownership of the game account.",
    });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Provider request failed." }, 500);
  }
});
