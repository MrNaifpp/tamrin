import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { attemptRef, makeHandler, type PayDeps } from "./handler.ts";
import { type MfPayment, MyFatoorahError } from "../_shared/myfatoorah.ts";

const token = {
  PaymentData: { version: "EC_v1", data: "abc" },
  PaymentMethod: { displayName: "mada 1234", network: "mada", type: "debit" },
  TransactionIdentifier: "0123456789abcdef0123456789abcdef",
};
const ATT_A = "pay-1:0123456789abcdef";

function mfPayment(outcome: MfPayment["outcome"], over: Partial<MfPayment> = {}): MfPayment {
  return {
    paymentId: "0707-1", invoiceId: "inv-1", externalIdentifier: ATT_A, outcome,
    amountHalalas: 6000, currency: "SAR", baseCurrency: "SAR", baseValue: 60, method: "Apple Pay",
    errorMessage: outcome === "failed" ? "DECLINED : Do not honour" : null, ...over,
  };
}

type ClaimStatus = "claimed" | "paid" | "processing" | "not_found" | "not_payable" | "event_closed";

function deps(opts: {
  claim?: ClaimStatus | ((attempt: string) => ClaimStatus);
  pay?: (args: Parameters<PayDeps["mf"]["payWithApplePay"]>[0]) => Promise<MfPayment>;
  settleStatus?: string;
} = {}) {
  const log: string[] = [];
  const claims: Array<{ paymentId: string; userId: string; attempt: string }> = [];
  const payCalls: Array<Parameters<PayDeps["mf"]["payWithApplePay"]>[0]> = [];
  const settles: Array<Parameters<PayDeps["settle"]>[0]> = [];
  const d: PayDeps = {
    getUserId: async (a) => (a === "Bearer good" ? "user-1" : null),
    claim: async (paymentId, userId, attempt) => {
      claims.push({ paymentId, userId, attempt });
      log.push("claim");
      const c = typeof opts.claim === "function" ? opts.claim(attempt) : (opts.claim ?? "claimed");
      return c === "claimed" ? { status: c, amount: 6000, currency: "SAR" } : { status: c };
    },
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
      return { status: opts.settleStatus ?? (args.p_outcome === "paid" ? "settled" : args.p_outcome) };
    },
  };
  return { d, log, claims, payCalls, settles };
}

const post = (body: unknown, auth = "Bearer good") =>
  new Request("http://x/pay-apple-pay", {
    method: "POST", headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("attempt reference is the payment id plus the start of Apple's transaction id", () => {
  assertEquals(attemptRef("pay-1", token.TransactionIdentifier), ATT_A);
});

Deno.test("rejects without auth (401)", async () => {
  const { d, claims } = deps();
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }, "Bearer bad"));
  assertEquals(res.status, 401);
  assertEquals(claims.length, 0);
});

Deno.test("missing token (400)", async () => {
  const { d } = deps();
  assertEquals((await makeHandler(d)(post({ payment_id: "pay-1" }))).status, 400);
  assertEquals((await makeHandler(d)(post({ payment_id: "pay-1", token: { PaymentData: {} } }))).status, 400);
});

Deno.test("claims as the caller, with this attempt", async () => {
  const { d, claims } = deps();
  await makeHandler(d)(post({ payment_id: "pay-1", token, user_id: "someone-else" }));
  assertEquals(claims, [{ paymentId: "pay-1", userId: "user-1", attempt: ATT_A }]);
});

Deno.test("claim answers that charge nothing", async () => {
  const cases: Array<[ClaimStatus, number, unknown]> = [
    ["not_found", 404, { error: "not found" }],
    ["paid", 200, { status: "paid" }],
    ["processing", 200, { status: "processing" }],
    ["not_payable", 409, { status: "failed", reason: "not_payable" }],
    ["event_closed", 409, { status: "failed", reason: "event_closed" }],
  ];
  for (const [claim, code, body] of cases) {
    const { d, payCalls } = deps({ claim });
    const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
    assertEquals(res.status, code, claim);
    assertEquals(await res.json(), body, claim);
    assertEquals(payCalls.length, 0, claim);
  }
});

Deno.test("sends the claimed amount and currency, not the body's", async () => {
  const { d, payCalls } = deps();
  await makeHandler(d)(post({ payment_id: "pay-1", token, amount: 1, currency: "USD" }));
  assertEquals(payCalls[0].amountHalalas, 6000);
  assertEquals(payCalls[0].currency, "SAR");
  assertEquals(payCalls[0].externalIdentifier, ATT_A);
  assertEquals(payCalls[0].tokenJson, JSON.stringify(token));
});

Deno.test("idempotency key is the attempt; a new token is a new attempt", async () => {
  const { d, payCalls } = deps({ pay: async () => mfPayment("failed") });
  const h = makeHandler(d);
  await h(post({ payment_id: "pay-1", token }));
  await h(post({ payment_id: "pay-1", token: { ...token, TransactionIdentifier: "ffffffffffffffff9999" } }));
  assertEquals(payCalls.map((c) => c.idempotencyKey), [`pay:${ATT_A}`, "pay:pay-1:ffffffffffffffff"]);
});

Deno.test("claims before calling MyFatoorah", async () => {
  const { d, log } = deps();
  await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(log, ["claim", "pay", "settle:paid"]);
});

Deno.test("paid outcome settles with the attempt and answers paid", async () => {
  const { d, settles } = deps();
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(await res.json(), { status: "paid" });
  assertEquals(settles[0], {
    p_payment_id: "pay-1", p_provider_payment_id: "0707-1", p_outcome: "paid",
    p_payment_method: "applepay", p_amount: 6000, p_currency: "SAR", p_attempt: ATT_A,
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
  assertEquals(settles[0].p_attempt, ATT_A);
});

Deno.test("processing outcome answers processing", async () => {
  const { d, settles } = deps({ pay: async () => mfPayment("processing") });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(await res.json(), { status: "processing" });
  assertEquals(settles[0].p_outcome, "processing");
});

Deno.test("a clear MyFatoorah refusal is a failure for this attempt", async () => {
  const { d, settles } = deps({
    pay: async () => { throw new MyFatoorahError(400, '{"IsSuccess":false,"Message":"Invalid token"}', true); },
  });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals((await res.json()).status, "failed");
  assertEquals(settles[0].p_outcome, "failed");
  assertEquals(settles[0].p_provider_payment_id, null);
  assertEquals(settles[0].p_attempt, ATT_A);
});

Deno.test("a gateway error is not a refusal: the row stays processing", async () => {
  for (const err of [new MyFatoorahError(504, "<html>Gateway Timeout</html>"), new MyFatoorahError(502, '{"IsSuccess":false}', true)]) {
    const { d, settles } = deps({ pay: async () => { throw err; } });
    const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
    assertEquals(await res.json(), { status: "processing" });
    assertEquals(settles.length, 0);
  }
});

Deno.test("network error leaves processing", async () => {
  const { d, settles, log } = deps({ pay: async () => { throw new TypeError("network down"); } });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", token }));
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { status: "processing" });
  assertEquals(settles.length, 0);
  assertEquals(log, ["claim", "pay"]);
});
