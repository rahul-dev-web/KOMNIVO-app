import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type JsonObject = Record<string, unknown>;

function json(body: JsonObject, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function objectValue(value: unknown): JsonObject {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as JsonObject
    : {};
}

function futureIso(value: unknown, label: string): Date {
  const raw = stringValue(value);
  if (!/(Z|[+-]\d{2}:\d{2})$/i.test(raw)) {
    throw new Error(label + " must include a timezone offset (for example +05:30).");
  }
  const date = new Date(raw);
  if (!Number.isFinite(date.getTime()) || date.getTime() <= Date.now()) {
    throw new Error(label + " must be a valid future date and time.");
  }
  return date;
}

function numberValue(value: unknown): number {
  if (typeof value === "number") return value;
  if (typeof value === "string" && value.trim()) return Number(value);
  return Number.NaN;
}

async function requireManager(
  admin: SupabaseClient,
  communityId: string,
  userId: string,
): Promise<{ id: string; name: string }> {
  const [{ data: community, error: communityError }, { data: member, error: memberError }] =
    await Promise.all([
      admin.from("communities").select("id,name,owner_user_id").eq("id", communityId).maybeSingle(),
      admin.from("community_members").select("role")
        .eq("community_id", communityId).eq("user_id", userId).maybeSingle(),
    ]);
  if (communityError || memberError) throw new Error("Unable to verify community organiser access.");
  const role = stringValue(member?.role);
  const authorised = Boolean(community && (
    community.owner_user_id === userId ||
    ["owner", "admin", "organiser"].includes(role)
  ));
  if (!authorised || !community) throw new Error("You need Owner, Admin or Organiser access to this community.");
  return { id: String(community.id), name: String(community.name ?? "Community") };
}

async function validatePayload(
  admin: SupabaseClient,
  userId: string,
  communityId: string,
  input: JsonObject,
): Promise<JsonObject> {
  const name = stringValue(input.name);
  if (name.length < 3 || name.length > 100) throw new Error("Tournament name must be 3–100 characters.");

  const format = stringValue(input.format);
  if (!["solo", "duo", "squad", "custom"].includes(format)) {
    throw new Error("Choose Solo, Duo, Squad or Custom mode.");
  }

  const capacity = numberValue(input.capacity);
  if (!Number.isInteger(capacity) || capacity < 1 || capacity > 1000) {
    throw new Error("Slots must be a whole number from 1 to 1000.");
  }

  const gameId = stringValue(input.game_id);
  const { data: game, error: gameError } = await admin.from("games")
    .select("id,code,name,is_active").eq("id", gameId).maybeSingle();
  if (gameError || !game || game.is_active !== true) throw new Error("Select an active supported game.");

  const registrationOpensAt = futureIso(input.registration_opens_at, "Registration start");
  const registrationClosesAt = futureIso(input.registration_closes_at, "Registration close");
  const startsAt = futureIso(input.starts_at, "Tournament start");
  if (registrationOpensAt.getTime() >= registrationClosesAt.getTime()) {
    throw new Error("Registration must close after registration starts.");
  }
  if (registrationClosesAt.getTime() >= startsAt.getTime()) {
    throw new Error("Tournament matches must start after registration closes.");
  }

  const eventConfig = objectValue(input.event_config);
  const stageCount = numberValue(eventConfig.stage_count);
  if (!Number.isInteger(stageCount) || stageCount < 1 || stageCount > 16) {
    throw new Error("Stage count must be a whole number from 1 to 16.");
  }

  const stageNames = Array.isArray(eventConfig.stage_names)
    ? eventConfig.stage_names.map((value) => String(value ?? "").trim()).filter(Boolean)
    : [];
  if (stageNames.length > 0 && stageNames.length !== stageCount) {
    throw new Error("Enter a name for every stage, or leave all stage names blank for Coming soon.");
  }
  if (stageNames.some((value) => value.length > 60)) {
    throw new Error("Each stage name must be 60 characters or fewer.");
  }
  if (new Set(stageNames.map((value) => value.toLowerCase())).size !== stageNames.length) {
    throw new Error("Stage names must be unique.");
  }

  const roadmap = eventConfig.roadmap == null ? null : objectValue(eventConfig.roadmap);
  if (roadmap && Object.keys(roadmap).length > 0) {
    const groupSize = numberValue(roadmap.group_size);
    const qualifiers = numberValue(roadmap.qualifiers_per_group);
    const nextRoundCount = numberValue(roadmap.next_round_team_count);
    const qualified = numberValue(roadmap.qualified_team_count);
    const invited = numberValue(roadmap.direct_invites);
    if (![groupSize, qualifiers, nextRoundCount, qualified, invited].every(Number.isInteger)) {
      throw new Error("Complete every roadmap field or leave the roadmap unset for Coming soon.");
    }
    if (groupSize < 2 || groupSize > 1000 || qualifiers < 1 || qualifiers > groupSize ||
      nextRoundCount < 1 || qualified < 0 || invited < 0 || qualified + invited !== nextRoundCount) {
      throw new Error("Roadmap values are inconsistent. Qualified teams plus direct invites must equal the next-round team count.");
    }
  }

  const prizePool = numberValue(eventConfig.prize_pool_amount);
  if (!Number.isFinite(prizePool) || prizePool < 0 || prizePool > 100000000) {
    throw new Error("Prize pool must be a valid INR amount.");
  }
  const prizeDistribution = stringValue(eventConfig.prize_distribution);
  if (prizeDistribution.length > 2000) throw new Error("Prize distribution must be 2,000 characters or fewer.");

  const entryType = stringValue(eventConfig.entry_type);
  const entryFee = eventConfig.entry_fee == null ? null : numberValue(eventConfig.entry_fee);
  if (!["free", "paid"].includes(entryType)) throw new Error("Choose Free or Paid entry.");
  if (entryType === "paid" && (!Number.isFinite(entryFee) || entryFee! <= 0 || entryFee! > 1000000)) {
    throw new Error("Paid entry requires a positive fee not exceeding ₹10,00,000.");
  }
  if (entryType === "free" && entryFee != null && entryFee !== 0) {
    throw new Error("Free entry cannot have an entry fee.");
  }

  const rulesSource = stringValue(eventConfig.rules_source);
  let rulesJson = objectValue(input.rules_json);
  let scoringConfig = objectValue(input.scoring_config);
  let rulebook: JsonObject | null = null;
  if (rulesSource === "standard") {
    const rulebookId = stringValue(objectValue(eventConfig.rulebook).id);
    if (!rulebookId) throw new Error("Select a standard rulebook for this game and mode.");
    const { data, error } = await admin.from("tournament_rulebooks")
      .select("id,title,version,region,mode_scope,scope,source_title,source_url,rules_config,scoring_config")
      .eq("id", rulebookId)
      .eq("game_id", gameId)
      .eq("is_active", true)
      .maybeSingle();
    if (error || !data || !(Array.isArray(data.mode_scope) && data.mode_scope.includes(format))) {
      throw new Error("That rulebook is no longer available for the selected game and mode.");
    }
    rulebook = {
      id: data.id,
      title: data.title,
      version: data.version,
      region: data.region,
      scope: data.scope,
      source_title: data.source_title,
      source_url: data.source_url,
    };
    rulesJson = objectValue(data.rules_config);
    scoringConfig = objectValue(data.scoring_config);
    eventConfig.rulebook = rulebook;
  } else if (rulesSource === "custom") {
    const customText = stringValue(rulesJson.custom_text);
    if (customText.length < 10) throw new Error("Enter the custom rule details (at least 10 characters).");
    if (JSON.stringify(scoringConfig).length > 12000) throw new Error("Scoring configuration is too large.");
    eventConfig.rulebook = null;
  } else {
    throw new Error("Choose Standard rulebook or Custom rules.");
  }

  const bannerPath = stringValue(input.banner_path);
  if (bannerPath && !bannerPath.startsWith(communityId + "/" + userId + "/")) {
    throw new Error("Banner upload does not belong to this organiser and community.");
  }
  if (JSON.stringify(rulesJson).length > 20000 || JSON.stringify(scoringConfig).length > 20000) {
    throw new Error("Rules or scoring configuration is too large.");
  }

  eventConfig.stage_names = stageNames;
  eventConfig.roadmap = roadmap && Object.keys(roadmap).length > 0 ? roadmap : null;
  eventConfig.entry_fee = entryType === "paid" ? entryFee : null;
  eventConfig.entry_type = entryType;
  eventConfig.prize_pool_amount = prizePool;
  eventConfig.prize_pool_currency = "INR";
  eventConfig.prize_distribution = prizeDistribution;
  eventConfig.rules_source = rulesSource;
  eventConfig.rulebook = rulebook;
  eventConfig.banner_path = bannerPath || null;

  return {
    name,
    description: stringValue(input.description).slice(0, 2000),
    game_id: gameId,
    game_code: String(game.code),
    game_name: String(game.name),
    format,
    capacity,
    starts_at: startsAt.toISOString(),
    registration_opens_at: registrationOpensAt.toISOString(),
    registration_closes_at: registrationClosesAt.toISOString(),
    community_id: communityId,
    rules_json: rulesJson,
    scoring_config: scoringConfig,
    event_config: eventConfig,
    banner_path: bannerPath || null,
  };
}

async function preparePrivateRulebookDownload(
  admin: SupabaseClient,
  rulebook: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  let storagePath = stringValue(rulebook.storage_path);
  let fileSize = numberValue(rulebook.file_size_bytes);
  let downloadError: string | null = null;

  if (!storagePath) {
    const sourceUrl = stringValue(rulebook.source_url);
    if (!sourceUrl.toLowerCase().endsWith(".pdf")) {
      return { ...rulebook, storage_path: null, download_url: sourceUrl, official_downloaded: false };
    }

    try {
      const response = await fetch(sourceUrl, { signal: AbortSignal.timeout(20000) });
      if (!response.ok) throw new Error("Official source returned HTTP " + response.status + ".");
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (bytes.length < 100 || bytes.length > 25 * 1024 * 1024) {
        throw new Error("Official PDF size is outside the allowed 25 MB limit.");
      }
      const signature = new TextDecoder().decode(bytes.slice(0, 5));
      if (signature !== "%PDF-") throw new Error("Official source response is not a PDF file.");

      const safeVersion = stringValue(rulebook.version).replace(/[^a-zA-Z0-9._-]+/g, "-");
      const safeTitle = stringValue(rulebook.title).toLowerCase().replace(/[^a-z0-9]+/g, "-").slice(0, 70);
      storagePath = String(rulebook.game_id) + "/" + safeTitle + "-" + safeVersion + ".pdf";
      const { error: uploadError } = await admin.storage.from("tournament-rulebooks").upload(
        storagePath,
        bytes,
        { contentType: "application/pdf", upsert: true },
      );
      if (uploadError) throw new Error("Could not save the official PDF in private Storage.");
      fileSize = bytes.length;

      await admin.from("tournament_rulebooks").update({
        storage_path: storagePath,
        file_size_bytes: fileSize,
        downloaded_at: new Date().toISOString(),
        download_error: null,
        source_checked_at: new Date().toISOString(),
      }).eq("id", String(rulebook.id));
    } catch (error) {
      downloadError = error instanceof Error ? error.message : "Official PDF download failed.";
      await admin.from("tournament_rulebooks").update({
        download_error: downloadError.slice(0, 240),
        source_checked_at: new Date().toISOString(),
      }).eq("id", String(rulebook.id));
      console.warn("[organizer-tournament-workflow] Official rulebook download could not be cached:", downloadError);
    }
  }

  let downloadUrl = stringValue(rulebook.source_url);
  if (storagePath) {
    const { data: signed, error } = await admin.storage
      .from("tournament-rulebooks")
      .createSignedUrl(storagePath, 60 * 60);
    if (!error && signed?.signedUrl) downloadUrl = signed.signedUrl;
  }

  return {
    ...rulebook,
    storage_path: storagePath || null,
    file_size_bytes: Number.isFinite(fileSize) ? fileSize : null,
    download_url: downloadUrl,
    official_downloaded: Boolean(storagePath),
    download_error: downloadError ?? rulebook.download_error ?? null,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authorization = req.headers.get("Authorization") ?? "";
  if (!authorization.toLowerCase().startsWith("bearer ")) {
    return json({ error: "Authentication required." }, 401);
  }

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return json({ error: "Tournament workflow is not configured." }, 503);

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return json({ error: "Invalid or expired session." }, 401);
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  let body: JsonObject;
  try {
    const parsed = await req.json();
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return json({ error: "Request body must be a JSON object." }, 400);
    }
    body = parsed as JsonObject;
  } catch {
    return json({ error: "Request body must be valid JSON." }, 400);
  }

  const action = stringValue(body.action);
  const communityId = stringValue(body.community_id);
  try {
    if (!communityId) return json({ error: "Choose a community first." }, 400);
    const community = await requireManager(admin, communityId, user.id);

    if (action === "rulebooks") {
      const gameId = stringValue(body.game_id);
      const mode = stringValue(body.format);
      const { data, error } = await admin.from("tournament_rulebooks")
        .select("id,game_id,title,version,region,mode_scope,scope,source_title,source_url,storage_path,file_size_bytes,downloaded_at,download_error,rules_config,scoring_config,notes")
        .eq("game_id", gameId)
        .eq("is_active", true)
        .contains("mode_scope", [mode])
        .order("title");
      if (error) throw new Error("Could not load standard rulebooks.");
      const prepared = await Promise.all((data ?? []).map((row) =>
        preparePrivateRulebookDownload(admin, row as Record<string, unknown>),
      ));
      return json({ rulebooks: prepared, community_name: community.name });
    }

    if (action === "create_proposal") {
      const rawPayload = objectValue(body.payload);
      const payload = await validatePayload(admin, user.id, communityId, rawPayload);
      const idempotencyKey = stringValue(body.idempotency_key);
      if (idempotencyKey.length < 8 || idempotencyKey.length > 120) {
        return json({ error: "A valid request id is required." }, 400);
      }

      const idempotencyKey = stringValue(body.idempotency_key);
      if (idempotencyKey.length < 8 || idempotencyKey.length > 120) {
        return json({ error: "A valid request id is required." }, 400);
      }

      const { data: prior } = await admin.from("tournament_proposals")
        .select("id,status,payload,expires_at,event_id,conversation_id")
        .eq("owner_user_id", user.id)
        .eq("idempotency_key", idempotencyKey)
        .maybeSingle();
      if (prior) {
        if (prior.conversation_id) {
          await admin.from("ai_conversations").update({ updated_at: new Date().toISOString() })
            .eq("id", prior.conversation_id).eq("owner_user_id", user.id);
        }
        return json({
          conversation_id: prior.conversation_id,
          proposal: {
            id: prior.id,
            status: prior.status,
            expires_at: prior.expires_at,
            event_id: prior.event_id,
            ...objectValue(prior.payload),
          },
          already_received: true,
        });
      }

      let conversationId = stringValue(body.conversation_id) || null;
      if (conversationId) {
        const { data: conversation, error } = await admin.from("ai_conversations")
          .select("id,owner_user_id,mode,community_id")
          .eq("id", conversationId).eq("owner_user_id", user.id).maybeSingle();
        if (error || !conversation || conversation.mode !== "organizer" ||
          conversation.community_id !== communityId) {
          return json({ error: "The selected Organizer AI conversation does not match this community." }, 403);
        }
      } else {
        const { data: conversation, error } = await admin.from("ai_conversations").insert({
          owner_user_id: user.id,
          mode: "organizer",
          community_id: communityId,
          title: ("Tournament: " + String(payload.name)).slice(0, 120),
        }).select("id").single();
        if (error || !conversation) throw new Error("Could not start an Organizer AI conversation.");
        conversationId = String(conversation.id);
      }

      const sourceRefs = selectedRulebook.id
        ? [{ document: stringValue(selectedRulebook.title), source: stringValue(selectedRulebook.source_url), version: stringValue(selectedRulebook.version) }]
        : [];
      const { data: proposal, error: proposalError } = await admin.from("tournament_proposals").insert({
        conversation_id: conversationId,
        owner_user_id: user.id,
        community_id: communityId,
        idempotency_key: idempotencyKey,
        payload,
        source_refs: sourceRefs,
        status: "pending_approval",
        expires_at: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
      }).select("id,status,expires_at,event_id").single();
      if (proposalError || !proposal) {
        const { data: recovered } = await admin.from("tournament_proposals")
          .select("id,status,payload,expires_at,event_id,conversation_id")
          .eq("owner_user_id", user.id).eq("idempotency_key", idempotencyKey).maybeSingle();
        if (recovered) {
          return json({
            conversation_id: recovered.conversation_id ?? conversationId,
            proposal: {
              id: recovered.id,
              status: recovered.status,
              expires_at: recovered.expires_at,
              event_id: recovered.event_id,
              ...objectValue(recovered.payload),
            },
            already_received: true,
          });
        }
        throw new Error("Could not save the tournament proposal.");
      }

      await admin.from("ai_conversations").update({ updated_at: new Date().toISOString() })
        .eq("id", conversationId).eq("owner_user_id", user.id);

      return json({
        conversation_id: conversationId,
        proposal: {
          id: proposal.id,
          workflow_type: "tournament",
          status: proposal.status,
          expires_at: proposal.expires_at,
          source_refs: sourceRefs,
          ...payload,
        },
      });
    }

    if (action === "resolve_proposal") {
      const proposalId = stringValue(body.proposal_id);
      const decision = stringValue(body.decision);
      if (!proposalId || !["approve", "reject"].includes(decision)) {
        return json({ error: "proposal_id and decision are required." }, 400);
      }
      const { data: result, error } = await admin.rpc("resolve_tournament_proposal", {
        p_proposal_id: proposalId,
        p_user_id: user.id,
        p_decision: decision,
      });
      if (error) {
        const message = String(error.message ?? "");
        const status = message.includes("permission") ? 403
          : message.includes("not awaiting") || message.includes("expired") ? 409
          : 400;
        return json({ error: message || "Could not resolve the tournament proposal." }, status);
      }
      const { data: linkedProposal } = await admin.from("tournament_proposals")
        .select("conversation_id")
        .eq("id", proposalId).eq("owner_user_id", user.id).maybeSingle();
      if (linkedProposal?.conversation_id) {
        await admin.from("ai_conversations").update({ updated_at: new Date().toISOString() })
          .eq("id", linkedProposal.conversation_id).eq("owner_user_id", user.id);
      }
      return json({
        ...(result && typeof result === "object" ? result as JsonObject : { result }),
        decision,
        published: false,
      });
    }

    if (action === "update_draft") {
      const eventId = stringValue(body.event_id);
      if (!eventId) return json({ error: "Event id is required." }, 400);
      const { data: event, error: eventError } = await admin.from("events")
        .select("id,community_id,organizer_id,status")
        .eq("id", eventId).maybeSingle();
      if (eventError || !event) return json({ error: "Tournament not found." }, 404);
      if (event.community_id !== communityId) return json({ error: "Community scope mismatch." }, 403);
      const payload = await validatePayload(admin, user.id, communityId, objectValue(body.payload));
      const { data: result, error } = await admin.rpc("update_tournament_draft", {
        p_event_id: eventId,
        p_user_id: user.id,
        p_payload: payload,
      });
      if (error) {
        const message = String(error.message ?? "");
        return json({ error: message || "Could not save tournament changes." }, message.includes("permission") ? 403 : 409);
      }
      return json({ ...(result as JsonObject), name: payload.name });
    }

    return json({ error: "Unsupported tournament workflow action." }, 400);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Tournament workflow failed.";
    return json({ error: message }, 400);
  }
});
