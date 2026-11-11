// Takes the Apple Pay token the phone got from PassKit and turns it into money,
// with the API key the phone never sees. The amount is the database's; nothing
// the app sends can change it.
//
// The row goes to `processing` BEFORE MyFatoorah is called. If this function
// dies mid-call, or the network drops after the charge went through, the row is
// still findable: the webhook and the payment sweep settle it from MyFatoorah's
// own answer. The member never sees a seat they paid for stay unconfirmed.
import { corsHeaders, json } from "../_shared/cors.ts";
import { type MfPayment, MyFatoorahError } from "../_shared/myfatoorah.ts";

export type PaymentRow = {
  id: string;
  user_id: string;
  amount: number;
  currency: string;
  status: string;
};

export type SettleArgs = {
  p_payment_id: string;
  p_provider_payment_id: string | null;
  p_outcome: "paid" | "failed" | "processing";
  p_payment_method: string | null;
  p_amount: number;
  p_currency: string;
};

export type PayDeps = {
  getUserId(auth: string | null): Promise<string | null>;
  loadPayment(id: string): Promise<PaymentRow | null>;
  markProcessing(id: string): Promise<void>;
  mf: {
    payWithApplePay(args: {
      amountHalalas: number;
      tokenJson: string;
      externalIdentifier: string;
      idempotencyKey: string;
    }): Promise<MfPayment>;
  };
  settle(args: SettleArgs): Promise<{ status: string }>;
};

const PAYABLE = new Set(["pending", "failed"]);

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

    const row = await deps.loadPayment(paymentId);
    if (!row || row.user_id !== userId) return json({ error: "not found" }, 404);
    if (row.status === "paid") return json({ status: "paid" });
    if (row.status === "processing") return json({ status: "processing" });
    if (!PAYABLE.has(row.status)) return json({ status: "failed", reason: "not_payable" }, 409);

    await deps.markProcessing(row.id);

    let result: MfPayment;
    try {
      result = await deps.mf.payWithApplePay({
        amountHalalas: row.amount,
        tokenJson: JSON.stringify(token),
        externalIdentifier: row.id,
        // One key per Apple Pay authorization: a repeat of the same token gets
        // MyFatoorah's cached answer, a fresh token after a decline is new.
        idempotencyKey: `pay:${row.id}:${txId}`,
      });
    } catch (error) {
      if (error instanceof MyFatoorahError) {
        // MyFatoorah answered and said no: nothing was charged.
        console.error("pay-apple-pay: MyFatoorah refused", error.status, error.body.slice(0, 300));
        await deps.settle({
          p_payment_id: row.id, p_provider_payment_id: null, p_outcome: "failed",
          p_payment_method: "applepay", p_amount: row.amount, p_currency: row.currency,
        });
        return json({ status: "failed", reason: "refused" });
      }
      // No answer: the charge may or may not have happened. The row stays
      // `processing` for the webhook or the sweep to settle.
      console.error("pay-apple-pay: no answer from MyFatoorah", error);
      return json({ status: "processing" });
    }

    const settled = await deps.settle({
      p_payment_id: row.id,
      p_provider_payment_id: result.paymentId || null,
      p_outcome: result.outcome,
      p_payment_method: "applepay",
      p_amount: result.amountHalalas,
      p_currency: result.currency,
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
