// Sends money back. Called server to server by the refunds trigger and the
// refund sweep, so the gate is a shared secret rather than a user's JWT — the
// same arrangement send-push uses: Postgres cannot present a Supabase JWT.
//
// The amount is read from the refunds row; the request body carries an id and
// nothing else. What happens next depends on where the row is:
//   pending / waiting_balance → ask MyFatoorah for a refund
//   processing with an id     → ask MyFatoorah how that refund is going
//   processing without one    → an earlier send got no answer; send again
//                               with the same idempotency key
import { json } from "../_shared/cors.ts";
import { type MfRefund, MyFatoorahError } from "../_shared/myfatoorah.ts";
import { refundStatusFor, type SettleRefundArgs } from "../myfatoorah-webhook/handler.ts";

export type RefundRow = {
  id: string;
  provider_payment_id: string;
  provider_refund_id: string | null;
  amount: number;
  status: string;
  attempts: number;
};

export type RefundDeps = {
  sharedSecret: string;
  loadRefund(id: string): Promise<RefundRow | null>;
  markProcessing(id: string): Promise<void>;
  mf: {
    createRefund(args: {
      paymentId: string;
      amountHalalas: number;
      externalIdentifier: string;
      idempotencyKey: string;
    }): Promise<MfRefund>;
    getRefund(refundId: string): Promise<MfRefund>;
  };
  settle(args: SettleRefundArgs): Promise<{ status: string }>;
};

export function makeHandler(deps: RefundDeps) {
  return async (req: Request): Promise<Response> => {
    if (!deps.sharedSecret || req.headers.get("authorization") !== `Bearer ${deps.sharedSecret}`) {
      return json({ error: "unauthorized" }, 401);
    }

    const body = await req.json().catch(() => ({}));
    const refundId = typeof body?.refund_id === "string" ? body.refund_id : null;
    if (!refundId) return json({ error: "refund_id required" }, 400);

    const row = await deps.loadRefund(refundId);
    if (!row) return json({ error: "not found" }, 404);
    if (row.status === "done" || row.status === "failed") return json({ status: "duplicate" });

    try {
      if (row.status === "processing" && row.provider_refund_id) {
        const remote = await deps.mf.getRefund(row.provider_refund_id);
        const status = refundStatusFor(remote.status);
        const r = await deps.settle({
          p_refund_id: row.id, p_status: status, p_provider_refund_id: row.provider_refund_id,
          p_failure_message: status === "failed" ? "Canceled by MyFatoorah" : null,
        });
        return json({ status: r.status });
      }

      await deps.markProcessing(row.id);
      const remote = await deps.mf.createRefund({
        paymentId: row.provider_payment_id,
        amountHalalas: row.amount,
        externalIdentifier: row.id,
        // attempts only moves when a balance refusal schedules a retry, so a
        // resend after no answer reuses the key and cannot refund twice.
        idempotencyKey: `refund:${row.id}:${row.attempts}`,
      });
      const status = refundStatusFor(remote.status);
      const r = await deps.settle({
        p_refund_id: row.id, p_status: status, p_provider_refund_id: remote.refundId || null,
        p_failure_message: status === "failed" ? "Canceled by MyFatoorah" : null,
      });
      return json({ status: r.status });
    } catch (error) {
      if (error instanceof MyFatoorahError && error.definitive) {
        // MyFatoorah answered no. Not enough balance yet is a "try tomorrow";
        // anything else is final and alerts ops through settle_refund.
        console.error("refund-payment refused:", error.status, error.body.slice(0, 300));
        const r = await deps.settle({
          p_refund_id: row.id,
          p_status: error.isBalanceRefusal ? "waiting_balance" : "failed",
          p_provider_refund_id: null,
          p_failure_message: error.body.slice(0, 500),
        });
        return json({ status: r.status });
      }
      // No clear answer (network, 5xx, gateway page). The refund may exist, so
      // the row stays where it is; the sweep resends with the same key while
      // MyFatoorah still remembers it, and gives up after three hours.
      console.error("refund-payment got no answer:", error);
      return json({ status: "retry" });
    }
  };
}
