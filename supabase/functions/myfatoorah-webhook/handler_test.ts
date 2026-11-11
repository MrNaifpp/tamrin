import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler, type WebhookDeps } from "./handler.ts";
import type { MfPayment, MfRefund } from "../_shared/myfatoorah.ts";
import {
  fieldsString,
  paymentSignatureFields,
  refundSignatureFields,
} from "../_shared/myfatoorah_signature.ts";

const SECRET = "whsec";

async function sign(message: string, secret = SECRET): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message)));
  return btoa(String.fromCharCode(...mac));
}

const paymentData = {
  Invoice: { Id: "inv-1", Status: "PAID", ExternalIdentifier: "pay-1" },
  Transaction: { Status: "SUCCESS", PaymentId: "0707-1" },
};
const refundData = {
  Refund: { Id: "R1", Status: "REFUNDED", ExternalIdentifier: "ref-1" },
  Amount: { ValueInBaseCurrency: 30 },
  ReferencedInvoice: { Id: "inv-1" },
};

async function paymentEvent(data = paymentData, reference = "evt-1", secret = SECRET) {
  const body = { Event: { Code: 1, Name: "PAYMENT_STATUS_CHANGED", Reference: reference }, Data: data };
  const sig = await sign(fieldsString(paymentSignatureFields(data)), secret);
  return new Request("http://x/myfatoorah-webhook", {
    method: "POST", headers: { "myfatoorah-signature": sig, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function refundEvent(data = refundData, reference = "evt-r1") {
  const body = { Event: { Code: 2, Name: "REFUND_STATUS_CHANGED", Reference: reference }, Data: data };
  const sig = await sign(fieldsString(refundSignatureFields(data)));
  return new Request("http://x/myfatoorah-webhook", {
    method: "POST", headers: { "myfatoorah-signature": sig, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

function mfPayment(outcome: MfPayment["outcome"]): MfPayment {
  return {
    paymentId: "0707-1", invoiceId: "inv-1", externalIdentifier: "pay-1", outcome,
    amountHalalas: 6000, currency: "SAR", method: "Apple Pay", errorMessage: null,
  };
}

function deps(opts: { remote?: MfPayment; refund?: MfRefund; knownPayment?: boolean; knownRefund?: boolean } = {}) {
  const seen = new Set<string>();
  const log: string[] = [];
  const payArgs: unknown[] = [];
  const refundArgs: unknown[] = [];
  const d: WebhookDeps = {
    secret: SECRET,
    recordEvent: async (e) => {
      if (seen.has(e.reference)) return "duplicate";
      seen.add(e.reference);
      log.push(`record:${e.reference}`);
      return "new";
    },
    linkEvent: async () => {},
    findPaymentById: async (id) => (opts.knownPayment === false || id !== "pay-1" ? null : { id }),
    findRefundById: async (id) => (opts.knownRefund === false || id !== "ref-1" ? null : { id }),
    mf: {
      getPayment: async (id) => { log.push(`get:${id}`); return opts.remote ?? mfPayment("paid"); },
      getRefund: async (id) => {
        log.push(`getRefund:${id}`);
        return opts.refund ?? { refundId: "R1", status: "refunded", amountHalalas: 3000 };
      },
    },
    settlePayment: async (args) => { payArgs.push(args); return { status: "settled" }; },
    settleRefund: async (args) => { refundArgs.push(args); return { status: "settled" }; },
  };
  return { d, log, payArgs, refundArgs };
}

Deno.test("bad signature → 401, nothing recorded", async () => {
  const { d, log } = deps();
  const res = await makeHandler(d)(await paymentEvent(paymentData, "evt-1", "wrong"));
  assertEquals(res.status, 401);
  assertEquals(log, []);
});

Deno.test("replayed reference → duplicate, no settle", async () => {
  const { d, payArgs } = deps();
  const h = makeHandler(d);
  await h(await paymentEvent());
  const res = await h(await paymentEvent());
  assertEquals(await res.json(), { status: "duplicate" });
  assertEquals(payArgs.length, 1);
});

Deno.test("payment event re-fetches and settles from GET, not from the body", async () => {
  const { d, log, payArgs } = deps({ remote: mfPayment("failed") });
  const res = await makeHandler(d)(await paymentEvent());
  assertEquals(res.status, 200);
  assertEquals(log, ["record:evt-1", "get:0707-1"]);
  assertEquals(payArgs, [{
    p_payment_id: "pay-1", p_provider_payment_id: "0707-1", p_outcome: "failed",
    p_payment_method: "applepay", p_amount: 6000, p_currency: "SAR",
  }]);
});

Deno.test("re-fetched payment for another order is ignored", async () => {
  const { d, payArgs } = deps({ remote: { ...mfPayment("paid"), externalIdentifier: "pay-2" } });
  const res = await makeHandler(d)(await paymentEvent());
  assertEquals((await res.json()).status, "ignored");
  assertEquals(payArgs.length, 0);
});

Deno.test("payment event for unknown ExternalIdentifier → 200 ignored", async () => {
  const { d, payArgs } = deps({ knownPayment: false });
  const res = await makeHandler(d)(await paymentEvent());
  assertEquals(res.status, 200);
  assertEquals((await res.json()).status, "ignored");
  assertEquals(payArgs.length, 0);
});

Deno.test("refund event re-fetches GET /v3/refunds and settles", async () => {
  const cases: Array<[MfRefund["status"], string]> = [["refunded", "refunded"], ["canceled", "failed"], ["pending", "pending"]];
  for (const [remote, want] of cases) {
    const { d, log, refundArgs } = deps({ refund: { refundId: "R1", status: remote, amountHalalas: 3000 } });
    await makeHandler(d)(await refundEvent());
    assertEquals(log.includes("getRefund:R1"), true);
    assertEquals((refundArgs[0] as { p_status: string; p_refund_id: string; p_provider_refund_id: string }), {
      ...(refundArgs[0] as object),
      p_refund_id: "ref-1", p_status: want, p_provider_refund_id: "R1",
    });
  }
});

Deno.test("refund event for a refund we did not create is ignored", async () => {
  const { d, refundArgs } = deps({ knownRefund: false });
  const res = await makeHandler(d)(await refundEvent());
  assertEquals((await res.json()).status, "ignored");
  assertEquals(refundArgs.length, 0);
});

Deno.test("other event codes → 200 ignored", async () => {
  const { d, log } = deps();
  const res = await makeHandler(d)(new Request("http://x", {
    method: "POST", body: JSON.stringify({ Event: { Code: 3, Reference: "evt-3" }, Data: {} }),
  }));
  assertEquals(res.status, 200);
  assertEquals((await res.json()).status, "ignored");
  assertEquals(log, []);
});
