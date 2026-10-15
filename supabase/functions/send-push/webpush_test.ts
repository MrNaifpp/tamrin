import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import * as lib from "jsr:@negrel/webpush@0.5.0";
import {
  isGone,
  makeWebPushServer,
  sendWebPush,
  webPushPayload,
} from "./webpush.ts";

function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// A real key pair for the server and a real browser key, so the library does
// its actual encryption; only the network is replaced.
async function fixture() {
  const vapid = await lib.generateVapidKeys({ extractable: true });
  const server = await makeWebPushServer({
    vapidKeysJson: JSON.stringify(await lib.exportVapidKeys(vapid)),
    subject: "https://guileless-squirrel-b6537a.netlify.app",
  });
  const browser = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"],
  );
  const sub = {
    endpoint: "https://fcm.googleapis.com/fcm/send/abc",
    p256dh: b64url(new Uint8Array(await crypto.subtle.exportKey("raw", browser.publicKey))),
    auth: b64url(crypto.getRandomValues(new Uint8Array(16))),
  };
  return { server, sub };
}

async function withFetch<T>(
  status: number,
  body: string,
  run: (calls: { url: string; init: RequestInit }[]) => Promise<T>,
): Promise<T> {
  const original = globalThis.fetch;
  const calls: { url: string; init: RequestInit }[] = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), init: init ?? {} });
    return Promise.resolve(new Response(body || null, { status }));
  }) as typeof fetch;
  try {
    return await run(calls);
  } finally {
    globalThis.fetch = original;
  }
}

Deno.test("webPushPayload carries title, body and the event to open", () => {
  assertEquals(
    JSON.parse(webPushPayload({ title: "تذكير", body: "لا تنسى" }, "e-1")),
    { title: "تذكير", body: "لا تنسى", event_id: "e-1" },
  );
  assertEquals(
    JSON.parse(webPushPayload({ title: "t", body: "b" }, null)).event_id,
    null,
  );
});

Deno.test("isGone is true only for 404 and 410", () => {
  assertEquals([404, 410].map(isGone), [true, true]);
  assertEquals([400, 401, 413, 429, 500].map(isGone), [false, false, false, false, false]);
});

Deno.test("sendWebPush posts an encrypted, signed, urgent message", async () => {
  const { server, sub } = await fixture();
  const result = await withFetch(201, "", async (calls) => {
    const r = await sendWebPush(server, sub, webPushPayload({ title: "t", body: "b" }, "e-1"));
    assertEquals(calls.length, 1);
    assertEquals(calls[0].url, sub.endpoint);
    const headers = new Headers(calls[0].init.headers);
    assertEquals(headers.get("content-encoding"), "aes128gcm");
    assertEquals(headers.get("ttl"), "86400");
    assertEquals(headers.get("urgency"), "high");
    assert(headers.get("authorization")?.startsWith("vapid t="));
    return r;
  });
  assertEquals(result, { ok: true, status: 201, text: "", gone: false });
});

Deno.test("sendWebPush reports a 410 as gone", async () => {
  const { server, sub } = await fixture();
  const result = await withFetch(410, "expired", () => sendWebPush(server, sub, "{}"));
  assertEquals(result, { ok: false, status: 410, text: "expired", gone: true });
});

Deno.test("sendWebPush reports a 500 as a failure that is not gone", async () => {
  const { server, sub } = await fixture();
  const result = await withFetch(500, "busy", () => sendWebPush(server, sub, "{}"));
  assertEquals(result, { ok: false, status: 500, text: "busy", gone: false });
});

Deno.test("sendWebPush turns a broken subscription into a failure, not a throw", async () => {
  const { server, sub } = await fixture();
  const result = await withFetch(201, "", () =>
    sendWebPush(server, { ...sub, p256dh: "not-a-key" }, "{}"));
  assertEquals(result.ok, false);
  assertEquals(result.gone, false);
  assertEquals(result.status, 0);
});
