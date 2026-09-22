// The device authorized; only this function may turn that into money moving.
// Fetch with the secret key, compare to what the database says is owed,
// capture on a match, void on anything else. A tampered amount therefore
// costs nothing to anyone: the hold is released, no refund is ever needed.
import { corsHeaders, json } from "../_shared/cors.ts";
import type { makeMoyasarClient } from "../_shared/moyasar.ts";
import { checkAuthorized } from "../_shared/payment_checks.ts";

export type PaymentRow = {
  id: string; user_id: string; amount: number; currency: string;
  split_recipient_id: string | null; status: string;
};

export type VerifyDeps = {
  getUserId(auth: string | null): Promise<string | null>;
  loadPayment(id: string): Promise<PaymentRow | null>;
  moyasar: ReturnType<typeof makeMoyasarClient>;
  settle(args: {
    p_payment_id: string; p_moyasar_payment_id: string; p_moyasar_status: string;
    p_payment_method: string | null; p_amount: number; p_currency: string;
  }): Promise<{ status: string }>;
};

export function makeHandler(deps: VerifyDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

    // Everything below crosses a boundary that can throw: the auth check, the
    // database, and three Moyasar calls. An uncaught throw becomes a bare 500,
    // which the app can only render as "something went wrong" — that is how an
    // invalid MOYASAR_SECRET_KEY once looked exactly like a declined card, with
    // the real answer (401 authentication_error) visible nowhere. `at` names the
    // boundary being crossed, and both the log and the response carry it.
    let at = "auth";
    try {
      const userId = await deps.getUserId(req.headers.get("authorization"));
      if (!userId) return json({ error: "unauthorized" }, 401);

      const body = await req.json().catch(() => ({}));
      const paymentId = typeof body?.payment_id === "string" ? body.payment_id : null;
      const moyasarId = typeof body?.moyasar_payment_id === "string" ? body.moyasar_payment_id : null;
      if (!paymentId || !moyasarId) return json({ error: "payment_id and moyasar_payment_id required" }, 400);

      at = "load_payment";
      const row = await deps.loadPayment(paymentId);
      if (!row || row.user_id !== userId) return json({ error: "not found" }, 404);
      if (row.status === "paid") return json({ status: "paid" });

      at = "moyasar_fetch";
      const remote = await deps.moyasar.fetchPayment(moyasarId);
      const method = remote.source?.type ?? null;

      if (remote.status === "initiated") return json({ status: "processing" });

      const check = checkAuthorized(remote, {
        amount: row.amount, currency: row.currency, recipientId: row.split_recipient_id,
      });

      if (!check.ok) {
        if (remote.status === "authorized") {
          at = "moyasar_void";
          const voided = await deps.moyasar.voidPayment(moyasarId);
          at = "settle_void";
          await deps.settle({
            p_payment_id: row.id, p_moyasar_payment_id: moyasarId, p_moyasar_status: voided.status,
            p_payment_method: method, p_amount: remote.amount, p_currency: remote.currency,
          });
        } else {
          at = "settle_reject";
          await deps.settle({
            p_payment_id: row.id, p_moyasar_payment_id: moyasarId, p_moyasar_status: remote.status,
            p_payment_method: method, p_amount: remote.amount, p_currency: remote.currency,
          });
        }
        return json({ status: "failed", reason: check.reason });
      }

      let final = remote;
      if (remote.status === "authorized") {
        at = "moyasar_capture";
        final = await deps.moyasar.capture(moyasarId);
      }

      at = "settle";
      const settled = await deps.settle({
        p_payment_id: row.id, p_moyasar_payment_id: moyasarId, p_moyasar_status: final.status,
        p_payment_method: method, p_amount: final.amount, p_currency: final.currency,
      });

      if (settled.status === "settled" || settled.status === "already_settled") return json({ status: "paid" });
      return json({ status: "failed", reason: settled.status });
    } catch (error) {
      // The money may well have moved — this says only that we could not
      // confirm it. The seat stays unconfirmed and the webhook settles it once
      // whatever broke here is fixed.
      console.error(`verify-payment failed at ${at}:`, error);
      return json({
        status: "failed",
        reason: `server_error:${at}`,
        detail: String(error).slice(0, 500),
      }, 500);
    }
  };
}
