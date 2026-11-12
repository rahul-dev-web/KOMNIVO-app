import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json, readBearer } from "../_shared/http.ts";

const PROVIDER = "Free Fire Community API (unofficial)";
const DEFAULT_BASE_URL = "https://developers.freefirecommunity.com/api/v1";

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

  // Provider lookups are authenticated as the caller, but trusted game-account
  // persistence is performed with the server-only service role. Client users
  // cannot write ownership_status or forge another account's UID association.
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!serviceRoleKey) return json({ error: "Server-side profile storage is not configured." }, 503);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const apiKey = Deno.env.get("FREEFIRE_API_KEY");
  if (!apiKey) return json({ error: "Game profile provider is not configured on the server." }, 503);

  try {
    const body = await req.json();
    const uid = String(body.uid ?? "").trim();
    const region = String(body.region ?? "ind").toLowerCase();
    if (!/^\d{5,15}$/.test(uid)) return json({ error: "UID must contain 5–15 digits." }, 400);
    if (!["ind", "sg", "br"].includes(region)) return json({ error: "Unsupported region." }, 400);

    const base = (Deno.env.get("FREEFIRE_API_BASE_URL") ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    const headers = {
      "x-api-key": apiKey,
      "User-Agent": "KOMNIVO/0.1 (esports community app)",
    };
    const query = new URLSearchParams({ region, uid });
    const [infoResponse, statsResponse] = await Promise.all([
      fetch(`${base}/info?${query.toString()}`, { headers }),
      fetch(`${base}/stats?${query.toString()}`, { headers }),
    ]);

    if (infoResponse.status === 404) return json({ error: "Player UID was not found in the selected region." }, 404);
    if (!infoResponse.ok) {
      const detail = await infoResponse.text();
      return json({ error: `Game provider returned ${infoResponse.status}.`, provider_detail: detail.slice(0, 300) }, 502);
    }

    const info = await infoResponse.json() as Record<string, unknown>;
    const stats = statsResponse.ok ? await statsResponse.json() as Record<string, unknown> : {};
    const basic = (info.basicInfo ?? info.BasicInfo ?? {}) as Record<string, unknown>;
    const clan = (info.clanBasicInfo ?? info.ClanBasicInfo ?? {}) as Record<string, unknown>;
    const profileInfo = (info.profileInfo ?? info.ProfileInfo ?? {}) as Record<string, unknown>;

    const profile = {
      nickname: basic.nickname ?? basic.AccountName ?? info.nickname ?? null,
      level: basic.level ?? basic.AccountLevel ?? null,
      likes: basic.liked ?? basic.likes ?? basic.AccountLikes ?? null,
      rank: basic.rank ?? basic.brRank ?? basic.BrMaxRank ?? null,
      region: basic.region ?? region.toUpperCase(),
      clan_name: clan.clanName ?? clan.name ?? null,
      clan_level: clan.clanLevel ?? null,
      clan_members: clan.memberNum ?? null,
      avatar_id: profileInfo.avatarId ?? profileInfo.avatar_id ?? null,
    };

    const { data: game, error: gameError } = await client.from("games")
      .select("id").eq("code", "free_fire_max").single();
    if (gameError || !game) return json({ error: "Free Fire MAX game catalog entry is missing." }, 500);

    const level = Number(profile.level);
    const lastSyncedAt = new Date().toISOString();
    const profileFields = {
      nickname: profile.nickname?.toString() ?? null,
      level: Number.isFinite(level) ? level : null,
      rank_label: profile.rank?.toString() ?? null,
      provider: PROVIDER,
      sync_status: "synced",
      last_synced_at: lastSyncedAt,
      raw_profile: info,
      raw_stats: stats,
    };

    // One KOMNIVO account may link one Free Fire account for this game.
    // Never silently replace its UID/region, and never overwrite Support's
    // ownership_status when refreshing public profile data.
    const { data: existingAccount, error: existingAccountError } = await admin
      .from("game_accounts")
      .select("id, uid, region, ownership_status")
      .eq("user_id", user.id)
      .eq("game_id", game.id)
      .maybeSingle();

    if (existingAccountError) {
      return json({ error: "The linked game account could not be checked securely." }, 500);
    }

    if (
      existingAccount &&
      (String(existingAccount.uid) !== uid ||
        String(existingAccount.region ?? "").toLowerCase() !== region)
    ) {
      return json({
        error: "A different Free Fire UID is already linked to this KOMNIVO account. Contact Platform Support to request a safe account change.",
      }, 409);
    }

    let accountRow: Record<string, unknown> | null = null;

    if (existingAccount) {
      const { data: updatedAccount, error: updateError } = await admin
        .from("game_accounts")
        .update(profileFields)
        .eq("id", existingAccount.id)
        .eq("user_id", user.id)
        .select()
        .single();

      if (updateError || !updatedAccount) {
        return json({ error: "The game profile could not be refreshed securely." }, 400);
      }
      accountRow = updatedAccount;
    } else {
      const { data: insertedAccount, error: insertError } = await admin
        .from("game_accounts")
        .insert({
          user_id: user.id,
          game_id: game.id,
          uid,
          region,
          ...profileFields,
          ownership_status: "linked_unverified",
        })
        .select()
        .single();

      if (insertError?.code === "23505") {
        // A concurrent request for the same user may have inserted the same
        // game account after our initial read. Re-read and reuse only an exact
        // same-user UID/region match; never take over another user's record.
        const { data: racedAccount, error: raceReadError } = await admin
          .from("game_accounts")
          .select("id, uid, region, ownership_status")
          .eq("user_id", user.id)
          .eq("game_id", game.id)
          .maybeSingle();

        if (
          raceReadError ||
          !racedAccount ||
          String(racedAccount.uid) !== uid ||
          String(racedAccount.region ?? "").toLowerCase() !== region
        ) {
          return json({
            error: "This Free Fire UID is already linked to another KOMNIVO account, or a different UID is already linked to your account. Contact Support if you believe this is an error.",
          },  409);
        }

        const { data: refreshedAccount, error: refreshError } = await admin
          .from("game_accounts")
          .update(profileFields)
          .eq("id", racedAccount.id)
          .eq("user_id", user.id)
          .select()
          .single();

        if (refreshError || !refreshedAccount) {
          return json({ error: "The game profile could not be refreshed securely." }, 400);
        }
        accountRow = refreshedAccount;
      } else if (insertError || !insertedAccount) {
        return json({ error: "The game profile could not be saved securely." }, 400);
      } else {
        accountRow = insertedAccount;
      }
    }

    if (!accountRow) {
      return json({ error: "The game profile could not be saved securely." }, 500);
    }

    const { error: snapshotError } = await admin.from("game_profile_snapshots").insert({
      user_id: user.id,
      game_account_id: accountRow.id,
      provider: PROVIDER,
      region,
      profile_json: info,
      stats_json: stats,
    });
    if (snapshotError) {
      return json({ error: "The game profile was fetched, but its history snapshot could not be saved." }, 500);
    }

    return json({
      account_id: accountRow.id,
      ownership_status: accountRow.ownership_status ?? "linked_unverified",
      provider: PROVIDER,
      last_synced_at: lastSyncedAt,
      profile,
      stats,
      notice: "This third-party API is unofficial and does not verify ownership of the game account.",
    });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Provider request failed." }, 500);
  }
});
