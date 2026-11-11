import { corsHeaders, json } from "../_shared/http.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const expectedSecret = Deno.env.get("PUSH_WEBHOOK_SECRET");
  if (!expectedSecret || req.headers.get("x-webhook-secret") !== expectedSecret) {
    return json({ error: "Webhook authentication failed." }, 401);
  }

  const senderUrl = Deno.env.get("FCM_SENDER_URL");
  const senderSecret = Deno.env.get("FCM_SENDER_SECRET");
  if (!senderUrl || !senderSecret) {
    return json({ error: "Keyless Firebase sender has not been configured." }, 503);
  }

  try {
    const body = await req.json();
    const record = body.record ?? body;
    const userId = String(record.user_id ?? "");
    if (!userId) return json({ error: "Notification user_id is missing." }, 400);

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const headers = { apikey: serviceKey, Authorization: "Bearer " + serviceKey };

    const [tokenResponse, preferenceResponse] = await Promise.all([
      fetch(
        supabaseUrl + "/rest/v1/device_tokens?select=token&user_id=eq." + encodeURIComponent(userId),
        { headers },
      ),
      fetch(
        supabaseUrl + "/rest/v1/notification_preferences?select=push_enabled,message_push,mention_push,event_push,tournament_push,marketing_push&user_id=eq." + encodeURIComponent(userId),
        { headers },
      ),
    ]);

    if (!tokenResponse.ok) return json({ error: "Could not load user device tokens." }, 502);
    if (!preferenceResponse.ok) return json({ error: "Could not load notification preferences." }, 502);

    const devices = await tokenResponse.json() as Array<{ token: string }>;
    const prefsList = await preferenceResponse.json() as Array<Record<string, boolean>>;
    const prefs = prefsList[0] ?? {
      push_enabled: true,
      message_push: true,
      mention_push: true,
      event_push: true,
      tournament_push: true,
      marketing_push: false,
    };

    const kind = String(record.kind ?? "general");
    const preferenceByKind: Record<string, keyof typeof prefs> = {
      message: "message_push",
      mention: "mention_push",
      event: "event_push",
      tournament: "tournament_push",
      marketing: "marketing_push",
    };
    const selectedPreference = preferenceByKind[kind];

    if (!prefs.push_enabled || (selectedPreference && !prefs[selectedPreference])) {
      return json({ sent: 0, skipped: true, reason: "Notification preferences disabled this push category." });
    }
    if (devices.length === 0) return json({ sent: 0, message: "No registered devices." });

    const url = senderUrl.replace(/\\/+$/, "") + "/send";
    const title = String(record.title ?? "KOMNIVO").slice(0, 120);
    const notificationBody = String(record.body ?? "").slice(0, 2000);
    const data = {
      kind,
      entity_type: String(record.entity_type ?? ""),
      entity_id: String(record.entity_id ?? ""),
      notification_id: String(record.id ?? ""),
    };

    const results = await Promise.all(devices.map(async (device) => {
      try {
        const response = await fetch(url, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-fcm-sender-secret": senderSecret,
          },
          body: JSON.stringify({
            token: device.token,
            notification: { title, body: notificationBody },
            data,
          }),
          signal: AbortSignal.timeout(15000),
        });
        return response.ok;
      } catch {
        return false;
      }
    }));

    return json({ sent: results.filter(Boolean).length, failed: results.filter((ok) => !ok).length });
  } catch {
    return json({ error: "Push delivery failed." }, 500);
  }
});
