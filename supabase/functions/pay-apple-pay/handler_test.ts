import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler, type PayDeps, type PaymentRow } from "./handler.ts";
import { type MfPayment, MyFatoorahError } from "../_shared/myfatoorah.ts";

const token = {
  PaymentData: { version: "EC_v1", data: "abc" },
  PaymentMethod: { displayName: "mada 1234", network: "mada", type: "debit" },
  TransactionIdentifier: "tx-A",
};

function mfPayment(outcome: MfPayment["outcome"], over: Partial<MfPayment> = {}): MfPayment {
  return {
    paymentId: "0707-1", invoiceId: "inv-1", externalIdentifier: "pay-1", outcome,
    amountHalalas: 6000, currency: "SAR", method: "Apple Pay",
    errorMessage: outcome === "failed" ? "DECLINED : Do not honour" : null, ...over,
  };
}

function deps(opts: {
  row?: Partial<PaymentRow> | null;
  pay?: (args: Parameters<PayDeps["mf"]["payWithApplePay"]>[0]) => Promise<MfPayment>;
  settleStatus?: string;
} = {}) {
  const log: string[] = [];
  const payCalls: Array<Parameters<PayDeps["mf"]["payWithApplePay"]>[0]> = [];
  const settles: Array<Parameters<PayDeps["settle"]>[0]> = [];
  let row: PaymentRow | null = opts.row === null ? null : {
    id: "pay-1", user_id: "user-1", amount: 6000, currency: "SAR", status: "pending",
    ...(opts.row ?? {}),
  };
  const d: PayDeps = {
    getUserId: async (a) => (a === "Bearer good" ? "user-1" : null),
    loadPayment: async (id) => (row && id === row.id ? { ...row } : null),
    markProcessing: async () => { log.push("processing"); if (row) row = { ...row, status: "processing" }; },
    mf: {
      payWithApplePay: async (args) => {
        payCalls.push(args);
        log.push("pay");
        return opts.pay ? opts.pay(args) : mfPayment("paid");
      },
    },
    settle: async (args) => {
      settles.push(args);
      log.push(`settle:${args.p_outcome}`);
      if (row) row = { ...row, status: args.p_outcome === "paid" ? "paid" : args.p_outcome };
      return { status: opts.settleStatus ?? (args.p_outcome === "paid" ? "settled" : args.p_outcome) };
    },
  };
  return { d, log, payCalls, settles, setStatus: (s: string) => { if (row) row = { ...row, status: s }; } };
}

const post = (body: unknown, auth = "Bearer good") =>
  new Request("http://x/pay-apple-pay", {
    method: "POST", headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("rejects without auth (401)", async () => {
  const { d } = deps();
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }, "Bearer bad"));
  assertEquals(res.status, 401);
});

Deno.test("rejects someone else's payment (404)", async () => {
  const { d, payCalls } = deps({ row: { user_id: "user-2" } });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(res.status, 404);
  assertEquals(payCalls.length, 0);
});

Deno.test("missing token (400)", async () => {
  const { d } = deps();
  assertEquals((await makeHandler(d)(post({ payment_id: "pay-1" }))).status, 400);
  assertEquals((await makeHandler(d)(post({ payment_id: "pay-1", token: { PaymentData: {} } }))).status, 400);
});

Deno.test("already paid returns paid without calling MyFatoorah", async () => {
  const { d, payCalls } = deps({ row: { status: "paid" } });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(await res.json(), { status: "paid" });
  assertEquals(payCalls.length, 0);
});

Deno.test("a payment already moving is not charged again", async () => {
  const { d, payCalls } = deps({ row: { status: "processing" } });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(await res.json(), { status: "processing" });
  assertEquals(payCalls.length, 0);
});

Deno.test("a cancelled quote cannot be paid", async () => {
  const { d, payCalls } = deps({ row: { status: "cancelled" } });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(res.status, 409);
  assertEquals(payCalls.length, 0);
});

Deno.test("sends database amount, not body amount", async () => {
  const { d, payCalls } = deps();
  await makeHandler(d)(post({ payment_id: "pay-1", token, amount: 1 }));
  assertEquals(payCalls[0].amountHalalas, 6000);
  assertEquals(payCalls[0].externalIdentifier, "pay-1");
  assertEquals(payCalls[0].tokenJson, JSON.stringify(token));
});

Deno.test("idempotency key is payment id plus TransactionIdentifier", async () => {
  const { d, payCalls } = deps();
  await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(payCalls[0].idempotencyKey, "pay:pay-1:tx-A");
});

Deno.test("retries with a new token are sent; same token is not re-sent", async () => {
  const { d, payCalls } = deps({ pay: async () => mfPayment("failed") });
  const h = makeHandler(d);
  await h(post({ payment_id: "pay-1", token }));
  await h(post({ payment_id: "pay-1", token }));
  await h(post({ payment_id: "pay-1", token: { ...token, TransactionIdentifier: "tx-B" } }));
  assertEquals(payCalls.map((c) => c.idempotencyKey), ["pay:pay-1:tx-A", "pay:pay-1:tx-A", "pay:pay-1:tx-B"]);
});

Deno.test("marks the row processing before calling MyFatoorah", async () => {
  const { d, log } = deps();
  await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(log, ["processing", "pay", "settle:paid"]);
});

Deno.test("paid outcome settles and answers paid", async () => {
  const { d, settles } = deps();
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(await res.json(), { status: "paid" });
  assertEquals(settles[0], {
    p_payment_id: "pay-1", p_provider_payment_id: "0707-1", p_outcome: "paid",
    p_payment_method: "applepay", p_amount: 6000, p_currency: "SAR",
  });
});

Deno.test("an amount mismatch from settle is a failure", async () => {
  const { d } = deps({ settleStatus: "amount_mismatch" });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(await res.json(), { status: "failed", reason: "amount_mismatch" });
});

Deno.test("failed outcome settles failed with reason", async () => {
  const { d, settles } = deps({ pay: async () => mfPayment("failed") });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(await res.json(), { status: "failed", reason: "DECLINED : Do not honour" });
  assertEquals(settles[0].p_outcome, "failed");
});

Deno.test("processing outcome answers processing", async () => {
  const { d, settles } = deps({ pay: async () => mfPayment("processing") });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(await res.json(), { status: "processing" });
  assertEquals(settles[0].p_outcome, "processing");
});

Deno.test("a MyFatoorah refusal is a failure, settled without a provider id", async () => {
  const { d, settles } = deps({ pay: async () => { throw new MyFatoorahError(400, "Invalid Apple Pay token"); } });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
  const body = await res.json();
  assertEquals(body.status, "failed");
  assertEquals(settles[0].p_outcome, "failed");
  assertEquals(settles[0].p_provider_payment_id, null);
});

Deno.test("network error leaves processing", async () => {
  const { d, settles, log } = deps({ pay: async () => { throw new TypeError("network down"); } });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { status: "processing" });
  assertEquals(settles.length, 0);
  assertEquals(log, ["processing", "pay"]);
});
