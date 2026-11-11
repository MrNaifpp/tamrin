import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler, type StuckPayment, type SweepDeps } from "./handler.ts";
import type { MfPayment } from "../_shared/myfatoorah.ts";

const NOW = new Date("2026-11-11T12:00:00Z");
const minutesAgo = (m: number) => new Date(NOW.getTime() - m * 60_000).toISOString();

function mf(outcome: MfPayment["outcome"], id = "0707-1"): MfPayment {
  return {
    paymentId: id, invoiceId: "inv", externalIdentifier: "pay-1", outcome,
    amountHalalas: 6000, currency: "SAR", baseCurrency: "SAR", baseValue: 60, method: "Apple Pay", errorMessage: null,
  };
}

function deps(rows: StuckPayment[], opts: {
  get?: (id: string) => Promise<MfPayment>;
  find?: (ext: string) => Promise<MfPayment | null>;
} = {}) {
  const settles: Array<Parameters<SweepDeps["settle"]>[0]> = [];
  const d: SweepDeps = {
    sharedSecret: "s",
    now: () => NOW,
    loadStuck: async () => rows,
    mf: {
      getPayment: opts.get ?? (async () => mf("paid")),
      findPaymentByExternalIdentifier: opts.find ?? (async () => null),
    },
    settle: async (a) => { settles.push(a); return { status: "ok" }; },
  };
  return { d, settles };
}

const post = (auth = "Bearer s") => new Request("http://x/payment-sweep", { method: "POST", headers: { authorization: auth } });
const row = (over: Partial<StuckPayment> = {}): StuckPayment => ({
  id: "pay-1", provider_payment_id: "0707-1", current_attempt: "pay-1:att", amount: 6000, currency: "SAR",
  updated_at: minutesAgo(5), ...over,
});

Deno.test("401 without secret", async () => {
  const { d } = deps([row()]);
  assertEquals((await makeHandler(d)(post("Bearer no"))).status, 401);
});

Deno.test("processing with id → getPayment → settle paid", async () => {
  const { d, settles } = deps([row()]);
  const res = await makeHandler(d)(post());
  assertEquals(await res.json(), { checked: 1, settled: 1 });
  assertEquals(settles, [{
    p_payment_id: "pay-1", p_provider_payment_id: "0707-1", p_outcome: "paid",
    p_payment_method: "applepay", p_amount: 6000, p_currency: "SAR", p_attempt: "pay-1:att",
  }]);
});

Deno.test("still processing → no settle", async () => {
  const { d, settles } = deps([row()], { get: async () => mf("processing") });
  await makeHandler(d)(post());
  assertEquals(settles.length, 0);
});

Deno.test("no provider id, found by the current attempt → settle paid", async () => {
  const looked: string[] = [];
  const { d, settles } = deps([row({ provider_payment_id: null })], {
    find: async (ext) => { looked.push(ext); return mf("paid", "0707-9"); },
  });
  await makeHandler(d)(post());
  assertEquals(settles[0].p_outcome, "paid");
  assertEquals(settles[0].p_provider_payment_id, "0707-9");
  assertEquals(looked, ["pay-1:att"]);
  assertEquals(settles[0].p_attempt, "pay-1:att");
});

Deno.test("no provider id, not found, older than 30 min → failed", async () => {
  const { d, settles } = deps([row({ provider_payment_id: null, updated_at: minutesAgo(31) })]);
  await makeHandler(d)(post());
  assertEquals(settles[0].p_outcome, "failed");
  assertEquals(settles[0].p_provider_payment_id, null);
});

Deno.test("not found, younger → untouched", async () => {
  const { d, settles } = deps([row({ provider_payment_id: null, updated_at: minutesAgo(10) })]);
  await makeHandler(d)(post());
  assertEquals(settles.length, 0);
});

Deno.test("one row failing does not stop the others", async () => {
  const { d, settles } = deps([row({ id: "a", provider_payment_id: "bad" }), row({ id: "b" })], {
    get: async (id) => { if (id === "bad") throw new Error("boom"); return mf("paid"); },
  });
  const res = await makeHandler(d)(post());
  assertEquals(await res.json(), { checked: 2, settled: 1 });
  assertEquals(settles.map((s) => s.p_payment_id), ["b"]);
});

Deno.test("a card payment is labelled creditcard", async () => {
  const { d, settles } = deps([row()], { get: async () => ({ ...mf("paid"), method: "MADA" }) });
  await makeHandler(d)(post());
  assertEquals(settles[0].p_payment_method, "creditcard");
});
