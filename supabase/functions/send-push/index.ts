import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { copyFor } from "./copy.ts";
import { makeApnsJwt, sendApns } from "./apns.ts";

const SEND_PUSH_SECRET = Deno.env.get("SEND_PUSH_SECRET")!;
const APNS_HOST = Deno.env.get("APNS_HOST") ?? "https://api.sandbox.push.apple.com";
const APNS_TOPIC = Deno.env.get("APNS_BUNDLE_ID")!;

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (req) => {
  // 1. Auth — server-only.
  if (req.headers.get("authorization") !== `Bearer ${SEND_PUSH_SECRET}`) {
    return new Response("unauthorized", { status: 401 });
  }

  const { outbox_id } = await req.json().catch(() => ({}));
  if (!outbox_id) return new Response("missing outbox_id", { status: 400 });

  // 2. Load the outbox row (authoritative).
  const { data: row } = await admin
    .from("push_outbox")
    .select("id, user_id, type, event_id")
    .eq("id", outbox_id)
    .single();
  if (!row) return new Response("outbox row not found", { status: 404 });

  const fail = async (msg: string) => {
    await admin.from("push_outbox").update({
      status: "failed",
      last_error: msg.slice(0, 500),
      attempts: 1,
    }).eq("id", row.id);
    return new Response(msg, { status: 200 }); // 200: we recorded the failure
  };

  // 3. Recipient tokens.
  const { data: tokens } = await admin
    .from("device_tokens")
    .select("apns_token")
    .eq("user_id", row.user_id);
  if (!tokens || tokens.length === 0) return await fail("no device tokens");

  // 4. Event name (for copy).
  let eventName = "";
  if (row.event_id) {
    const { data: ev } = await admin
      .from("events").select("name").eq("id", row.event_id).single();
    eventName = ev?.name ?? "";
  }

  // 5. Copy.
  const copy = copyFor(row.type, eventName);
  if (!copy) return await fail(`no copy for type ${row.type}`);

  // 6. Sign + send to every device.
  const jwt = await makeApnsJwt({
    keyId: Deno.env.get("APNS_KEY_ID")!,
    teamId: Deno.env.get("APNS_TEAM_ID")!,
    authKeyPem: Deno.env.get("APNS_AUTH_KEY")!,
    nowSeconds: Math.floor(Date.now() / 1000),
  });

  const results = await Promise.all(tokens.map((t) =>
    sendApns({
      host: APNS_HOST,
      deviceToken: t.apns_token,
      topic: APNS_TOPIC,
      jwt,
      title: copy.title,
      body: copy.body,
      data: { event_id: row.event_id },
    })
  ));

  const anyOk = results.some((r) => r.ok);
  await admin.from("push_outbox").update({
    status: anyOk ? "sent" : "failed",
    sent_at: anyOk ? new Date().toISOString() : null,
    last_error: anyOk
      ? null
      : results.map((r) => `${r.status}:${r.text}`).join("; ").slice(0, 500),
    attempts: 1,
  }).eq("id", row.id);

  return new Response(JSON.stringify({ ok: anyOk }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
});
