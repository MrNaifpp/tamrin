import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { basicAuthHeader, makeMoyasarClient } from "./moyasar.ts";

Deno.test("basic auth is the secret key as username with an empty password", () => {
  assertEquals(basicAuthHeader("sk_test_abc"), "Basic " + btoa("sk_test_abc:"));
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
