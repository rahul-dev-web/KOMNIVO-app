import { createClient } from "npm:@supabase/supabase-js@2";
import { AccessToken } from "npm:livekit-server-sdk@2";
import { corsHeaders, json, readBearer } from "../_shared/http.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const authorization = readBearer(req);
  if (!authorization) return json({ error: "Authentication required" }, 401);

  const url = Deno.env.get("SUPABASE_URL")!;
  const client = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const { data: { user }, error: authError } = await client.auth.getUser();
  if (authError || !user) return json({ error: "Invalid session" }, 401);

  const livekitUrl = Deno.env.get("LIVEKIT_URL");
  const apiKey = Deno.env.get("LIVEKIT_API_KEY");
  const apiSecret = Deno.env.get("LIVEKIT_API_SECRET");
  if (!livekitUrl || !apiKey || !apiSecret) {
    return json({ error: "Voice service has not been configured." }, 503);
  }

  try {
    const body = await req.json();
    const channelId = String(body.channel_id ?? "");
    if (!channelId) return json({ error: "channel_id is required." }, 400);

    const { data: channel } = await client.from("channels")
      .select("id,community_id,kind,is_private")
      .eq("id", channelId).maybeSingle();
    if (!channel) return json({ error: "Channel not found or access denied." }, 404);
    if (!["voice", "text", "match", "dm", "group"].includes(channel.kind)) {
      return json({ error: "This channel does not support voice." }, 400);
    }

    if (channel.community_id) {
      const { data: communityMember } = await client.from("community_members")
        .select("user_id").eq("community_id", channel.community_id).eq("user_id", user.id).maybeSingle();
      if (!communityMember) return json({ error: "Join this community before entering its voice rooms." }, 403);

      if (channel.is_private) {
        const { data: channelMember } = await client.from("channel_members")
          .select("user_id").eq("channel_id", channelId).eq("user_id", user.id).maybeSingle();
        if (!channelMember) return json({ error: "You are not a member of this private voice room." }, 403);
      }
    } else {
      const { data: membership } = await client.from("channel_members")
        .select("user_id").eq("channel_id", channelId).eq("user_id", user.id).maybeSingle();
      if (!membership) return json({ error: "You are not a member of this conversation." }, 403);
    }

    const roomName = `channel-${channelId}`;
    const token = new AccessToken(apiKey, apiSecret, {
      identity: user.id,
      ttl: "1h",
      name: user.user_metadata?.full_name ?? "KOMNIVO player",
    });
    token.addGrant({ roomJoin: true, room: roomName, canPublish: true, canSubscribe: true, canPublishData: true });
    return json({ url: livekitUrl, token: await token.toJwt(), room: roomName });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "Unable to create voice session." }, 400);
  }
});
