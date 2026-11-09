import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json, readBearer } from "../_shared/http.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const authorization = readBearer(req);
  if (!authorization) return json({ error: "Authentication required" }, 401);

  const url = Deno.env.get("SUPABASE_URL")!;
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return json({ error: "Invalid session" }, 401);

  try {
    const body = await req.json();
    const registrationId = String(body.registration_id ?? "");
    const status = String(body.status ?? "");
    if (!registrationId || !["approved", "rejected", "waitlisted"].includes(status)) {
      return json({ error: "registration_id and a supported review status are required." }, 400);
    }

    const { data: registration, error: fetchError } = await userClient.from("event_registrations")
      .select("id,event_id,status").eq("id", registrationId).maybeSingle();
    if (fetchError || !registration) return json({ error: "Registration not found or unavailable." }, 404);
    const { data: isStaff, error: staffError } = await userClient.rpc("is_event_staff", { p_event_id: registration.event_id });
    if (staffError || isStaff !== true) return json({ error: "Only authorised event staff can review registrations." }, 403);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const patch: Record<string, unknown> = { status };
    if (status === "approved") patch.approved_at = new Date().toISOString();
    const { data, error } = await admin.from("event_registrations")
      .update(patch).eq("id", registrationId).select("id,status,approved_at").single();
    if (error) return json({ error: error.message }, 400);

    await admin.from("audit_logs").insert({
      actor_id: user.id,
      event_id: registration.event_id,
      entity_type: "event_registration",
      entity_id: registrationId,
      action: "registration_" + status,
      reason: typeof body.reason === "string" ? body.reason.slice(0, 500) : null,
    });
    return json({ registration: data });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Invalid request" }, 400);
  }
});
