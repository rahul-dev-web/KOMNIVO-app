import { timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { GoogleAuth } from "google-auth-library";

const PORT = Number.parseInt(process.env.PORT ?? "8080", 10);
const PROJECT_ID = process.env.FIREBASE_PROJECT_ID ?? "";
const SHARED_SECRET = process.env.FCM_SENDER_SECRET ?? "";
const MAX_BODY_BYTES = 32 * 1024;

const auth = new GoogleAuth({
  scopes: ["https://www.googleapis.com/auth/firebase.messaging"],
});

function sendJson(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
  });
  res.end(body);
}

function authorized(provided) {
  if (!SHARED_SECRET || !provided) return false;
  const expected = Buffer.from(SHARED_SECRET, "utf8");
  const actual = Buffer.from(provided, "utf8");
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

async function readJson(req) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new Error("Request body too large.");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function validMessage(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  if (typeof value.token !== "string" || value.token.length < 20 || value.token.length > 4096) return false;
  if (!value.notification || typeof value.notification !== "object") return false;
  if (typeof value.notification.title !== "string" || value.notification.title.length > 120) return false;
  if (typeof value.notification.body !== "string" || value.notification.body.length > 2000) return false;
  if (value.data !== undefined) {
    if (!value.data || typeof value.data !== "object" || Array.isArray(value.data)) return false;
    if (Object.values(value.data).some((v) => typeof v !== "string" || v.length > 1024)) return false;
  }
  return true;
}

const server = createServer(async (req, res) => {
  const pathname = new URL(req.url ?? "/", "http://localhost").pathname;

  if (req.method === "GET" && pathname === "/healthz") {
    return sendJson(res, 200, { ok: true });
  }

  if (req.method !== "POST" || pathname !== "/send") {
    return sendJson(res, 404, { error: "Not found." });
  }

  if (!authorized(req.headers["x-fcm-sender-secret"])) {
    return sendJson(res, 401, { error: "Unauthorized." });
  }

  if (!PROJECT_ID || !SHARED_SECRET) {
    return sendJson(res, 503, { error: "Sender is not configured." });
  }

  try {
    const input = await readJson(req);
    if (!validMessage(input)) {
      return sendJson(res, 400, { error: "Invalid FCM message payload." });
    }

    const client = await auth.getClient();
    const result = await client.request({
      url: `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(PROJECT_ID)}/messages:send`,
      method: "POST",
      data: {
        message: {
          token: input.token,
          notification: input.notification,
          data: input.data ?? {},
          android: { priority: "high" },
        },
      },
    });

    return sendJson(res, 200, { sent: true, message_name: result.data?.name ?? null });
  } catch (error) {
    const status = Number(error?.response?.status ?? 0);
    // Do not log request bodies, device tokens, access tokens, or secret values.
    console.error("FCM send failed.", { upstream_status: status || null });
    return sendJson(res, 502, {
      sent: false,
      error: "FCM rejected or could not process the message.",
      upstream_status: status || null,
    });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`KOMNIVO FCM sender listening on port ${PORT}`);
});
