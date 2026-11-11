// TEST ONLY. Lets the sandbox app pay with a MyFatoorah test card while Apple
// Pay waits for its certificate. Creates the payment the same way Apple Pay
// does (claim the row, one attempt, our ExternalIdentifier) but asks MyFatoorah
// for its hosted card page instead of sending an Apple Pay token. What happens
// after the card is paid is the real pipeline: the webhook or the payment
// sweep settles it, and refunds run as for any payment.
//
// It refuses to run unless it points at MyFatoorah's TEST server and the
// sandbox-only switch is on, so it can never take real money.
import { corsHeaders, json } from "../_shared/cors.ts";
import { MyFatoorahError } from "../_shared/myfatoorah.ts";
import type { ClaimResult, SettleArgs } from "../pay-apple-pay/handler.ts";

export type CardTestDeps = {
  enabled: boolean;
  redirectUrl: string;
  newAttemptSuffix(): string;
  getUserId(auth: string | null): Promise<string | null>;
  claim(paymentId: string, userId: string, attempt: string): Promise<ClaimResult>;
  mf: {
    createCardPayment(args: {
      amountHalalas: number;
      currency: string;
      externalIdentifier: string;
      idempotencyKey: string;
      redirectUrl: string;
    }): Promise<{ invoiceId: string; paymentUrl: string }>;
  };
  settle(args: SettleArgs): Promise<{ status: string }>;
};

export function testCardsAllowed(flag: string | undefined, baseUrl: string): boolean {
  if (flag !== "true") return false;
  try {
    return new URL(baseUrl).hostname === "apitest.myfatoorah.com";
  } catch {
    return false;
  }
}

export function makeHandler(deps: CardTestDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
    if (!deps.enabled) return json({ error: "test card payments are off" }, 403);

    const userId = await deps.getUserId(req.headers.get("authorization"));
    if (!userId) return json({ error: "unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));
    const paymentId = typeof body?.payment_id === "string" ? body.payment_id : null;
    if (!paymentId) return json({ error: "payment_id required" }, 400);

    const attempt = `${paymentId}:card${deps.newAttemptSuffix()}`;
    const claim = await deps.claim(paymentId, userId, attempt);
    switch (claim.status) {
      case "not_found": return json({ error: "not found" }, 404);
      case "paid": return json({ status: "paid" });
      case "processing": return json({ status: "processing" });
      case "not_payable":
      case "event_closed": return json({ status: "failed", reason: claim.status }, 409);
    }

    try {
      const link = await deps.mf.createCardPayment({
        amountHalalas: claim.amount,
        currency: claim.currency,
        externalIdentifier: attempt,
        idempotencyKey: `card:${attempt}`,
        redirectUrl: deps.redirectUrl,
      });
      return json({ status: "ready", payment_url: link.paymentUrl });
    } catch (error) {
      if (error instanceof MyFatoorahError && error.definitive) {
        await deps.settle({
          p_payment_id: paymentId, p_provider_payment_id: null, p_outcome: "failed",
          p_payment_method: "creditcard", p_amount: claim.amount, p_currency: claim.currency,
          p_attempt: attempt,
        });
        return json({ status: "failed", reason: "refused" });
      }
      // No page came back. The row stays `processing`; the sweep finds no
      // payment for this attempt and releases it after 30 minutes.
      console.error("pay-card-test: no link from MyFatoorah", error);
      return json({ status: "failed", reason: "no_link" }, 502);
    }
  };
}
