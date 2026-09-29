import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { basicAuthHeader, makeMoyasarClient } from "./moyasar.ts";

Deno.test("basic auth is the secret key as username with an empty password", () => {
  // Pinned to the exact header `curl -u sk_test_abc:` sends. The old assertion
  // compared btoa of the same expression the function uses, so it would have
  // passed no matter how wrong the encoding was.
  assertEquals(basicAuthHeader("sk_test_abc"), "Basic c2tfdGVzdF9hYmM6");
});

Deno.test("fetchPayment hits /v1/payments/{id} with basic auth", async () => {
  let seen: { url: string; auth: string | null } | null = null;
  const fakeFetch: typeof fetch = async (input, init) => {
    seen = {
      url: String(input),
      auth: new Headers(init?.headers).get("authorization"),
    };
    return new Response(JSON.stringify({ id: "p1", status: "authorized", amount: 6000, currency: "SAR" }), { status: 200 });
  };
  const c = makeMoyasarClient("sk_test_abc", fakeFetch);
  const p = await c.fetchPayment("p1");
  assertEquals(p.status, "authorized");
  assertEquals(seen!.url, "https://api.moyasar.com/v1/payments/p1");
  assertEquals(seen!.auth, "Basic " + btoa("sk_test_abc:"));
});

Deno.test("capture posts to /capture and void posts to /void", async () => {
  const urls: string[] = [];
  const fakeFetch: typeof fetch = async (input, init) => {
    urls.push(`${init?.method} ${String(input)}`);
    return new Response(JSON.stringify({ id: "p1", status: "captured", amount: 6000, currency: "SAR" }), { status: 200 });
  };
  const c = makeMoyasarClient("sk_test_abc", fakeFetch);
  await c.capture("p1");
  await c.voidPayment("p1");
  assertEquals(urls, [
    "POST https://api.moyasar.com/v1/payments/p1/capture",
    "POST https://api.moyasar.com/v1/payments/p1/void",
  ]);
});
Deno.test("refund posts the amount in halalas as a JSON body", async () => {
  let seen: { url: string; method?: string; body?: string } | null = null;
  const fakeFetch: typeof fetch = async (input, init) => {
    seen = { url: String(input), method: init?.method, body: init?.body as string };
    return new Response(
      JSON.stringify({ id: "p1", status: "refunded", amount: 6000, currency: "SAR", refunded: 2000 }),
      { status: 200 },
    );
  };
  const c = makeMoyasarClient("sk_test_abc", fakeFetch);
  const p = await c.refund("p1", 2000);
  assertEquals(p.refunded, 2000);
  assertEquals(seen!.url, "https://api.moyasar.com/v1/payments/p1/refund");
  assertEquals(seen!.method, "POST");
  assertEquals(seen!.body, JSON.stringify({ amount: 2000 }));
});

Deno.test("refund with no amount sends no body, which Moyasar reads as all of it", async () => {
  let seen: { body?: string | null } | null = null;
  const fakeFetch: typeof fetch = async (_input, init) => {
    seen = { body: (init?.body ?? null) as string | null };
    return new Response(
      JSON.stringify({ id: "p1", status: "refunded", amount: 6000, currency: "SAR", refunded: 6000 }),
      { status: 200 },
    );
  };
  const c = makeMoyasarClient("sk_test_abc", fakeFetch);
  await c.refund("p1");
  assertEquals(seen!.body, null);
});
