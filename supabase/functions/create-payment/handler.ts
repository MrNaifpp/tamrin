// Prices the caller's seats and hands the app what the Moyasar SDK needs.
// The body carries an event id and nothing else that matters: the price, the
// seat count, the recipient and the idempotency key all come from the database.
import { corsHeaders, json } from "../_shared/cors.ts";

export type CreateDeps = {
  getUserId(authHeader: string | null): Promise<string | null>;
  rpc(name: "begin_card_payment", args: { p_event_id: string; p_user_id: string }): Promise<Record<string, unknown>>;
  publishableKey: string;
};

export function makeHandler(deps: CreateDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

    const userId = await deps.getUserId(req.headers.get("authorization"));
    if (!userId) return json({ error: "unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));
    const eventId = typeof body?.event_id === "string" ? body.event_id : null;
    if (!eventId) return json({ error: "event_id required" }, 400);

    const r = await deps.rpc("begin_card_payment", { p_event_id: eventId, p_user_id: userId });
    if (r.status !== "ready") return json({ status: r.status });

    const amount = r.amount as number;
    return json({
      status: "ready",
      payment_id: r.payment_id,
      given_id: r.given_id,
      amount,
      currency: r.currency,
      seat_count: r.seat_count,
      publishable_key: deps.publishableKey,
      description: `تمرين: ${r.event_name}`,
      metadata: { payment_id: r.payment_id, event_id: eventId, user_id: userId },
      splits: [{
        recipient_id: r.recipient_id,
        recipient_type: r.recipient_type,
        amount,
        fee_source: true,
        refundable: true,
      }],
    });
  };
}
