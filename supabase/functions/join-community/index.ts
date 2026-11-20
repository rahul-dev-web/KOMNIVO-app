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
    const communityId = String(body.community_id ?? "");
    if (!communityId) return json({ error: "community_id is required" }, 400);
    const inviteCode = typeof body.invite_code === "string" ? body.invite_code.trim() : "";
    if (inviteCode && inviteCode.length < 16) {
      return json({ error: "Invite code is invalid." }, 400);
    }

    let tokenHash: string | null = null;
    if (inviteCode) {
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(inviteCode));
      tokenHash = Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
    }

    const applicantNote = typeof body.applicant_note === "string"
      ? body.applicant_note.trim().slice(0, 1000)
      : "";
    const { data, error } = await userClient.rpc("join_community_with_invite", {
      p_community_id: communityId,
      p_token_hash: tokenHash,
      p_applicant_note: applicantNote,
    });
    if (error) {
      const status = error.code === "42501" ? 403 : error.code === "P0002" ? 404 : 400;
      return json({ error: error.message }, status);
    }

    const result = data as { status?: string; request_id?: string; community_id?: string } | null;
    if (!result?.status) return json({ error: "Community join returned an invalid status." }, 500);

    return json({
      joined: result.status === "joined" || result.status === "already_member",
      status: result.status,
      request_id: result.request_id ?? null,
      community_id: result.community_id ?? communityId,
    });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Invalid request" }, 400);
  }
});
