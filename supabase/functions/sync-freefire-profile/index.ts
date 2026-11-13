import { createClient } from "npm:@supabase/supabase-js@2";

const PROVIDER = "Free Fire Community API (unofficial)";
const DEFAULT_BASE_URL = "https://developers.freefirecommunity.com/api/v1";
const GAME_CODE = "free_fire_max";
const MAX_VERIFY_ATTEMPTS = 3;
const VERIFY_RETRY_SECONDS = 15;
const CHALLENGE_LIFETIME_MS = 30 * 60 * 1000;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type RecordData = Record<string, unknown>;

function asRecord(value: unknown): RecordData {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as RecordData
    : {};
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
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

// The supplied Free Fire API response nests the Bio exactly here:
// socialInfo.signature. Do not read BasicInfo, profileInfo or a client value
// for ownership proof, and never trim/normalise the signature before matching.
function readProfileSignature(info: RecordData): string {
  const socialInfo = asRecord(info.socialInfo ?? info.SocialInfo);
  const value = socialInfo.signature ?? socialInfo.Signature;
  return typeof value === "string" ? value : "";
}

// Never retain a user's Bio, including the temporary verification code.
function withoutPublicBio(raw: RecordData): RecordData {
  const clone = JSON.parse(JSON.stringify(raw)) as RecordData;
  for (const key of ["socialInfo", "SocialInfo"]) {
    const socialInfo = asRecord(clone[key]);
    delete socialInfo.signature;
    delete socialInfo.Signature;
    clone[key] = socialInfo;
  }
  delete clone.signature;
  delete clone.Signature;
  return clone;
}

function buildProfile(info: RecordData, region: string): RecordData {
  const basicInfo = asRecord(info.basicInfo ?? info.BasicInfo);
  const clanInfo = asRecord(info.clanBasicInfo ?? info.ClanBasicInfo);
  const profileInfo = asRecord(info.profileInfo ?? info.ProfileInfo);

  const numberOrNull = (value: unknown): number | null => {
    if (value === null || value === undefined || value === "") return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) ? Math.trunc(parsed) : null;
  };

  return {
    account_id: basicInfo.accountId ?? basicInfo.AccountId ?? null,
    nickname: basicInfo.nickname ?? basicInfo.AccountName ?? info.nickname ?? null,
    level: numberOrNull(basicInfo.level ?? basicInfo.AccountLevel),
    likes: numberOrNull(basicInfo.liked ?? basicInfo.likes ?? basicInfo.AccountLikes),
    rank: numberOrNull(basicInfo.rank ?? basicInfo.brRank ?? basicInfo.maxRank),
    max_rank: numberOrNull(basicInfo.maxRank ?? basicInfo.max_rank),
    ranking_points: numberOrNull(basicInfo.rankingPoints ?? basicInfo.ranking_points),
    cs_rank: numberOrNull(basicInfo.csRank ?? basicInfo.cs_rank),
    cs_max_rank: numberOrNull(basicInfo.csMaxRank ?? basicInfo.cs_max_rank),
    badge_count: numberOrNull(basicInfo.badgeCnt ?? basicInfo.badge_count),
    badge_id: basicInfo.badgeId ?? null,
    banner_id: basicInfo.bannerId ?? null,
    head_pic: basicInfo.headPic ?? null,
    region: basicInfo.region ?? region.toUpperCase(),
    clan_name: clanInfo.clanName ?? clanInfo.name ?? null,
    clan_id: clanInfo.clanId ?? null,
    clan_level: numberOrNull(clanInfo.clanLevel),
    clan_members: numberOrNull(clanInfo.memberNum),
    clan_capacity: numberOrNull(clanInfo.capacity),
    avatar_id: profileInfo.avatarId ?? profileInfo.avatar_id ?? null,
  };
}

async function authenticate(req: Request) {
  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return { error: json({ error: "Authentication required." }, 401) };
  }

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
  return { user, admin };
}

async function loadFreeFireGame(admin: ReturnType<typeof createClient>) {
  const { data, error } = await admin.from("games")
    .select("id")
    .eq("code", GAME_CODE)
    .single();
  if (error || !data) return null;
  return data as { id: string };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const auth = await authenticate(req);
  if ("error" in auth) return auth.error;

  const { user, admin } = auth;
  let inFlightChallengeId: string | null = null;
  let inFlightAttemptNumber = 0;

  try {
    const body = asRecord(await req.json());
    const action = String(body.action ?? "status");

    const game = await loadFreeFireGame(admin);
    if (!game) return json({ error: "Free Fire MAX game catalogue entry is unavailable." }, 500);

    // Status reads and code preparation use Supabase only. Neither action
    // invokes the Free Fire provider.
    if (action === "status") {
      const { data: accounts, error: accountError } = await admin.from("game_accounts")
        .select("id, uid, region, nickname, level, rank_label, ownership_status, last_synced_at, verification_attempts")
        .eq("user_id", user.id)
        .eq("game_id", game.id)
        .order("updated_at", { ascending: false })
        .limit(2);

      if (accountError) return json({ error: "Could not load your linked Free Fire account." }, 500);
      if (!accounts || accounts.length === 0) {
        return json({
          status: "not_linked",
          ownership_status: "not_linked",
          attempts_remaining: MAX_VERIFY_ATTEMPTS,
          message: "Enter your Free Fire UID and generate a code. This step does not call the Free Fire profile API.",
        });
      }
      if (accounts.length > 1) {
        return json({ error: "Multiple Free Fire accounts are linked. Contact KOMNIVO Support before continuing." }, 409);
      }

      const account = accounts[0];
      const attempts = Number(account.verification_attempts ?? 0);
      const locked = attempts >= MAX_VERIFY_ATTEMPTS;

      if (account.ownership_status === "verified") {
        return json({
          status: "verified",
          ownership_status: "verified",
          account_id: account.id,
          uid: account.uid,
          region: account.region,
          nickname: account.nickname,
          level: account.level,
          rank_label: account.rank_label,
          last_synced_at: account.last_synced_at,
          verification_attempts: attempts,
          attempts_remaining: 0,
          message: "KOMNIVO verified this Free Fire account. You may restore or change your Bio.",
        });
      }

      const { data: challenges, error: challengeError } = await admin.from("game_account_verification_challenges")
        .select("id, status, attempts, expires_at, created_at")
        .eq("user_id", user.id)
        .eq("game_account_id", account.id)
        .order("created_at", { ascending: false })
        .limit(1);

      if (challengeError) return json({ error: "Could not load ownership-verification status." }, 500);

      let challenge = challenges?.[0] ?? null;
      if (challenge?.status === "pending" && Date.parse(String(challenge.expires_at)) <= Date.now()) {
        await admin.from("game_account_verification_challenges")
          .update({ status: "expired", updated_at: new Date().toISOString() })
          .eq("id", challenge.id)
          .eq("status", "pending");
        challenge = { ...challenge, status: "expired" };
      }

      const verificationInProgress = challenge?.status === "verifying";
      return json({
        status: verificationInProgress ? "verifying" : locked ? "locked" : account.ownership_status === "proof_pending" ? "proof_pending" : "linked_unverified",
        ownership_status: account.ownership_status,
        account_id: account.id,
        uid: account.uid,
        region: account.region,
        nickname: account.nickname,
        level: account.level,
        rank_label: account.rank_label,
        last_synced_at: account.last_synced_at,
        verification_attempts: attempts,
        attempts_remaining: Math.max(0, MAX_VERIFY_ATTEMPTS - attempts),
        challenge_status: challenge?.status ?? "not_started",
        challenge_expires_at: challenge?.expires_at ?? null,
        message: locked
          ? "All three Free Fire verification requests for this profile have been used. Contact KOMNIVO Support for further verification."
          : challenge?.status === "expired"
            ? "The previous code expired. Generate a new code; your three verification requests are not reset."
            : "Ownership remains Verification Pending until the exact code is visible in the complete in-game Bio.",
      });
    }

    if (action === "prepare") {
      const uid = String(body.uid ?? "").trim();
      const region = String(body.region ?? "ind").toLowerCase();
      if (!/^\d{5,15}$/.test(uid)) return json({ error: "UID must contain 5–15 digits." }, 400);
      if (!["ind", "sg", "br"].includes(region)) return json({ error: "Unsupported region." }, 400);

      const { data: existingAccounts, error: existingError } = await admin.from("game_accounts")
        .select("id, uid, region, ownership_status, last_synced_at, verification_attempts")
        .eq("user_id", user.id)
        .eq("game_id", game.id)
        .limit(2);

      if (existingError) return json({ error: "Could not check your linked Free Fire account." }, 500);
      if ((existingAccounts ?? []).length > 1) {
        return json({ error: "Multiple Free Fire accounts are linked. Contact KOMNIVO Support." }, 409);
      }

      let account = existingAccounts?.[0] ?? null;
      if (account?.ownership_status === "verified") {
        if (String(account.uid) === uid && String(account.region).toLowerCase() === region) {
          return json({
            status: "verified",
            ownership_status: "verified",
            account_id: account.id,
            uid,
            attempts_remaining: 0,
            message: "This Free Fire account is already verified. You may change your Bio back.",
          });
        }
        return json({ error: "A verified Free Fire account is linked. Contact KOMNIVO Support to change it." }, 409);
      }

      if (account && (String(account.uid) !== uid || String(account.region).toLowerCase() !== region)) {
        // Allow correcting the UID only before any provider profile has been
        // fetched and before any verification request has been consumed.
        if (account.last_synced_at || Number(account.verification_attempts ?? 0) > 0) {
          return json({
            error: "A different Free Fire UID is already linked. Contact KOMNIVO Support to change the linked account safely.",
          }, 409);
        }

        const { error: updateError } = await admin.from("game_accounts")
          .update({
            uid,
            region,
            ownership_status: "proof_pending",
            sync_status: "pending",
            provider: PROVIDER,
            updated_at: new Date().toISOString(),
          })
          .eq("id", account.id)
          .eq("user_id", user.id);

        if (updateError?.code === "23505") {
          return json({ error: "This Free Fire UID is already linked to another KOMNIVO account." }, 409);
        }
        if (updateError) return json({ error: "Could not update the unverified UID." }, 400);

        account = { ...account, uid, region, ownership_status: "proof_pending" };
      }

      if (!account) {
        const { data: inserted, error: insertError } = await admin.from("game_accounts")
          .insert({
            user_id: user.id,
            game_id: game.id,
            uid,
            region,
            provider: PROVIDER,
            ownership_status: "proof_pending",
            sync_status: "pending",
            raw_profile: {},
            raw_stats: {},
          })
          .select("id, uid, region, ownership_status, last_synced_at, verification_attempts")
          .single();

        if (insertError?.code === "23505") {
          return json({ error: "This Free Fire UID is already linked to another KOMNIVO account. Contact Support if you believe this is an error." }, 409);
        }
        if (insertError || !inserted) return json({ error: "Could not prepare this Free Fire UID for verification." }, 400);
        account = inserted;
      }

      const attempts = Number(account.verification_attempts ?? 0);
      if (attempts >= MAX_VERIFY_ATTEMPTS) {
        return json({
          status: "locked",
          ownership_status: "proof_pending",
          account_id: account.id,
          uid,
          verification_attempts: attempts,
          attempts_remaining: 0,
          message: "All three verification requests are used. Contact KOMNIVO Support for further verification.",
        });
      }

      const code = makeChallengeCode();
      const expiresAt = new Date(Date.now() + CHALLENGE_LIFETIME_MS).toISOString();
      const prepared = await admin.rpc("prepare_game_verification_challenge", {
        p_game_account_id: account.id,
        p_user_id: user.id,
        p_challenge_hash: await sha256Hex(code),
        p_expires_at: expiresAt,
      });

      if (prepared.error) return json({ error: "Could not safely prepare your verification code." }, 500);
      const gate = asRecord(prepared.data);
      if (gate.verified === true) {
        return json({ status: "verified", ownership_status: "verified", account_id: account.id, uid });
      }
      if (gate.in_progress === true) {
        return json({
          status: "verifying",
          ownership_status: "proof_pending",
          account_id: account.id,
          uid,
          verification_attempts: Number(gate.verification_attempts ?? attempts),
          attempts_remaining: Number(gate.attempts_remaining ?? Math.max(0, 3 - attempts)),
          message: "A verification request is already running for this Free Fire profile. Wait for it to finish before generating another code or retrying.",
        });
      }
      if (gate.locked === true) {
        return json({
          status: "locked",
          ownership_status: "proof_pending",
          account_id: account.id,
          uid,
          verification_attempts: Number(gate.verification_attempts ?? attempts),
          attempts_remaining: 0,
          message: "All three verification requests are used. Contact KOMNIVO Support.",
        });
      }
      if (gate.error) return json({ error: "The linked Free Fire account could not be prepared." }, 409);

      return json({
        status: "proof_pending",
        ownership_status: "proof_pending",
        account_id: account.id,
        uid,
        region,
        challenge_code: code,
        challenge_expires_at: expiresAt,
        challenge_lifetime_seconds: 1800,
        verification_attempts: Number(gate.verification_attempts ?? attempts),
        attempts_remaining: Number(gate.attempts_remaining ?? (MAX_VERIFY_ATTEMPTS - attempts)),
        message: "Your code is ready. Replace the complete Free Fire Bio with this exact code only, tick the confirmation checkbox and tap Verify. No Free Fire profile API request has been made yet.",
      });
    }

    if (action === "verify") {
      if (body.bio_confirmed !== true) {
        return json({
          status: "proof_pending",
          error: "Confirm that the complete Free Fire Bio contains only the exact KOMNIVO code.",
        }, 400);
      }

      const accountId = String(body.account_id ?? "").trim();
      if (!/^[0-9a-f-]{36}$/i.test(accountId)) {
        return json({ error: "Invalid linked game-account reference." }, 400);
      }

      const { data: account, error: accountError } = await admin.from("game_accounts")
        .select("id, uid, region, nickname, ownership_status, verification_attempts")
        .eq("id", accountId)
        .eq("user_id", user.id)
        .maybeSingle();

      if (accountError || !account) return json({ error: "This Free Fire UID is not linked to your KOMNIVO account." }, 404);
      if (account.ownership_status === "verified") {
        return json({
          status: "verified",
          ownership_status: "verified",
          attempts_remaining: 0,
          message: "Ownership is already verified. You may change your Bio back.",
        });
      }

      const { data: challenge, error: challengeError } = await admin.from("game_account_verification_challenges")
        .select("id, challenge_hash, expires_at, status")
        .eq("user_id", user.id)
        .eq("game_account_id", account.id)
        .in("status", ["pending", "verifying"])
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();

      if (challengeError || !challenge) {
        return json({
          status: "no_active_code",
          error: "No active verification code exists. Generate a new code first.",
        }, 409);
      }

      if (challenge.status !== "verifying" && Date.parse(String(challenge.expires_at)) <= Date.now()) {
        await admin.from("game_account_verification_challenges")
          .update({ status: "expired", updated_at: new Date().toISOString() })
          .eq("id", challenge.id)
          .eq("status", "pending");
        return json({
          status: "expired",
          error: "This code expired after 30 minutes. Generate a new code; previous verification requests are not reset.",
          attempts_remaining: Math.max(0, MAX_VERIFY_ATTEMPTS - Number(account.verification_attempts ?? 0)),
        });
      }

      // Missing server configuration must not consume a user's provider attempt.
      const apiKey = Deno.env.get("FREEFIRE_API_KEY");
      if (!apiKey) return json({ error: "The Free Fire profile provider is not configured on the server." }, 503);
      const base = (Deno.env.get("FREEFIRE_API_BASE_URL") ?? DEFAULT_BASE_URL).replace(/\/+$/, "");

      // The Postgres RPC is the only counter authority. It locks this account,
      // enforces a 15-second retry interval and reserves no more than 3 requests.
      const { data: gateData, error: gateError } = await admin.rpc("reserve_game_verification_attempt", {
        p_game_account_id: account.id,
        p_user_id: user.id,
        p_challenge_id: challenge.id,
      });
      if (gateError) return json({ error: "Could not reserve a verification request." }, 500);

      const gate = asRecord(gateData);
      if (gate.verified === true) {
        return json({ status: "verified", ownership_status: "verified", attempts_remaining: 0 });
      }
      if (gate.error === "account_not_found") {
        return json({ error: "This Free Fire account is no longer linked to your profile." }, 404);
      }
      if (gate.error === "challenge_not_found" || gate.error === "challenge_not_active") {
        return json({
          status: "no_active_code",
          error: "This verification code is no longer active. Generate a new code before retrying.",
        }, 409);
      }
      if (gate.expired === true) {
        return json({
          status: "expired",
          error: "This code expired after 30 minutes. Generate a new code; previous verification requests are not reset.",
          attempts_remaining: Number(gate.attempts_remaining ?? 0),
        });
      }
      if (gate.in_progress === true) {
        return json({
          status: "verifying",
          error: "A verification request is already running for this Free Fire profile. Wait for it to finish.",
          attempts_remaining: Number(gate.attempts_remaining ?? 0),
        });
      }
      if (gate.throttled === true) {
        return json({
          status: "throttled",
          retry_after_seconds: Number(gate.retry_after_seconds ?? VERIFY_RETRY_SECONDS),
          attempts_remaining: Number(gate.attempts_remaining ?? 0),
          error: "Please wait before starting another verification request. No attempt was consumed.",
        }, 429);
      }
      // The third reservation is allowed to make its final provider request.
      // The RPC returns locked=true and reserved=true for that third attempt;
      // only a non-reserved locked response must stop before fetch().
      if (gate.locked === true && gate.reserved !== true) {
        return json({
          status: "locked",
          attempts_remaining: 0,
          error: "You have used all three verification requests for this Free Fire profile. Contact KOMNIVO Support.",
        });
      }

      const attemptNumber = Number(gate.attempt_number);
      const attemptsRemaining = Number(gate.attempts_remaining);
      const attemptTime = new Date().toISOString();
      inFlightChallengeId = challenge.id;
      inFlightAttemptNumber = attemptNumber;

      let info: RecordData;
      try {
        // Exactly one Free Fire provider API request per verification attempt.
        // This /info response carries basicInfo AND socialInfo.signature (Bio).
        // Do not add a /stats request to this ownership-verification flow.
        const query = new URLSearchParams({
          region: String(account.region).toLowerCase(),
          uid: String(account.uid),
        });
        const response = await fetch(base + "/info?" + query.toString(), {
          headers: {
            "x-api-key": apiKey,
            "User-Agent": "KOMNIVO/1.0 (esports community app)",
          },
          signal: AbortSignal.timeout(15_000),
        });

        if (!response.ok) {
          const detail = response.status === 404
            ? "The provider could not find this UID in the selected region."
            : response.status === 429
              ? "The Free Fire provider rate-limited this request."
              : "The Free Fire provider returned HTTP " + response.status + ".";
          throw new Error(detail);
        }
        info = await response.json() as RecordData;
      } catch (providerError) {
        const locked = attemptNumber >= MAX_VERIFY_ATTEMPTS;
        // Release the in-flight challenge after every completed provider error.
        // The request was already counted, so the profile counter is unchanged.
        await admin.from("game_account_verification_challenges")
          .update({
            status: locked ? "locked" : "pending",
            updated_at: new Date().toISOString(),
          })
          .eq("id", challenge.id)
          .eq("status", "verifying");
        inFlightChallengeId = null;

        const detail = providerError instanceof Error
          ? providerError.message
          : "The provider could not complete this request.";
        return json({
          status: locked ? "locked" : "proof_pending",
          ownership_status: "proof_pending",
          error: locked
            ? "Your third verification request could not complete. Contact KOMNIVO Support for further verification. Provider detail: " + detail
            : detail + " This provider request has been counted.",
          verification_attempts: attemptNumber,
          attempts_remaining: attemptsRemaining,
          retry_after_seconds: VERIFY_RETRY_SECONDS,
        });
      }

      // This is the exact field shown in the owner's supplied response:
      // { "socialInfo": { "signature": "..." } }.
      const currentSignature = readProfileSignature(info);
      const observedHash = currentSignature ? await sha256Hex(currentSignature) : "";
      const matches = Boolean(observedHash) &&
        constantTimeHexEqual(observedHash, String(challenge.challenge_hash));

      // Use this same /info response for the profile lookup. No second API call.
      const profile = buildProfile(info, String(account.region).toLowerCase());
      const cleanInfo = withoutPublicBio(info);
      const stats = asRecord(info.stats ?? info.statsInfo ?? {});
      const syncedAt = new Date().toISOString();

      const { error: profileSaveError } = await admin.from("game_accounts")
        .update({
          nickname: profile.nickname === null ? null : String(profile.nickname),
          level: typeof profile.level === "number" ? profile.level : null,
          rank_label: profile.rank === null ? null : String(profile.rank),
          provider: PROVIDER,
          sync_status: "synced",
          last_synced_at: syncedAt,
          raw_profile: cleanInfo,
          raw_stats: stats,
          ownership_status: matches ? "verified" : "proof_pending",
          updated_at: syncedAt,
        })
        .eq("id", account.id)
        .eq("user_id", user.id);

      if (profileSaveError) {
        // Do not strand this challenge in the in-flight state. This provider
        // request remains counted even though the profile snapshot save failed.
        await admin.from("game_account_verification_challenges")
          .update({
            status: attemptNumber >= MAX_VERIFY_ATTEMPTS ? "locked" : "pending",
            updated_at: new Date().toISOString(),
          })
          .eq("id", challenge.id)
          .eq("status", "verifying");
        inFlightChallengeId = null;

        return json({
          status: attemptNumber >= MAX_VERIFY_ATTEMPTS ? "locked" : "proof_pending",
          error: "The provider response was received, but the game profile could not be saved securely. This request was counted. Contact Support if the issue persists.",
          attempts_remaining: attemptsRemaining,
        }, 500);
      }

      const { error: snapshotError } = await admin.from("game_profile_snapshots").insert({
        user_id: user.id,
        game_account_id: account.id,
        provider: PROVIDER,
        region: account.region,
        profile_json: cleanInfo,
        stats_json: stats,
      });
      if (snapshotError) {
        console.warn("Could not save game profile snapshot.", { code: snapshotError.code });
      }

      if (!matches) {
        const locked = attemptNumber >= MAX_VERIFY_ATTEMPTS;
        await admin.from("game_account_verification_challenges")
          .update({
            status: locked ? "locked" : "pending",
            updated_at: new Date().toISOString(),
          })
          .eq("id", challenge.id)
          .eq("status", "verifying");
        inFlightChallengeId = null;

        return json({
          status: locked ? "locked" : "proof_pending",
          ownership_status: "proof_pending",
          verified: false,
          profile,
          verification_attempts: attemptNumber,
          attempts_remaining: attemptsRemaining,
          retry_after_seconds: VERIFY_RETRY_SECONDS,
          error: locked
            ? "The exact Bio code did not match after three provider requests. Contact KOMNIVO Support for further verification."
            : "The latest profile Bio does not match the exact code. Replace the complete Bio with only the code, save it in-game, wait for provider refresh, then retry after 15 seconds.",
        });
      }

      const verifiedAt = new Date().toISOString();
      const { error: challengeUpdateError } = await admin.from("game_account_verification_challenges")
        .update({
          status: "verified",
          verified_at: verifiedAt,
          attempts: attemptNumber,
          last_attempt_at: attemptTime,
          updated_at: verifiedAt,
        })
        .eq("id", challenge.id)
        .eq("status", "verifying");
      inFlightChallengeId = null;

      if (challengeUpdateError) {
        console.warn("The account is verified but challenge audit update failed.", { code: challengeUpdateError.code });
      }

      await admin.from("notifications").insert({
        user_id: user.id,
        title: "Free Fire ownership verified",
        body: "KOMNIVO confirmed the exact code in your Free Fire profile Bio. You may now change your Bio back.",
        kind: "verification",
        entity_type: "game_account",
        entity_id: account.id,
      });

      return json({
        status: "verified",
        ownership_status: "verified",
        verified: true,
        verified_at: verifiedAt,
        profile,
        verification_attempts: attemptNumber,
        attempts_remaining: attemptsRemaining,
        message: "Free Fire ownership verified successfully. You may restore or change your Bio now.",
      });
    }

    return json({ error: "Unsupported action. Use prepare, status or verify." }, 400);
  } catch (error) {
    // Unexpected failures after reserving an attempt must not leave the
    // challenge permanently stuck in "verifying". The consumed request is
    // never refunded; a third reserved attempt remains Support-locked.
    if (inFlightChallengeId) {
      await admin.from("game_account_verification_challenges")
        .update({
          status: inFlightAttemptNumber >= MAX_VERIFY_ATTEMPTS ? "locked" : "pending",
          updated_at: new Date().toISOString(),
        })
        .eq("id", inFlightChallengeId)
        .eq("status", "verifying");
    }

    console.error("Free Fire verification handler failed.", {
      error_type: error instanceof Error ? error.name : "UnknownError",
    });
    return json({
      error: error instanceof Error ? error.message : "Free Fire verification request failed.",
    }, 500);
  }
});
