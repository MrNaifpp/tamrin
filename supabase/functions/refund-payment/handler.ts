// Sends money back. Called server to server by the refunds trigger, so the gate
// is a shared secret rather than a user's JWT — the same arrangement send-push
// uses, for the same reason: Postgres cannot present a Supabase JWT.
//
// The amount is read from the refunds row. The request body carries an id and
// nothing else that matters, exactly as create-payment carries no price.
import { json } from "../_shared/cors.ts";
import type { makeMoyasarClient } from "../_shared/moyasar.ts";

export type RefundRow = {
  id: string;
  moyasar_payment_id: string;
  amount: number;
  status: string;
};

export type RefundDeps = {
  sharedSecret: string;
  loadRefund(id: string): Promise<RefundRow | null>;
  markProcessing(id: string): Promise<void>;
  moyasar: ReturnType<typeof makeMoyasarClient>;
  settle(args: {
    p_refund_id: string;
    p_status: string;
    p_refunded_total: number;
    p_failure_message: string | null;
  }): Promise<{ status: string }>;
};

export function makeHandler(deps: RefundDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.headers.get("authorization") !== `Bearer ${deps.sharedSecret}`) {
      return json({ error: "unauthorized" }, 401);
    }

    const body = await req.json().catch(() => ({}));
    const refundId = typeof body?.refund_id === "string" ? body.refund_id : null;
    if (!refundId) return json({ error: "refund_id required" }, 400);

    const row = await deps.loadRefund(refundId);
    if (!row) return json({ error: "not found" }, 404);

    // The trigger and the retry sweep can both reach the same row. Whichever
    // arrives second finds it already moving and leaves it alone.
    if (row.status !== "pending") return json({ status: "duplicate" });

    await deps.markProcessing(row.id);

    try {
      await deps.moyasar.refund(row.moyasar_payment_id, row.amount);
      // Re-read so the cumulative total is Moyasar's figure, not our sum.
      const payment = await deps.moyasar.fetchPayment(row.moyasar_payment_id);
      const result = await deps.settle({
        p_refund_id: row.id,
        p_status: "refunded",
        p_refunded_total: payment.refunded ?? row.amount,
        p_failure_message: null,
      });
      return json({ status: result.status });
    } catch (error) {
      // A refusal is an outcome, not a crash. Record it and acknowledge, so the
      // retry sweep does not hammer a refund Moyasar will never accept.
      console.error("refund-payment failed:", error);
      await deps.settle({
        p_refund_id: row.id,
        p_status: "failed",
        p_refunded_total: 0,
        p_failure_message: String(error).slice(0, 500),
      });
      return json({ status: "failed" });
    }
  };
}
