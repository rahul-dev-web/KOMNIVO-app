import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { PDFDocument, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";

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

async function ensureTournamentDraft(
  admin: SupabaseClient,
  userId: string,
  proposalId: string,
): Promise<{ eventId: string; eventStatus: string }> {
  const { data: current, error: currentError } = await admin.from("tournament_proposals")
    .select("id,status,event_id").eq("id", proposalId).eq("owner_user_id", userId).maybeSingle();
  if (currentError || !current) throw new Error("Saved tournament proposal could not be recovered.");

  if (current.status === "pending_approval") {
    const { error } = await admin.rpc("resolve_tournament_proposal", {
      p_proposal_id: proposalId,
      p_user_id: userId,
      p_decision: "approve",
    });
    if (error) {
      // A concurrent retry may have completed the same proposal while this
      // request waited for the proposal row lock. Accept that committed draft.
      const { data: raced, error: racedError } = await admin.from("tournament_proposals")
        .select("status,event_id").eq("id", proposalId).eq("owner_user_id", userId).maybeSingle();
      if (racedError || raced?.status !== "approved" || !raced.event_id) {
        throw new Error(String(error.message ?? "Could not create the tournament DRAFT event."));
      }
    }
  }

  const { data: resolved, error: resolvedError } = await admin.from("tournament_proposals")
    .select("id,status,event_id").eq("id", proposalId).eq("owner_user_id", userId).maybeSingle();
  if (resolvedError || !resolved || !resolved.event_id || resolved.status !== "approved") {
    throw new Error("Tournament details were saved, but the DRAFT event could not be confirmed. Retry the save.");
  }
  const { data: event, error: eventError } = await admin.from("events")
    .select("id,status").eq("id", resolved.event_id).maybeSingle();
  if (eventError || !event) throw new Error("The saved tournament event could not be loaded.");
  return { eventId: String(event.id), eventStatus: String(event.status) };
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
  if (gameError || !game || game.is_active !== true ||
      !["free_fire_india", "bgmi"].includes(String(game.code))) {
    throw new Error("Select Free Fire India or Battlegrounds Mobile India.");
  }

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

async function buildCleanFreeFireIndiaRulebook(): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  pdf.setTitle("Free Fire India Rulebook - KOMNIVO Curated Baseline");
  pdf.setAuthor("KOMNIVO");
  pdf.setSubject("Game settings, map rotation, match scoring and tie-breakers");
  pdf.setKeywords(["Free Fire India", "tournament", "rules", "scoring"]);
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const navy = rgb(0.055, 0.085, 0.15);
  const ink = rgb(0.12, 0.16, 0.22);
  const muted = rgb(0.35, 0.40, 0.47);
  const cyan = rgb(0.0, 0.48, 0.57);
  const amber = rgb(0.92, 0.60, 0.12);
  const white = rgb(1, 1, 1);
  const pageWidth = 595.28;
  const pageHeight = 841.89;
  const margin = 48;
  let page = pdf.addPage([pageWidth, pageHeight]);
  let y = pageHeight - margin;

  const footer = (target: typeof page, pageNo: number) => {
    target.drawLine({
      start: { x: margin, y: 38 },
      end: { x: pageWidth - margin, y: 38 },
      thickness: 0.6,
      color: rgb(0.82, 0.85, 0.89),
    });
    target.drawText("KOMNIVO | FREE FIRE INDIA RULEBOOK | CURATED BASELINE", {
      x: margin, y: 23, size: 7.2, font: regular, color: muted,
    });
    target.drawText("Page " + pageNo, {
      x: pageWidth - margin - 38, y: 23, size: 7.2, font: regular, color: muted,
    });
  };

  const newPage = (title?: string) => {
    page = pdf.addPage([pageWidth, pageHeight]);
    y = pageHeight - margin;
    page.drawText("KOMNIVO  /  FREE FIRE INDIA RULEBOOK", {
      x: margin, y, size: 8, font: bold, color: cyan,
    });
    y -= 28;
    if (title) {
      page.drawText(title, { x: margin, y, size: 18, font: bold, color: navy });
      y -= 30;
    }
    return page;
  };

  const wrap = (text: string, font: typeof regular, size: number, maxWidth: number): string[] => {
    const words = text.split(/\s+/).filter(Boolean);
    const lines: string[] = [];
    let line = "";
    for (const word of words) {
      const candidate = line ? line + " " + word : word;
      if (font.widthOfTextAtSize(candidate, size) <= maxWidth || !line) {
        line = candidate;
      } else {
        lines.push(line);
        line = word;
      }
    }
    if (line) lines.push(line);
    return lines;
  };

  const paragraph = (
    text: string,
    options: { size?: number; font?: typeof regular; color?: typeof ink; indent?: number; gap?: number } = {},
  ) => {
    const size = options.size ?? 10;
    const font = options.font ?? regular;
    const color = options.color ?? ink;
    const indent = options.indent ?? 0;
    const gap = options.gap ?? 6;
    for (const line of wrap(text, font, size, pageWidth - margin * 2 - indent)) {
      if (y < 62) newPage();
      page.drawText(line, { x: margin + indent, y, size, font, color });
      y -= size * 1.45;
    }
    y -= gap;
  };

  const heading = (text: string) => {
    if (y < 100) newPage();
    y -= 6;
    page.drawText(text, { x: margin, y, size: 14, font: bold, color: navy });
    y -= 22;
  };

  const bullet = (text: string) => paragraph("- " + text, { indent: 10, gap: 3 });

  // Cover and status: the PDF is deliberately not presented as a Garena-issued document.
  page.drawRectangle({
    x: margin, y: pageHeight - 285, width: pageWidth - margin * 2, height: 245, color: navy,
  });
  page.drawText("KOMNIVO", { x: margin + 30, y: pageHeight - 82, size: 10, font: bold, color: rgb(0.78,0.85,0.92) });
  page.drawText("FREE FIRE INDIA", { x: margin + 30, y: pageHeight - 145, size: 28, font: bold, color: white });
  page.drawText("RULEBOOK", { x: margin + 30, y: pageHeight - 181, size: 28, font: bold, color: white });
  page.drawText("Tournament gameplay settings, map selection and scoring baseline", {
    x: margin + 30, y: pageHeight - 216, size: 10.5, font: regular, color: rgb(0.84,0.89,0.95),
  });
  page.drawText("Version 1.0  |  21 November 2026  |  Squad / team Battle Royale", {
    x: margin + 30, y: pageHeight - 254, size: 8.5, font: regular, color: rgb(0.84,0.89,0.95),
  });
  y = pageHeight - 325;
  page.drawRectangle({
    x: margin, y: y - 80, width: pageWidth - margin * 2, height: 78,
    color: rgb(1,0.96,0.88), borderColor: amber, borderWidth: 0.8,
  });
  page.drawText("IMPORTANT STATUS", { x: margin + 12, y: y - 21, size: 9, font: bold, color: rgb(0.53,0.32,0.03) });
  y -= 39;
  for (const line of wrap(
    "This is a KOMNIVO-curated organiser baseline prepared from the PDF supplied for this project. It is not an official Garena publication and must not be represented as one. The source PDF was an Esports World Cup 2026 competition rulebook; EWC-only participant, qualification, stage, schedule, prize, region, staffing and event-administration rules have been removed.",
    regular, 8.5, pageWidth - margin * 2 - 24,
  )) {
    page.drawText(line, { x: margin + 12, y, size: 8.5, font: regular, color: ink });
    y -= 12;
  }
  y -= 60;
  heading("How to apply this document");
  paragraph(
    "Use these settings as a starting preset for a Free Fire India Squad tournament. The organiser must confirm the current in-game options, active map pool, available modes and tournament-specific changes before publishing an event.",
  );
  paragraph(
    "The source map pool and settings are version-sensitive. Custom organiser rules may override this baseline only when the change is stated in the event rules and communicated consistently to all teams.",
    { color: muted, size: 8.5 },
  );

  newPage("1. Scope and organiser responsibilities");
  paragraph(
    "This baseline covers match setup, map selection, scoring and ranking for a Free Fire India Squad tournament. It does not prescribe participant eligibility, roster locks, regional qualification, team ownership, prize distribution, travel, venue operations, referee staffing, sanctions, privacy terms or any named competition format.",
  );
  heading("1.1 Organiser confirmation before each event");
  bullet("Confirm the current Free Fire India client version and the options available in the tournament lobby.");
  bullet("Confirm the active map pool. Maps can change as the game is updated; the list below is a source-derived starting point, not a permanent guarantee.");
  bullet("Publish the selected mode, match settings, map policy, scoring table and tie-breakers before registration closes.");
  bullet("State any event-specific exception explicitly. Do not assume that a past competition rule remains current.");
  paragraph("Version-sensitive values: the five-map list and match-setting toggles are retained from the supplied 2026 document and must be checked against the current Free Fire India game client.", {
    size: 8.7, font: bold, color: cyan,
  });

  newPage("2. Game settings baseline");
  paragraph(
    "Recommended starting configuration from the supplied source. An organiser may change a setting only when the change is stated in the event rules and communicated consistently to all teams.",
  );
  const settings = [
    ["Game mode", "Esports"],
    ["Gun Property / Weapon Stats", "Off"],
    ["Revival", "On"],
    ["Hide Nickname and Kill Feed", "On"],
    ["Generic Enemy Outfit", "On"],
    ["High-tier Loot Zone", "Off"],
    ["Death Cam", "On"],
    ["In-game Missions", "On"],
    ["In-game Quests", "Off"],
    ["Safe Zone Moving", "On"],
    ["Loadouts", "Allowed"],
  ];
  const rowHeight = 22;
  const col1 = margin;
  const col2 = margin + 265;
  const tableWidth = pageWidth - margin * 2;
  page.drawRectangle({ x: col1, y: y - rowHeight, width: tableWidth, height: rowHeight, color: navy });
  page.drawText("Setting", { x: col1 + 8, y: y - 15, size: 9, font: bold, color: white });
  page.drawText("Baseline", { x: col2 + 8, y: y - 15, size: 9, font: bold, color: white });
  y -= rowHeight;
  for (let i = 0; i < settings.length; i++) {
    const [label, value] = settings[i];
    page.drawRectangle({
      x: col1, y: y - rowHeight, width: tableWidth, height: rowHeight,
      color: i % 2 === 0 ? rgb(0.94,0.96,0.98) : white,
      borderColor: rgb(0.82,0.85,0.89), borderWidth: 0.35,
    });
    page.drawText(label, { x: col1 + 8, y: y - 15, size: 8.5, font: bold, color: ink });
    page.drawText(value, { x: col2 + 8, y: y - 15, size: 8.5, font: regular, color: ink });
    y -= rowHeight;
  }
  y -= 18;
  heading("2.1 Map pool");
  paragraph("Source-listed starting pool: Bermuda, Purgatory, Kalahari, NexTerra and Solara. Use only maps currently available in the Free Fire India client. If the live pool differs, publish the corrected pool in the tournament rules before the first match.");

  newPage("3. Map selection and rotation");
  paragraph(
    "The source document randomises maps from the five-map pool without repeats during the first full cycle. Its fixed Group Stage, Survival Stage and Finals schedules have deliberately been removed.",
  );
  heading("3.1 Generic organiser baseline");
  bullet("Publish the eligible map pool and randomisation method before the first match.");
  bullet("For the first full five-match cycle, select each eligible map once in a random order.");
  bullet("For later cycles, reshuffle the pool and avoid repeating a map until the current cycle has used all eligible maps, unless the event rules explicitly define a different policy.");
  bullet("Record the generated order so that organisers can resolve disputes consistently.");
  bullet("If fewer than five maps are available in the live game client, build the cycle from the confirmed available pool and state the change before the event.");
  heading("3.2 No fixed tournament stage schedule");
  paragraph(
    "This baseline does not define group count, survival stages, finals, match count per day, fixed dates, seeding pools, qualification slots or a Match Point threshold. These values belong to the organiser's own tournament roadmap and must be configured separately.",
    { color: muted },
  );

  newPage("4. Match scoring and ranking");
  paragraph("The source scoring system awards one point per kill plus placement points. The table below reproduces the values from the supplied source document.");
  heading("4.1 Placement points");
  const placements = [
    ["1", "12"], ["2", "9"], ["3", "8"], ["4", "7"], ["5", "6"], ["6", "5"],
    ["7", "4"], ["8", "3"], ["9", "2"], ["10", "1"], ["11", "0"], ["12", "0"],
  ];
  const half = (pageWidth - margin * 2) / 2;
  page.drawRectangle({ x: margin, y: y - rowHeight, width: half, height: rowHeight, color: navy });
  page.drawRectangle({ x: margin + half, y: y - rowHeight, width: half, height: rowHeight, color: navy });
  page.drawText("Placement", { x: margin + 8, y: y - 15, size: 9, font: bold, color: white });
  page.drawText("Points", { x: margin + half + 8, y: y - 15, size: 9, font: bold, color: white });
  y -= rowHeight;
  for (let i = 0; i < placements.length; i++) {
    const [place, points] = placements[i];
    page.drawRectangle({ x: margin, y: y - rowHeight, width: half, height: rowHeight, color: i % 2 === 0 ? rgb(0.94,0.96,0.98) : white, borderColor: rgb(0.82,0.85,0.89), borderWidth: 0.35 });
    page.drawRectangle({ x: margin + half, y: y - rowHeight, width: half, height: rowHeight, color: i % 2 === 0 ? rgb(0.94,0.96,0.98) : white, borderColor: rgb(0.82,0.85,0.89), borderWidth: 0.35 });
    page.drawText(place, { x: margin + 8, y: y - 15, size: 8.5, font: bold, color: ink });
    page.drawText(points, { x: margin + half + 8, y: y - 15, size: 8.5, font: regular, color: ink });
    y -= rowHeight;
  }
  y -= 10;
  paragraph("Kill point: 1 kill = 1 point.", { font: bold });
  heading("4.2 Tie-breakers");
  paragraph("When teams finish on equal total points, use the following order:");
  bullet("Total Booyahs across all matches in the tournament phase.");
  bullet("Total accumulated kills across all matches in the tournament phase.");
  bullet("Placement in the most recent match in which all tied teams competed together.");
  paragraph(
    "These tie-breakers have been generalised from the source wording. An organiser must define the period of calculation (for example, a round or the full event) and publish it before competition starts.",
    { color: muted, size: 8.5 },
  );
  heading("5. Source and exclusions");
  paragraph("Source supplied by the organiser: Free Fire at 2026 Esports World Cup - Game Rulebook (29 pages), sections 5.1, 5.1.1, 5.4 and 5.5, printed source pages 16-22. Source link: https://drive.google.com/file/d/1JJG27CKPvGDh-azyqxFpDzuL0QM0bLuB/view?usp=drive_link", { size: 8.2 });
  paragraph("Removed: EWC eligibility and participant clauses, age and roster rules, region/residency restrictions, qualification slots, group/seeding structure, Survival Stage/Finals format, fixed event dates and match counts, Match Point threshold, EWC-only character/pet restrictions, event-specific banned skins, administration procedures, penalties, staff rules, prizes, travel, venue, equipment logistics and privacy clauses.", { size: 8.2 });
  paragraph("This is a curated baseline, not a replacement for current Garena game policies or tournament-specific organiser rules. The current patch and event requirements always take precedence.", { font: bold, color: cyan, size: 8.2 });

  for (let i = 0; i < pdf.getPageCount(); i++) footer(pdf.getPage(i), i + 1);
  return await pdf.save();
}

async function preparePrivateRulebookDownload(
  admin: SupabaseClient,
  rulebook: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  let storagePath = stringValue(rulebook.storage_path);
  let fileSize = numberValue(rulebook.file_size_bytes);
  let downloadError: string | null = null;

  if (!storagePath) {
    try {
      let bytes: Uint8Array;
      if (stringValue(rulebook.title) === "Free Fire India Rulebook") {
        // Build a clean copy from only the reusable gameplay and scoring clauses
        // already curated from the organiser-supplied EWC source document.
        bytes = await buildCleanFreeFireIndiaRulebook();
      } else {
        const sourceUrl = stringValue(rulebook.source_url);
        if (!sourceUrl.toLowerCase().endsWith(".pdf")) {
          return { ...rulebook, storage_path: null, download_url: sourceUrl, official_downloaded: false };
        }
        const response = await fetch(sourceUrl, { signal: AbortSignal.timeout(20000) });
        if (!response.ok) throw new Error("Official source returned HTTP " + response.status + ".");
        bytes = new Uint8Array(await response.arrayBuffer());
      }

      if (bytes.length < 100 || bytes.length > 25 * 1024 * 1024) {
        throw new Error("Rulebook PDF size is outside the allowed 25 MB limit.");
      }
      const signature = new TextDecoder().decode(bytes.slice(0, 5));
      if (signature !== "%PDF-") throw new Error("Generated rulebook output is not a valid PDF.");

      const safeVersion = stringValue(rulebook.version).replace(/[^a-zA-Z0-9._-]+/g, "-");
      const safeTitle = stringValue(rulebook.title).toLowerCase().replace(/[^a-z0-9]+/g, "-").slice(0, 70);
      storagePath = String(rulebook.game_id) + "/" + safeTitle + "-" + safeVersion + ".pdf";
      const { error: uploadError } = await admin.storage.from("tournament-rulebooks").upload(
        storagePath,
        bytes,
        { contentType: "application/pdf", upsert: true },
      );
      if (uploadError) throw new Error("Could not save the curated rulebook in private Storage.");
      fileSize = bytes.length;

      await admin.from("tournament_rulebooks").update({
        storage_path: storagePath,
        file_size_bytes: fileSize,
        downloaded_at: new Date().toISOString(),
        download_error: null,
        source_checked_at: new Date().toISOString(),
      }).eq("id", String(rulebook.id));
    } catch (error) {
      downloadError = error instanceof Error ? error.message : "Rulebook PDF preparation failed.";
      await admin.from("tournament_rulebooks").update({
        download_error: downloadError.slice(0, 240),
        source_checked_at: new Date().toISOString(),
      }).eq("id", String(rulebook.id));
      console.warn("[organizer-tournament-workflow] Rulebook PDF preparation failed:", downloadError);
    }
  }

  const isCleanedFreeFireRulebook = stringValue(rulebook.title) === "Free Fire India Rulebook";
  // Never send the organiser to the unfiltered EWC source as the rulebook download.
  // Only the generated, EWC-cleaned private copy is exposed for Free Fire India.
  let downloadUrl = isCleanedFreeFireRulebook ? "" : stringValue(rulebook.source_url);
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
    official_downloaded: Boolean(storagePath) && !isCleanedFreeFireRulebook,
    download_available: Boolean(storagePath && downloadUrl),
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
        preparePrivateRulebookDownload(admin, row as unknown as Record<string, unknown>),
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

      const { data: prior } = await admin.from("tournament_proposals")
        .select("id,status,payload,expires_at,event_id,conversation_id,community_id")
        .eq("owner_user_id", user.id)
        .eq("idempotency_key", idempotencyKey)
        .maybeSingle();
      if (prior) {
        if (prior.community_id !== communityId) {
          return json({ error: "This request id is already assigned to a different community." }, 409);
        }
        if (prior.conversation_id) {
          await admin.from("ai_conversations").update({ updated_at: new Date().toISOString() })
            .eq("id", prior.conversation_id).eq("owner_user_id", user.id);
        }
        const draft = await ensureTournamentDraft(admin, user.id, String(prior.id));
        return json({
          conversation_id: prior.conversation_id,
          proposal: {
            id: prior.id,
            status: draft.eventStatus,
            event_status: draft.eventStatus,
            expires_at: prior.expires_at,
            event_id: draft.eventId,
            community_id: prior.community_id,
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

      const selectedRulebook = objectValue(objectValue(payload.event_config).rulebook);
      const sourceRefs = stringValue(selectedRulebook.id)
        ? [{
            document: stringValue(selectedRulebook.title),
            source: stringValue(selectedRulebook.source_url),
            version: stringValue(selectedRulebook.version),
          }]
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
          const draft = await ensureTournamentDraft(admin, user.id, String(recovered.id));
          return json({
            conversation_id: recovered.conversation_id ?? conversationId,
            proposal: {
              id: recovered.id,
              workflow_type: "tournament",
              status: draft.eventStatus,
              event_status: draft.eventStatus,
              expires_at: recovered.expires_at,
              event_id: draft.eventId,
              community_id: communityId,
              ...objectValue(recovered.payload),
            },
            already_received: true,
          });
        }
        throw new Error("Could not save the tournament proposal.");
      }

      const draft = await ensureTournamentDraft(admin, user.id, String(proposal.id));
      await admin.from("ai_conversations").update({ updated_at: new Date().toISOString() })
        .eq("id", conversationId).eq("owner_user_id", user.id);

      return json({
        conversation_id: conversationId,
        proposal: {
          id: proposal.id,
          workflow_type: "tournament",
          status: draft.eventStatus,
          event_status: draft.eventStatus,
          event_id: draft.eventId,
          community_id: communityId,
          expires_at: proposal.expires_at,
          source_refs: sourceRefs,
          ...payload,
        },
      });
    }

    if (action === "publish_proposal") {
      const proposalId = stringValue(body.proposal_id);
      if (!proposalId) return json({ error: "proposal_id is required." }, 400);

      const { data: proposal, error: proposalError } = await admin.from("tournament_proposals")
        .select("id,owner_user_id,community_id,conversation_id,status,event_id")
        .eq("id", proposalId)
        .eq("owner_user_id", user.id)
        .maybeSingle();
      if (proposalError || !proposal) return json({ error: "Tournament proposal not found." }, 404);
      if (proposal.community_id !== communityId) return json({ error: "Community scope mismatch." }, 403);

      const { data: result, error } = await admin.rpc("publish_tournament_proposal", {
        p_proposal_id: proposalId,
        p_user_id: user.id,
      });
      if (error) {
        const message = String(error.message ?? "");
        const status = message.includes("permission") || message.includes("authorised") ? 403
          : message.includes("not publishable") || message.includes("only a DRAFT")
            || message.includes("not published") ? 409
          : 400;
        return json({ error: message || "Could not publish the tournament." }, status);
      }

      if (proposal.conversation_id) {
        await admin.from("ai_conversations").update({ updated_at: new Date().toISOString() })
          .eq("id", proposal.conversation_id).eq("owner_user_id", user.id);
      }
      return json({
        ...(result && typeof result === "object" ? result as JsonObject : { result }),
        published: true,
        registration_opened: false,
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
        .select("id,community_id,organizer_id,status,event_config")
        .eq("id", eventId).maybeSingle();
      if (eventError || !event) return json({ error: "Tournament not found." }, 404);
      if (event.community_id !== communityId) return json({ error: "Community scope mismatch." }, 403);
      const incomingPayload = objectValue(body.payload);
      const incomingConfig = objectValue(incomingPayload.event_config);
      const savedConfig = objectValue(event.event_config);
      // The tournament form no longer edits roadmap details. Preserve a roadmap
      // already configured in Event Operations when saving other draft fields.
      const mergedConfig = {
        ...savedConfig,
        ...incomingConfig,
        roadmap: Object.prototype.hasOwnProperty.call(incomingConfig, "roadmap")
          ? incomingConfig.roadmap
          : (savedConfig.roadmap ?? null),
      };
      const payload = await validatePayload(admin, user.id, communityId, {
        ...incomingPayload,
        event_config: mergedConfig,
      });
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
