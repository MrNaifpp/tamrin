// Prices the caller's seats and hands the app what the Moyasar SDK needs.
// The body carries an event id and nothing else that matters: the price, the
// seat count, the recipient and the idempotency key all come from the database.
import { corsHeaders, json } from "../_shared/cors.ts";

export type CreateDeps = {
  getUserId(authHeader: string | null): Promise<string | null>;
  rpc(
    name: "begin_card_payment",
    args: { p_event_id: string; p_user_id: string; p_allow_without_recipient: boolean },
  ): Promise<Record<string, unknown>>;
  publishableKey: string;
  /// Whether a workspace with no verified Moyasar recipient may still pay by
  /// card. Read from the environment, never from the request, so a client
  /// cannot ask for it. Set on the sandbox only; unset in production, where
  /// this stays false and the recipient gate is exactly as designed.
  allowWithoutRecipient: boolean;
};

export function makeHandler(deps: CreateDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

    const userId = await deps.getUserId(req.headers.get("authorization"));
    if (!userId) return json({ error: "unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));
    const eventId = typeof body?.event_id === "string" ? body.event_id : null;
    if (!eventId) return json({ error: "event_id required" }, 400);

    const r = await deps.rpc("begin_card_payment", {
      p_event_id: eventId,
      p_user_id: userId,
      p_allow_without_recipient: deps.allowWithoutRecipient,
    });
    if (r.status !== "ready") return json({ status: r.status });

    const amount = r.amount as number;
    // No recipient, no split: the payment settles into Tamrin's own Moyasar
    // account. verify-payment compares against the stored split_recipient_id,
    // which is null in that case, so it checks the amount and skips the split.
    const recipientId = typeof r.recipient_id === "string" ? r.recipient_id : null;
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
      splits: recipientId === null ? [] : [{
        recipient_id: recipientId,
        recipient_type: r.recipient_type,
        amount,
        fee_source: true,
        refundable: true,
      }],
    });
  };
}
