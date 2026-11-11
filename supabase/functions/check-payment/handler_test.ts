import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { type CheckPaymentDeps, makeHandler, type OwnPayment } from "./handler.ts";
import type { MfPayment } from "../_shared/myfatoorah.ts";

const NOW = new Date("2026-11-12T12:00:00Z");

function mf(outcome: MfPayment["outcome"]): MfPayment {
  return {
    paymentId: "0707-1", invoiceId: "inv", externalIdentifier: "pay-1:card1", outcome,
    amountHalalas: 100, currency: "SAR", baseCurrency: "SAR", baseValue: 1,
    method: "MADA", errorMessage: null,
  };
}

function deps(opts: {
  row?: Partial<OwnPayment> | null;
  get?: () => Promise<MfPayment>;
  find?: (ext: string) => Promise<MfPayment | null>;
} = {}) {
  const calls: string[] = [];
  const settles: Array<Parameters<CheckPaymentDeps["settle"]>[0]> = [];
  const row: OwnPayment | null = opts.row === null ? null : {
    id: "pay-1", user_id: "user-1", status: "processing", provider: "myfatoorah",
    provider_payment_id: null, current_attempt: "pay-1:card1", amount: 100, currency: "SAR",
    updated_at: new Date(NOW.getTime() - 60_000).toISOString(), ...(opts.row ?? {}),
  };
  const d: CheckPaymentDeps = {
    now: () => NOW,
    getUserId: async (a) => (a === "Bearer good" ? "user-1" : null),
    loadPayment: async (id) => (row && id === row.id ? row : null),
    mf: {
      getPayment: async () => { calls.push("get"); return opts.get ? opts.get() : mf("paid"); },
      findPaymentByExternalIdentifier: async (ext) => {
        calls.push(`find:${ext}`);
        return opts.find ? opts.find(ext) : mf("paid");
      },
    },
    settle: async (a) => { settles.push(a); return { status: a.p_outcome === "paid" ? "settled" : a.p_outcome }; },
  };
  return { d, calls, settles };
}

const post = (body: unknown, auth = "Bearer good") =>
  new Request("http://x/check-payment", {
    method: "POST", headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("401 without auth, 400 without payment_id", async () => {
  const { d } = deps();
  assertEquals((await makeHandler(d)(post({ payment_id: "pay-1" }, "Bearer bad"))).status, 401);
  assertEquals((await makeHandler(d)(post({}))).status, 400);
});

Deno.test("someone else's payment is not found", async () => {
  const { d, calls } = deps({ row: { user_id: "user-2" } });
  assertEquals((await makeHandler(d)(post({ payment_id: "pay-1" }))).status, 404);
  assertEquals(calls.length, 0);
});

Deno.test("a payment that is not moving answers its state without asking MyFatoorah", async () => {
  for (const [status, want] of [["paid", "paid"], ["failed", "failed"], ["pending", "failed"], ["cancelled", "failed"]]) {
    const { d, calls } = deps({ row: { status } });
    const res = await makeHandler(d)(post({ payment_id: "pay-1" }));
    assertEquals(await res.json(), { status: want }, status);
    assertEquals(calls.length, 0, status);
  }
});

Deno.test("a Moyasar-era payment is never looked up at MyFatoorah", async () => {
  const { d, calls } = deps({ row: { provider: "moyasar" } });
  const res = await makeHandler(d)(post({ payment_id: "pay-1" }));
  assertEquals(await res.json(), { status: "processing" });
  assertEquals(calls.length, 0);
});

Deno.test("processing: asks MyFatoorah by the current attempt and settles a payment it finds paid", async () => {
  const { d, calls, settles } = deps();
  const res = await makeHandler(d)(post({ payment_id: "pay-1" }));
  assertEquals(await res.json(), { status: "paid" });
  assertEquals(calls, ["find:pay-1:card1"]);
  assertEquals(settles[0], {
    p_payment_id: "pay-1", p_provider_payment_id: "0707-1", p_outcome: "paid",
    p_payment_method: "creditcard", p_amount: 100, p_currency: "SAR", p_attempt: "pay-1:card1",
  });
});

Deno.test("still processing at MyFatoorah (or not paid yet) answers processing", async () => {
  for (const find of [async () => mf("processing"), async () => null]) {
    const { d, settles } = deps({ find });
    const res = await makeHandler(d)(post({ payment_id: "pay-1" }));
    assertEquals(await res.json(), { status: "processing" });
    assertEquals(settles.length, 0);
  }
});

Deno.test("declined at MyFatoorah answers failed", async () => {
  const { d } = deps({ find: async () => mf("failed") });
  const res = await makeHandler(d)(post({ payment_id: "pay-1" }));
  assertEquals(await res.json(), { status: "failed" });
});

Deno.test("MyFatoorah unreachable answers processing; the sweep keeps trying", async () => {
  const { d, settles } = deps({ find: async () => { throw new TypeError("network down"); } });
  const res = await makeHandler(d)(post({ payment_id: "pay-1" }));
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { status: "processing" });
  assertEquals(settles.length, 0);
});
