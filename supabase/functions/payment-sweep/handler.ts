// Finishes payments left halfway. pay-apple-pay marks a row `processing` before
// it calls MyFatoorah, so a crash, a timeout or a closed app leaves a row this
// sweep can find. It asks MyFatoorah what really happened and settles that.
// Called every few minutes by pg_cron through pg_net, with a shared secret.
import { json } from "../_shared/cors.ts";
import type { MfPayment } from "../_shared/myfatoorah.ts";
import type { SettleArgs } from "../pay-apple-pay/handler.ts";

export type StuckPayment = {
  id: string;
  provider_payment_id: string | null;
  amount: number;
  currency: string;
  updated_at: string;
};

export type SweepDeps = {
  sharedSecret: string;
  now(): Date;
  loadStuck(): Promise<StuckPayment[]>;
  mf: {
    getPayment(paymentId: string): Promise<MfPayment>;
    findPaymentByExternalIdentifier(externalIdentifier: string): Promise<MfPayment | null>;
  };
  settle(args: SettleArgs): Promise<{ status: string }>;
};

/// With no MyFatoorah payment after this long, the charge never happened.
const GIVE_UP_MS = 30 * 60_000;

export function makeHandler(deps: SweepDeps) {
  return async (req: Request): Promise<Response> => {
    if (!deps.sharedSecret || req.headers.get("authorization") !== `Bearer ${deps.sharedSecret}`) {
      return json({ error: "unauthorized" }, 401);
    }

    const rows = await deps.loadStuck();
    let settled = 0;
    for (const row of rows) {
      try {
        const remote = row.provider_payment_id
          ? await deps.mf.getPayment(row.provider_payment_id)
          : await deps.mf.findPaymentByExternalIdentifier(row.id);

        if (!remote) {
          const age = deps.now().getTime() - new Date(row.updated_at).getTime();
          if (age < GIVE_UP_MS) continue;
          await deps.settle({
            p_payment_id: row.id, p_provider_payment_id: null, p_outcome: "failed",
            p_payment_method: "applepay", p_amount: row.amount, p_currency: row.currency,
          });
          settled++;
          continue;
        }
        if (remote.outcome === "processing") continue;

        await deps.settle({
          p_payment_id: row.id,
          p_provider_payment_id: remote.paymentId || row.provider_payment_id,
          p_outcome: remote.outcome,
          p_payment_method: "applepay",
          p_amount: remote.amountHalalas,
          p_currency: remote.currency,
        });
        settled++;
      } catch (error) {
        console.error(`payment-sweep: ${row.id} not settled this round`, error);
      }
    }
    return json({ checked: rows.length, settled });
  };
}
