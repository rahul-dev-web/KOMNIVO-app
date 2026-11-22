import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function readBearer(req: Request): string | null {
  const value = req.headers.get("Authorization");
  return value?.startsWith("Bearer ") ? value : null;
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

  try {
    const body = await req.json();
    if (typeof body.event_id !== "string") {
      return json({ error: "event_id is required" }, 400);
    }

    // Backward compatibility: clients that omit registration_type still use
    // the real registration path. Test entries are routed to isolated storage.
    const registrationType = body.registration_type ?? "real";
    if (registrationType !== "real" && registrationType !== "test") {
      return json({ error: "registration_type must be 'real' or 'test'." }, 400);
    }
    if (body.team_id !== undefined && body.team_id !== null && typeof body.team_id !== "string") {
      return json({ error: "team_id must be a UUID string or null." }, 400);
    }

    const rpcName = registrationType === "test"
      ? "submit_test_registration"
      : "register_for_event";
    const { data, error } = await client.rpc(rpcName, {
      p_event_id: body.event_id,
      p_team_id: typeof body.team_id === "string" ? body.team_id : null,
    });
    if (error) return json({ error: error.message }, 400);
    return json(data, 201);
  } catch (error) {
    return json(error instanceof Error ? { error: error.message } : { error: "Invalid request" }, 400);
  }
});
