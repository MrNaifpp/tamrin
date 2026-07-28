import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { copyFor } from "./copy.ts";
import { makeApnsJwt, sendApns } from "./apns.ts";

const SEND_PUSH_SECRET = Deno.env.get("SEND_PUSH_SECRET")!;
const APNS_TOPIC = Deno.env.get("APNS_BUNDLE_ID")!;

// A device token is only valid on the APNs environment that issued it: Xcode
// builds register against sandbox, TestFlight and App Store builds against
// production. device_tokens doesn't record which one a row came from, so we
// try the configured host first and fall back to its sibling when Apple
// answers BadDeviceToken.
const APNS_SANDBOX = "https://api.sandbox.push.apple.com";
const APNS_PRODUCTION = "https://api.push.apple.com";
const APNS_HOST = Deno.env.get("APNS_HOST") ?? APNS_SANDBOX;
const APNS_FALLBACK_HOST = APNS_HOST === APNS_PRODUCTION ? APNS_SANDBOX : APNS_PRODUCTION;

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

  // 400 BadDeviceToken means the token belongs to the other environment, not
  // that it is dead — the same token still delivers on the sibling host.
  const isWrongEnvironment = (r: { status: number; text: string }) =>
    r.status === 400 && r.text.includes("BadDeviceToken");

  const deliver = async (deviceToken: string) => {
    const payload = {
      deviceToken,
      topic: APNS_TOPIC,
      jwt,
      title: copy.title,
      body: copy.body,
      data: { event_id: row.event_id },
    };
    const first = await sendApns({ host: APNS_HOST, ...payload });
    if (first.ok || !isWrongEnvironment(first)) return first;

    const second = await sendApns({ host: APNS_FALLBACK_HOST, ...payload });
    if (second.ok) return second;
    // Both environments rejected it. Keep each answer so the outbox says why.
    return {
      ...second,
      text: `${APNS_HOST} -> ${first.text}; ${APNS_FALLBACK_HOST} -> ${second.text}`,
    };
  };

  const results = await Promise.all(tokens.map((t) => deliver(t.apns_token)));

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
