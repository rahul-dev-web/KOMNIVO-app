import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json, readBearer } from "../_shared/http.ts";

const PROVIDER = "Free Fire Community API (unofficial)";
const DEFAULT_BASE_URL = "https://developers.freefirecommunity.com/api/v1";
const GAME_CODE = "free_fire_max";
const CHALLENGE_LIFETIME_MS = 30 * 60 * 1000;
const MAX_VERIFY_ATTEMPTS = 5;
const VERIFY_RETRY_SECONDS = 15;

type RecordData = Record<string, unknown>;

function asRecord(value: unknown): RecordData {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as RecordData
    : {};
}

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return toHex(new Uint8Array(digest));
}

function constantTimeHexEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

function makeChallengeCode(): string {
  const random = crypto.getRandomValues(new Uint8Array(16));
  return "KOMNIVO-" + toHex(random).toUpperCase();
}

function withoutPublicBio(raw: RecordData): RecordData {
  const clone = JSON.parse(JSON.stringify(raw)) as RecordData;

  // Provider casing may differ between payload versions. Strip the signature
  // from both spellings so no player's temporary challenge or previous Bio is
  // accidentally copied into profile snapshots.
  for (const key of ["socialInfo", "SocialInfo"]) {
    const socialInfo = asRecord(clone[key]);
    if (Object.keys(socialInfo).length > 0) {
      delete socialInfo.signature;
      clone[key] = socialInfo;
    }
  }
  return clone;
}

function providerHeaders(apiKey: string): HeadersInit {
  return {
    "x-api-key": apiKey,
    "User-Agent": "KOMNIVO/1.0 (+https://komnivo-app.pages.dev)",
  };
}

async function fetchPlayerInfo(base: string, headers: HeadersInit, region: string, uid: string) {
  const query = new URLSearchParams({ region, uid });
  const response = await fetch(base + "/info?" + query.toString(), { headers });
  if (!response.ok) {
    const status = response.status;
    const detail = status === 404
      ? "Player UID was not found in the selected region."
      : status === 429
        ? "The game-profile provider is rate limiting requests. Please wait before retrying."
        : "Game provider returned " + status + ".";
    throw Object.assign(new Error(detail), { httpStatus: status });
  }
  return await response.json() as RecordData;
}

async function authenticate(req: Request) {
  const authorization = readBearer(req);
  if (!authorization) return { error: json({ error: "Authentication required." }, 401) };

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceRoleKey) {
    return { error: json({ error: "Server-side game profile storage is not configured." }, 503) };
  }

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user }, error } = await userClient.auth.getUser();
  if (error || !user) return { error: json({ error: "Invalid session." }, 401) };

  const admin = createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return { user, userClient, admin };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const auth = await authenticate(req);
  if ("error" in auth) return auth.error;

  try {
    const body = asRecord(await req.json());
    const action = String(body.action ?? "lookup");
    const { user, userClient, admin } = auth;

    if (action === "status") {
      const { data: game, error: gameError } = await userClient.from("games")
        .select("id").eq("code", GAME_CODE).single();
      if (gameError || !game) return json({ error: "Free Fire game catalogue entry is unavailable." }, 500);

      const { data: accounts, error: accountError } = await admin.from("game_accounts")
        .select("id, uid, region, nickname, level, rank_label, ownership_status, last_synced_at")
        .eq("user_id", user.id).eq("game_id", game.id)
        .order("updated_at", { ascending: false }).limit(2);
      if (accountError) return json({ error: "Could not load your linked game account." }, 500);
      if (!accounts || accounts.length === 0) {
        return json({
          status: "not_linked",
          message: "Enter your Free Fire UID to look up your profile and generate a verification code.",
        });
      }
      if (accounts.length > 1) {
        return json({ error: "More than one Free Fire account is linked. Contact KOMNIVO Support before continuing." }, 409);
      }

      const account = accounts[0];
      if (account.ownership_status === "verified") {
        return json({
          status: "verified",
          account_id: account.id,
          uid: account.uid,
          region: account.region,
          nickname: account.nickname,
          ownership_status: account.ownership_status,
          last_synced_at: account.last_synced_at,
          message: "KOMNIVO has verified control of this Free Fire account. You may now change your Bio back.",
        });
      }

      const { data: challenges, error: challengeError } = await admin.from("game_account_verification_challenges")
        .select("id, status, attempts, expires_at, created_at")
        .eq("user_id", user.id).eq("game_account_id", account.id)
        .order("created_at", { ascending: false }).limit(1);
      if (challengeError) return json({ error: "Could not load ownership verification status." }, 500);

      const challenge = challenges?.[0];
      const expired = challenge?.status === "pending" &&
        Date.parse(String(challenge.expires_at)) <= Date.now();
      if (expired) {
        await admin.from("game_account_verification_challenges")
          .update({ status: "expired", updated_at: new Date().toISOString() })
          .eq("id", challenge.id).eq("status", "pending");
      }

      const challengeStatus = expired ? "expired" : (challenge?.status ?? "not_started");
      return json({
        status: account.ownership_status === "proof_pending" ? "proof_pending" : "linked_unverified",
        challenge_status: challengeStatus,
        challenge_expires_at: challenge?.expires_at ?? null,
        account_id: account.id,
        uid: account.uid,
        region: account.region,
        nickname: account.nickname,
        ownership_status: account.ownership_status,
        last_synced_at: account.last_synced_at,
        message: expired
          ? "Your previous code has expired. Generate a new code and place it in your Free Fire Bio."
          : "Ownership is pending. Generate a one-time code, paste only that code into your Free Fire Bio/Signature, then start verification.",
      });
    }

    const apiKey = Deno.env.get("FREEFIRE_API_KEY");
    if (!apiKey) return json({ error: "Game-profile provider is not configured on the server." }, 503);
    const base = (Deno.env.get("FREEFIRE_API_BASE_URL") ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
    const headers = providerHeaders(apiKey);

    if (action === "lookup") {
      const uid = String(body.uid ?? "").trim();
      const region = String(body.region ?? "ind").toLowerCase();
      if (!/^\d{5,15}$/.test(uid)) return json({ error: "UID must contain 5–15 digits." }, 400);
      if (!["ind", "sg", "br"].includes(region)) return json({ error: "Unsupported region." }, 400);

      const info = await fetchPlayerInfo(base, headers, region, uid);
      const statsQuery = new URLSearchParams({ region, uid });
      const statsResponse = await fetch(base + "/stats?" + statsQuery.toString(), { headers });
      const stats = statsResponse.ok ? await statsResponse.json() as RecordData : {};
      const basic = asRecord(info.basicInfo ?? info.BasicInfo);
      const clan = asRecord(info.clanBasicInfo ?? info.ClanBasicInfo);
      const profileInfo = asRecord(info.profileInfo ?? info.ProfileInfo);
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

      const { data: game, error: gameError } = await userClient.from("games")
        .select("id").eq("code", GAME_CODE).single();
      if (gameError || !game) return json({ error: "Free Fire MAX game catalogue entry is missing." }, 500);

      const { data: existingAccounts, error: existingError } = await admin.from("game_accounts")
        .select("id, uid, region, ownership_status")
        .eq("user_id", user.id).eq("game_id", game.id).limit(2);
      if (existingError) return json({ error: "The linked game account could not be checked securely." }, 500);
      if ((existingAccounts ?? []).length > 1) {
        return json({ error: "Multiple Free Fire accounts are already linked to this KOMNIVO account. Contact Support before changing them." }, 409);
      }

      const existing = existingAccounts?.[0] ?? null;
      if (existing && (String(existing.uid) !== uid || String(existing.region ?? "").toLowerCase() !== region)) {
        return json({ error: "A different Free Fire UID is already linked to this KOMNIVO account. Contact Support to request a safe account change." }, 409);
      }

      const cleanInfo = withoutPublicBio(info);
      const level = Number(profile.level);
      const syncedAt = new Date().toISOString();
      const profileFields = {
        nickname: profile.nickname?.toString() ?? null,
        level: Number.isFinite(level) ? level : null,
        rank_label: profile.rank?.toString() ?? null,
        provider: PROVIDER,
        sync_status: "synced",
        last_synced_at: syncedAt,
        raw_profile: cleanInfo,
        raw_stats: stats,
        updated_at: syncedAt,
      };

      let accountRow: RecordData | null = null;
      if (existing) {
        const { data, error } = await admin.from("game_accounts")
          .update(profileFields).eq("id", existing.id).eq("user_id", user.id)
          .select("id, uid, region, ownership_status, nickname, level, rank_label, last_synced_at").single();
        if (error || !data) return json({ error: "The game profile could not be refreshed securely." }, 400);
        accountRow = data;
      } else {
        const { data, error } = await admin.from("game_accounts")
          .insert({
            user_id: user.id,
            game_id: game.id,
            uid,
            region,
            ...profileFields,
            ownership_status: "linked_unverified",
          })
          .select("id, uid, region, ownership_status, nickname, level, rank_label, last_synced_at").single();

        if (error?.code === "23505") {
          return json({ error: "This Free Fire UID is already linked to another KOMNIVO account. Contact Support if you believe this is your account." }, 409);
        }
        if (error || !data) return json({ error: "The game profile could not be saved securely." }, 400);
        accountRow = data;
      }

      const { error: snapshotError } = await admin.from("game_profile_snapshots").insert({
        user_id: user.id,
        game_account_id: accountRow.id,
        provider: PROVIDER,
        region,
        profile_json: cleanInfo,
        stats_json: stats,
      });
      if (snapshotError) {
        return json({ error: "The profile was fetched, but its history snapshot could not be saved." }, 500);
      }

      if (accountRow.ownership_status === "verified") {
        return json({
          account_id: accountRow.id,
          ownership_status: "verified",
          status: "verified",
          provider: PROVIDER,
          last_synced_at: syncedAt,
          profile,
          stats,
          message: "KOMNIVO has already verified control of this Free Fire account. You may change your Bio back.",
        });
      }

      const challengeCode = makeChallengeCode();
      const challengeHash = await sha256Hex(challengeCode);
      const now = new Date();
      const expiresAt = new Date(now.getTime() + CHALLENGE_LIFETIME_MS).toISOString();

      const { error: replaceError } = await admin.from("game_account_verification_challenges")
        .update({ status: "replaced", updated_at: now.toISOString() })
        .eq("game_account_id", accountRow.id).eq("status", "pending");
      if (replaceError) return json({ error: "Could not rotate the previous verification code." }, 500);

      const { error: challengeInsertError } = await admin.from("game_account_verification_challenges")
        .insert({
          user_id: user.id,
          game_account_id: accountRow.id,
          challenge_hash: challengeHash,
          status: "pending",
          expires_at: expiresAt,
          attempts: 0,
        });
      if (challengeInsertError) return json({ error: "Could not create a secure verification code." }, 500);

      const { error: ownershipError } = await admin.from("game_accounts")
        .update({ ownership_status: "proof_pending", updated_at: now.toISOString() })
        .eq("id", accountRow.id).eq("user_id", user.id);
      if (ownershipError) return json({ error: "The profile was found, but its ownership state could not be updated." }, 500);

      await admin.from("notifications").insert({
        user_id: user.id,
        title: "Free Fire ownership verification pending",
        body: "Your UID profile was found. Paste the one-time KOMNIVO code into your Free Fire profile Bio/Signature, then return to KOMNIVO and start verification. The code expires in 30 minutes.",
        kind: "verification",
        entity_type: "game_account",
        entity_id: accountRow.id,
      });

      return json({
        account_id: accountRow.id,
        status: "proof_pending",
        ownership_status: "proof_pending",
        provider: PROVIDER,
        last_synced_at: syncedAt,
        profile,
        stats,
        challenge_code: challengeCode,
        challenge_expires_at: expiresAt,
        challenge_lifetime_seconds: 1800,
        message: "Your game profile was found. Ownership is pending. Copy the code exactly, replace your Free Fire Bio/Signature with this code only, save it, then confirm the checkbox and start verification. You may change the Bio back after verification succeeds.",
        notice: "UID lookup alone does not prove ownership. The code is checked against the profile signature returned by the third-party API.",
      });
    }

    if (action === "verify") {
      if (body.bio_confirmed !== true) {
        return json({ error: "Confirm that the exact code is saved as the complete Bio/Signature before starting verification." }, 400);
      }

      const accountId = String(body.account_id ?? "").trim();
      if (!/^[0-9a-f-]{36}$/i.test(accountId)) return json({ error: "Invalid linked game-account reference." }, 400);

      const { data: account, error: accountError } = await admin.from("game_accounts")
        .select("id, uid, region, ownership_status")
        .eq("id", accountId).eq("user_id", user.id).maybeSingle();
      if (accountError || !account) return json({ error: "This Free Fire account is not linked to your KOMNIVO account." }, 404);

      if (account.ownership_status === "verified") {
        return json({ status: "verified", ownership_status: "verified", message: "Ownership is already verified. You may change your Bio back." });
      }

      const { data: challenge, error: challengeError } = await admin.from("game_account_verification_challenges")
        .select("id, challenge_hash, attempts, expires_at, last_attempt_at, status")
        .eq("user_id", user.id).eq("game_account_id", account.id).eq("status", "pending")
        .order("created_at", { ascending: false }).limit(1).maybeSingle();
      if (challengeError || !challenge) {
        return json({ error: "No active verification code was found. Generate a new code and place it in your Bio." }, 409);
      }

      const now = new Date();
      if (Date.parse(String(challenge.expires_at)) <= now.getTime()) {
        await admin.from("game_account_verification_challenges")
          .update({ status: "expired", updated_at: now.toISOString() }).eq("id", challenge.id);
        return json({ error: "This verification code has expired. Generate a new code and try again.", status: "expired" }, 410);
      }
      if (Number(challenge.attempts) >= MAX_VERIFY_ATTEMPTS) {
        await admin.from("game_account_verification_challenges")
          .update({ status: "locked", updated_at: now.toISOString() }).eq("id", challenge.id);
        return json({ error: "This code reached its verification-attempt limit. Generate a new code and try again.", status: "locked" }, 429);
      }
      if (challenge.last_attempt_at) {
        const elapsed = now.getTime() - Date.parse(String(challenge.last_attempt_at));
        if (elapsed < VERIFY_RETRY_SECONDS * 1000) {
          const wait = Math.ceil((VERIFY_RETRY_SECONDS * 1000 - elapsed) / 1000);
          return json({ error: "Please wait " + wait + " seconds before checking the Bio again.", retry_after_seconds: wait }, 429);
        }
      }

      const info = await fetchPlayerInfo(base, headers, String(account.region).toLowerCase(), String(account.uid));
      const socialInfo = asRecord(info.socialInfo ?? info.SocialInfo);
      // Do not trim or otherwise normalise: the Bio must contain the exact
      // challenge code and nothing before or after it.
      const currentSignature = typeof socialInfo.signature === "string" ? socialInfo.signature : "";
      const observedHash = currentSignature ? await sha256Hex(currentSignature) : "";
      const attemptCount = Number(challenge.attempts) + 1;

      if (!observedHash || !constantTimeHexEqual(observedHash, String(challenge.challenge_hash))) {
        const locked = attemptCount >= MAX_VERIFY_ATTEMPTS;
        await admin.from("game_account_verification_challenges")
          .update({
            attempts: attemptCount,
            last_attempt_at: now.toISOString(),
            status: locked ? "locked" : "pending",
            updated_at: now.toISOString(),
          })
          .eq("id", challenge.id).eq("status", "pending");
        return json({
          status: locked ? "locked" : "proof_pending",
          error: locked
            ? "The code could not be found after five checks. Generate a fresh code and try again."
            : "The code is not visible in the latest profile response yet. Check that the Bio contains only the exact code, save it in-game, wait briefly, then retry.",
          attempts_remaining: Math.max(0, MAX_VERIFY_ATTEMPTS - attemptCount),
          retry_after_seconds: VERIFY_RETRY_SECONDS,
        }, locked ? 429 : 409);
      }

      const verifiedAt = now.toISOString();

      // The game-account ownership state is the user-visible source of truth.
      // Update it only after the live Bio has matched exactly. If challenge
      // bookkeeping then fails, status reads still show Verified and a retry
      // cannot accidentally undo the completed proof.
      const { error: accountUpdateError } = await admin.from("game_accounts")
        .update({ ownership_status: "verified", updated_at: verifiedAt })
        .eq("id", account.id).eq("user_id", user.id);
      if (accountUpdateError) return json({ error: "The challenge matched, but the game-account status could not be updated." }, 500);

      const { error: challengeUpdateError } = await admin.from("game_account_verification_challenges")
        .update({
          status: "verified",
          verified_at: verifiedAt,
          last_attempt_at: verifiedAt,
          attempts: attemptCount,
          updated_at: verifiedAt,
        }).eq("id", challenge.id).eq("status", "pending");
      if (challengeUpdateError) {
        return json({ error: "The account is verified, but the challenge audit record needs a retry." }, 500);
      }

      await admin.from("notifications").insert({
        user_id: user.id,
        title: "Free Fire account ownership verified",
        body: "KOMNIVO verified that you can control the linked Free Fire profile. You may now restore or change your Bio/Signature.",
        kind: "verification",
        entity_type: "game_account",
        entity_id: account.id,
      });

      return json({
        status: "verified",
        ownership_status: "verified",
        verified_at: verifiedAt,
        message: "Free Fire account ownership verified successfully. You may now change your Bio/Signature back.",
      });
    }

    return json({ error: "Unsupported action. Use lookup, status or verify." }, 400);
  } catch (error) {
    const status = Number((error as { httpStatus?: number }).httpStatus ?? 500);
    return json({
      error: error instanceof Error ? error.message : "Game profile request failed.",
    }, status >= 400 && status < 600 ? status : 500);
  }
});
