import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler } from "./handler.ts";

const remote = { id: "moy-1", status: "paid", amount: 6000, currency: "SAR",
  source: { type: "applepay" }, metadata: { payment_id: "pay-1" } };

function deps() {
  const seen = new Set<string>();
  const log: string[] = [];
  return {
    log,
    webhookSecret: "whsec",
    recordEvent: async (e: { id: string }) => { if (seen.has(e.id)) return "duplicate" as const; seen.add(e.id); return "new" as const; },
    findPaymentByMetadata: async (id: string) => (id === "pay-1" ? { id: "pay-1", amount: 6000, currency: "SAR" } : null),
    moyasar: {
      // Answers per id, as Moyasar would: only moy-1 carries a real payment_id.
      fetchPayment: async (id: string) => {
        log.push("fetch");
        return id === "moy-1" ? remote : { ...remote, id, metadata: { payment_id: "nope" } };
      },
      capture: async () => remote, voidPayment: async () => remote,
      refund: async () => remote,
    },
    settle: async (a: { p_moyasar_status: string }) => { log.push(`settle:${a.p_moyasar_status}`); return { status: "settled" }; },
    linkEvent: async () => { log.push("link"); },
  };
}

const post = (body: unknown) =>
  new Request("http://x/moyasar-webhook", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

const evt = (id: string, over: Record<string, unknown> = {}) => ({
  id, type: "payment_paid", secret_token: "whsec", live: false,
  data: { id: "moy-1", status: "paid", amount: 6000, metadata: { payment_id: "pay-1" } },
  ...over,
});

Deno.test("wrong secret is 401 and nothing is fetched", async () => {
  const d = deps();
  const res = await makeHandler(d)(post(evt("wh-1", { secret_token: "nope" })));
  assertEquals(res.status, 401);
  assertEquals(d.log, []);
});

Deno.test("a real event is re-fetched from Moyasar and settled", async () => {
  const d = deps();
  const res = await makeHandler(d)(post(evt("wh-1")));
  assertEquals(res.status, 200);
  assertEquals(d.log, ["fetch", "link", "settle:paid"]);
});

Deno.test("the body's status is ignored: a forged 'paid' settles whatever Moyasar really says", async () => {
  const d = deps();
  d.moyasar.fetchPayment = async () => { d.log.push("fetch"); return { ...remote, status: "failed" }; };
  await makeHandler(d)(post(evt("wh-2")));
  assertEquals(d.log, ["fetch", "link", "settle:failed"]);
});

Deno.test("a replayed delivery is acknowledged and settles nothing", async () => {
  const d = deps();
  await makeHandler(d)(post(evt("wh-3")));
  d.log.length = 0;
  const res = await makeHandler(d)(post(evt("wh-3")));
  assertEquals(res.status, 200);
  assertEquals(d.log, []);
});

Deno.test("unknown payment id is recorded and acknowledged, never creates a row", async () => {
  const d = deps();
  const res = await makeHandler(d)(post(evt("wh-4", { data: { id: "moy-9", metadata: { payment_id: "nope" } } })));
  assertEquals(res.status, 200);
  assertEquals(d.log.includes("settle:paid"), false);
});
Deno.test("a refund webhook carries Moyasar's cumulative refunded total", async () => {
  const d = deps();
  const settled: Array<Record<string, unknown>> = [];
  d.moyasar.fetchPayment = async () => ({
    ...remote, status: "refunded", refunded: 12000,
  });
  d.settle = async (a: Record<string, unknown>) => { settled.push(a); return { status: "refunded" }; };
  await makeHandler(d)(post(evt("wh-refund-1")));
  assertEquals(settled[0].p_moyasar_status, "refunded");
  assertEquals(settled[0].p_refunded_total, 12000);
});
