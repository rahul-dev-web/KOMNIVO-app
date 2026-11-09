import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, json, readBearer } from "../_shared/http.ts";

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
    const name = String(body.name ?? "").trim();
    const description = String(body.description ?? "").trim().slice(0, 500);
    const visibility = body.visibility === "private" ? "private" : "public";
    if (name.length < 3 || name.length > 60) return json({ error: "Community name must be 3–60 characters." }, 400);

    const base = name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 44);
    const slug = `${base || "community"}-${crypto.randomUUID().slice(0, 6)}`;
    const { data, error } = await client.from("communities").insert({
      name, slug, description, visibility, owner_user_id: user.id,
    }).select().single();
    if (error) return json({ error: error.message }, 400);
    // The database trigger creates the owner membership and the standard channel set.
    return json({ community: data }, 201);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Invalid request" }, 400);
  }
});
