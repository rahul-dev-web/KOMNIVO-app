const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-webhook-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

type NotificationPreferences = {
  push_enabled: boolean;
  message_push: boolean;
  mention_push: boolean;
  event_push: boolean;
  tournament_push: boolean;
  marketing_push: boolean;
};

type Device = { token: string; platform?: string | null };
type SendResult = { ok: boolean; platform: string; error_status?: string };

let cachedGoogleAccessToken = "";
let googleAccessTokenExpiresAt = 0;
let pendingTokenRefresh: Promise<string> | null = null;

async function getGoogleAccessToken(): Promise<string> {
  if (cachedGoogleAccessToken && Date.now() < googleAccessTokenExpiresAt - 60_000) {
    return cachedGoogleAccessToken;
  }

  if (pendingTokenRefresh) return await pendingTokenRefresh;

  const refreshPromise = (async () => {
    const clientId = Deno.env.get("GOOGLE_OAUTH_CLIENT_ID");
    const clientSecret = Deno.env.get("GOOGLE_OAUTH_CLIENT_SECRET");
    const refreshToken = Deno.env.get("GOOGLE_OAUTH_REFRESH_TOKEN");

    if (!clientId || !clientSecret || !refreshToken) {
      throw new Error("Google OAuth credentials are not configured.");
    }

    const response = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: clientId,
        client_secret: clientSecret,
        refresh_token: refreshToken,
        grant_type: "refresh_token",
      }),
      signal: AbortSignal.timeout(12_000),
    });

    if (!response.ok) {
      // Do not log or return OAuth response bodies; they can contain credential details.
      throw new Error("Google OAuth refresh failed.");
    }

    const result = await response.json() as { access_token?: string; expires_in?: number };
    if (!result.access_token) throw new Error("Google OAuth did not return an access token.");

    cachedGoogleAccessToken = result.access_token;
    googleAccessTokenExpiresAt = Date.now() + Math.max(60, result.expires_in ?? 3600) * 1000;
    return cachedGoogleAccessToken;
  })().finally(() => {
    pendingTokenRefresh = null;
  });
  pendingTokenRefresh = refreshPromise;

  return await refreshPromise;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const expectedSecret = Deno.env.get("PUSH_WEBHOOK_SECRET");
  if (!expectedSecret || req.headers.get("x-webhook-secret") !== expectedSecret) {
    return json({ error: "Webhook authentication failed." }, 401);
  }

  const projectId = Deno.env.get("FIREBASE_PROJECT_ID");
  if (!projectId) return json({ error: "Firebase project is not configured." }, 503);

  try {
    const body = await req.json();
    const record = body?.record ?? body;
    const userId = String(record?.user_id ?? "");
    if (!userId) return json({ error: "Notification user_id is missing." }, 400);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceKey) {
      return json({ error: "Supabase server configuration is unavailable." }, 503);
    }

    const supabaseHeaders = {
      apikey: serviceKey,
      Authorization: "Bearer " + serviceKey,
    };

    const [tokenResponse, preferenceResponse] = await Promise.all([
      fetch(
        supabaseUrl + "/rest/v1/device_tokens?select=token,platform&user_id=eq." + encodeURIComponent(userId),
        { headers: supabaseHeaders, signal: AbortSignal.timeout(12_000) },
      ),
      fetch(
        supabaseUrl + "/rest/v1/notification_preferences?select=push_enabled,message_push,mention_push,event_push,tournament_push,marketing_push&user_id=eq." + encodeURIComponent(userId),
        { headers: supabaseHeaders, signal: AbortSignal.timeout(12_000) },
      ),
    ]);

    if (!tokenResponse.ok) return json({ error: "Could not load user device tokens." }, 502);
    if (!preferenceResponse.ok) return json({ error: "Could not load notification preferences." }, 502);

    const devices = await tokenResponse.json() as Device[];
    const prefsList = await preferenceResponse.json() as NotificationPreferences[];
    const prefs = prefsList[0] ?? {
      push_enabled: true,
      message_push: true,
      mention_push: true,
      event_push: true,
      tournament_push: true,
      marketing_push: false,
    };

    const kind = String(record.kind ?? "general");
    const preferenceByKind: Record<string, keyof NotificationPreferences> = {
      message: "message_push",
      mention: "mention_push",
      event: "event_push",
      tournament: "tournament_push",
      marketing: "marketing_push",
    };
    const selectedPreference = preferenceByKind[kind];

    if (!prefs.push_enabled || (selectedPreference && !prefs[selectedPreference])) {
      return json({ sent: 0, failed: 0, skipped: true, reason: "Notification preferences disabled this push category." });
    }
    if (devices.length === 0) return json({ sent: 0, failed: 0, message: "No registered devices." });

    const accessToken = await getGoogleAccessToken();
    const title = String(record.title ?? "KOMNIVO").slice(0, 120);
    const notificationBody = String(record.body ?? "").slice(0, 2000);
    const data = {
      kind,
      entity_type: String(record.entity_type ?? ""),
      entity_id: String(record.entity_id ?? ""),
      notification_id: String(record.id ?? ""),
    };
    const webAppUrl = Deno.env.get("KOMNIVO_WEB_URL") ?? "https://komnivo-app.pages.dev/";

    const results = await Promise.all(devices.map(async (device): Promise<SendResult> => {
      const platform = String(device.platform ?? "android").toLowerCase();
      const isWeb = platform === "web";
      try {
        const response = await fetch(
          "https://fcm.googleapis.com/v1/projects/" + encodeURIComponent(projectId) + "/messages:send",
          {
            method: "POST",
            headers: {
              Authorization: "Bearer " + accessToken,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              message: {
                token: device.token,
                notification: { title, body: notificationBody },
                data,
                ...(isWeb
                  ? {
                      webpush: {
                        headers: { Urgency: "high" },
                        fcm_options: { link: webAppUrl },
                      },
                    }
                  : { android: { priority: "high" } }),
              },
            }),
            signal: AbortSignal.timeout(15_000),
          },
        );

        if (response.ok) return { ok: true, platform };

        // Keep the diagnostic code, but never log response bodies or device tokens.
        const errorPayload = await response.json().catch(() => null) as
          | { error?: { status?: string } }
          | null;
        const errorStatus = String(errorPayload?.error?.status ?? `HTTP_${response.status}`);
        console.warn("FCM send rejected for device.", {
          platform,
          http_status: response.status,
          error_status: errorStatus,
        });
        return { ok: false, platform, error_status: errorStatus };
      } catch {
        console.warn("FCM send failed before receiving a response.", { platform, error_status: "NETWORK_ERROR" });
        return { ok: false, platform, error_status: "NETWORK_ERROR" };
      }
    }));

    const sent = results.filter((result) => result.ok).length;
    const failures = results
      .filter((result) => !result.ok)
      .map((result) => ({ platform: result.platform, error_status: result.error_status ?? "UNKNOWN" }));

    return json({ sent, failed: failures.length, failures });
  } catch (error) {
    console.error("FCM notification handler failed.", {
      error_type: error instanceof Error ? error.name : "UnknownError",
    });
    return json({ error: "Push delivery failed. Check Edge Function logs for the non-secret error category." }, 500);
  }
});
