// Prices the caller's owed seats and hands the app what Apple Pay's sheet needs.
// The body carries an event id and nothing else that matters: the price, the
// seat count and which seats are covered all come from the database.
import { corsHeaders, json } from "../_shared/cors.ts";

export type CreateDeps = {
  getUserId(authHeader: string | null): Promise<string | null>;
  rpc(
    name: "begin_card_payment",
    args: { p_event_id: string; p_user_id: string },
  ): Promise<Record<string, unknown>>;
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

    return json({
      status: "ready",
      payment_id: r.payment_id,
      amount: r.amount,
      currency: r.currency,
      seat_count: r.seat_count,
      event_name: r.event_name,
    });
  };
}
