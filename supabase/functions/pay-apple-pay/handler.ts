// Takes the Apple Pay token the phone got from PassKit and turns it into money,
// with the API key the phone never sees. The amount is the database's; nothing
// the app sends can change it.
//
// Each Apple Pay authorization is one "attempt", named `<payment id>:<start of
// Apple's transaction id>`. That name is MyFatoorah's ExternalIdentifier and the
// idempotency key, and the row remembers it as current_attempt. A late answer
// about an earlier attempt can therefore never fail the one in flight, and a
// second charge on a paid row is recognised and refunded by settle_payment.
//
// claim_payment_attempt moves the row to `processing` BEFORE MyFatoorah is
// called, atomically. If this function dies mid-call, or the gateway answers
// with a 5xx after the charge went through, the row is still findable: the
// webhook and the payment sweep settle it from MyFatoorah's own answer.
import { corsHeaders, json } from "../_shared/cors.ts";
import { type MfPayment, MyFatoorahError } from "../_shared/myfatoorah.ts";

export type SettleArgs = {
  p_payment_id: string;
  p_provider_payment_id: string | null;
  p_outcome: "paid" | "failed" | "processing";
  p_payment_method: string | null;
  p_amount: number;
  p_currency: string;
  p_attempt: string | null;
};

export type ClaimResult =
  | { status: "claimed"; amount: number; currency: string }
  | { status: "paid" | "processing" | "not_found" | "not_payable" | "event_closed" };

export type PayDeps = {
  getUserId(auth: string | null): Promise<string | null>;
  claim(paymentId: string, userId: string, attempt: string): Promise<ClaimResult>;
  mf: {
    payWithApplePay(args: {
      amountHalalas: number;
      currency: string;
      tokenJson: string;
      externalIdentifier: string;
      idempotencyKey: string;
    }): Promise<MfPayment>;
  };
  settle(args: SettleArgs): Promise<{ status: string }>;
};

export function attemptRef(paymentId: string, transactionIdentifier: string): string {
  return `${paymentId}:${transactionIdentifier.slice(0, 16)}`;
}

/// Our payment id from an attempt reference (or from a bare payment id).
export function paymentIdOf(attempt: string): string {
  return attempt.split(":")[0];
}

export function makeHandler(deps: PayDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

    const userId = await deps.getUserId(req.headers.get("authorization"));
    if (!userId) return json({ error: "unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));
    const paymentId = typeof body?.payment_id === "string" ? body.payment_id : null;
    const token = body?.token;
    const txId = typeof token?.TransactionIdentifier === "string" ? token.TransactionIdentifier : null;
    if (!paymentId || !token || typeof token !== "object" || !token.PaymentData || !txId) {
      return json({ error: "payment_id and an Apple Pay token are required" }, 400);
    }

    const attempt = attemptRef(paymentId, txId);
    const claim = await deps.claim(paymentId, userId, attempt);
    switch (claim.status) {
      case "not_found": return json({ error: "not found" }, 404);
      case "paid": return json({ status: "paid" });
      case "processing": return json({ status: "processing" });
      case "not_payable":
      case "event_closed": return json({ status: "failed", reason: claim.status }, 409);
    }

    let result: MfPayment;
    try {
      result = await deps.mf.payWithApplePay({
        amountHalalas: claim.amount,
        currency: claim.currency,
        tokenJson: JSON.stringify(token),
        externalIdentifier: attempt,
        idempotencyKey: `pay:${attempt}`,
      });
    } catch (error) {
      if (error instanceof MyFatoorahError && error.definitive) {
        // MyFatoorah answered clearly and said no: nothing was charged.
        console.error("pay-apple-pay: MyFatoorah refused", error.status, error.body.slice(0, 300));
        await deps.settle({
          p_payment_id: paymentId, p_provider_payment_id: null, p_outcome: "failed",
          p_payment_method: "applepay", p_amount: claim.amount, p_currency: claim.currency,
          p_attempt: attempt,
        });
        return json({ status: "failed", reason: "refused" });
      }
      // No clear answer: the charge may or may not have happened. The row
      // stays `processing` for the webhook or the sweep to settle.
      console.error("pay-apple-pay: no clear answer from MyFatoorah", error);
      return json({ status: "processing" });
    }

    const settled = await deps.settle({
      p_payment_id: paymentId,
      p_provider_payment_id: result.paymentId || null,
      p_outcome: result.outcome,
      p_payment_method: "applepay",
      p_amount: result.amountHalalas,
      p_currency: result.currency,
      p_attempt: attempt,
    });

    if (result.outcome === "processing") return json({ status: "processing" });
    if (result.outcome === "failed") {
      return json({ status: "failed", reason: result.errorMessage ?? "declined" });
    }
    if (settled.status === "settled" || settled.status === "already_settled") {
      return json({ status: "paid" });
    }
    return json({ status: "failed", reason: settled.status });
  };
}
