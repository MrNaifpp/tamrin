// Moyasar tells us something changed. We do not believe what it says changed:
// the body's secret_token gets us past the door, the webhook id gets recorded
// (a replay hits the primary key), and then the payment is fetched again with
// the secret key. Whatever Moyasar answers is what settle_payment receives.
import { json } from "../_shared/cors.ts";
import type { makeMoyasarClient } from "../_shared/moyasar.ts";

export type SettleArgs = {
  p_payment_id: string; p_moyasar_payment_id: string; p_moyasar_status: string;
  p_payment_method: string | null; p_amount: number; p_currency: string;
};

export type WebhookDeps = {
  webhookSecret: string;
  recordEvent(e: { id: string; type: string; raw: unknown }): Promise<"new" | "duplicate">;
  findPaymentByMetadata(paymentId: string): Promise<{ id: string; amount: number; currency: string } | null>;
  moyasar: ReturnType<typeof makeMoyasarClient>;
  settle(args: SettleArgs): Promise<{ status: string }>;
  linkEvent(webhookId: string, paymentId: string): Promise<void>;
};

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function makeHandler(deps: WebhookDeps) {
  return async (req: Request): Promise<Response> => {
    const body = await req.json().catch(() => null);
    if (!body || typeof body !== "object") return json({ error: "bad body" }, 400);

    const token = typeof body.secret_token === "string" ? body.secret_token : "";
    if (!constantTimeEqual(token, deps.webhookSecret)) return json({ error: "unauthorized" }, 401);

    const id = typeof body.id === "string" ? body.id : null;
    const type = typeof body.type === "string" ? body.type : "unknown";
    if (!id) return json({ error: "missing id" }, 400);

    if ((await deps.recordEvent({ id, type, raw: body })) === "duplicate") {
      return json({ status: "duplicate" });
    }

    const moyasarId = typeof body.data?.id === "string" ? body.data.id : null;
    if (!moyasarId) return json({ status: "ignored", reason: "no payment id" });

    // Re-fetch: this is the only status we act on.
    const remote = await deps.moyasar.fetchPayment(moyasarId);
    const paymentId = typeof remote.metadata?.payment_id === "string" ? remote.metadata.payment_id : null;
    const row = paymentId ? await deps.findPaymentByMetadata(paymentId) : null;
    if (!row) return json({ status: "ignored", reason: "unknown payment" });

    await deps.linkEvent(id, row.id);
    const result = await deps.settle({
      p_payment_id: row.id, p_moyasar_payment_id: remote.id, p_moyasar_status: remote.status,
      p_payment_method: remote.source?.type ?? null, p_amount: remote.amount, p_currency: remote.currency,
    });
    return json({ status: result.status });
  };
}
