import { corsHeaders, json } from "../_shared/http.ts";

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function base64UrlText(value: string): string {
  return base64Url(new TextEncoder().encode(value));
}

function decodePem(pem: string): ArrayBuffer {
  const body = pem.replace(/-----BEGIN PRIVATE KEY-----/g, "").replace(/-----END PRIVATE KEY-----/g, "").replace(/\s/g, "");
  const bytes = Uint8Array.from(atob(body), (char) => char.charCodeAt(0));
  return bytes.buffer;
}

async function googleAccessToken(serviceAccount: Record<string, string>): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = base64UrlText(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64UrlText(JSON.stringify({
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const unsigned = header + "." + claims;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    decodePem(serviceAccount.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  ));
  const assertion = unsigned + "." + base64Url(signature);

  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!response.ok) throw new Error("Google OAuth token exchange failed.");
  const result = await response.json();
  return result.access_token as string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const expectedSecret = Deno.env.get("PUSH_WEBHOOK_SECRET");
  if (!expectedSecret || req.headers.get("x-webhook-secret") !== expectedSecret) {
    return json({ error: "Webhook authentication failed." }, 401);
  }
  const projectId = Deno.env.get("FIREBASE_PROJECT_ID");
  const serviceAccountValue = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON");
  if (!projectId || !serviceAccountValue) {
    return json({ error: "Firebase server credentials have not been configured." }, 503);
  }

  try {
    const body = await req.json();
    const record = body.record ?? body;
    const userId = String(record.user_id ?? "");
    if (!userId) return json({ error: "Notification user_id is missing." }, 400);

    const serviceAccount = JSON.parse(serviceAccountValue) as Record<string, string>;
    const accessToken = await googleAccessToken(serviceAccount);
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const tokenResponse = await fetch(
      supabaseUrl + "/rest/v1/device_tokens?select=token&user_id=eq." + encodeURIComponent(userId),
      { headers: { apikey: serviceKey, Authorization: "Bearer " + serviceKey } },
    );
    if (!tokenResponse.ok) return json({ error: "Could not load user device tokens." }, 502);
    const devices = await tokenResponse.json() as Array<{ token: string }>;
    if (devices.length === 0) return json({ sent: 0, message: "No registered devices." });

    const results = await Promise.all(devices.map(async (device) => {
      const response = await fetch(
        "https://fcm.googleapis.com/v1/projects/" + projectId + "/messages:send",
        {
          method: "POST",
          headers: { Authorization: "Bearer " + accessToken, "Content-Type": "application/json" },
          body: JSON.stringify({
            message: {
              token: device.token,
              notification: {
                title: String(record.title ?? "KOMNIVO"),
                body: String(record.body ?? ""),
              },
              data: {
                kind: String(record.kind ?? "general"),
                entity_type: String(record.entity_type ?? ""),
                entity_id: String(record.entity_id ?? ""),
                notification_id: String(record.id ?? ""),
              },
              android: { priority: "high" },
            },
          }),
        },
      );
      return response.ok;
    }));

    return json({ sent: results.filter(Boolean).length, failed: results.filter((ok) => !ok).length });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Push delivery failed." }, 500);
  }
});
