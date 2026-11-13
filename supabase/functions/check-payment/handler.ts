// The app asks "is my payment done?" right after MyFatoorah's page closes,
// instead of waiting for the payment sweep's next round. It does exactly what
// the sweep does for one payment (checkOne), for the caller's own payment only.
// The sweep and the webhook still settle anything this misses.
import { corsHeaders, json } from "../_shared/cors.ts";
import { checkOne, type CheckDeps, type StuckPayment } from "../payment-sweep/handler.ts";

export type OwnPayment = StuckPayment & {
  user_id: string;
  status: string;
  provider: string;
};

export type CheckPaymentDeps = CheckDeps & {
  getUserId(auth: string | null): Promise<string | null>;
  loadPayment(id: string): Promise<OwnPayment | null>;
};

export function makeHandler(deps: CheckPaymentDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

    const userId = await deps.getUserId(req.headers.get("authorization"));
    if (!userId) return json({ error: "unauthorized" }, 401);

    const body = await req.json().catch(() => ({}));
    const paymentId = typeof body?.payment_id === "string" ? body.payment_id : null;
    if (!paymentId) return json({ error: "payment_id required" }, 400);

    const row = await deps.loadPayment(paymentId);
    if (!row || row.user_id !== userId) return json({ error: "not found" }, 404);
    if (row.status === "paid") return json({ status: "paid" });
    if (row.status !== "processing") return json({ status: "failed" });
    if (row.provider !== "myfatoorah") return json({ status: "processing" });

    try {
      return json({ status: await checkOne(row, deps) });
    } catch (error) {
      console.error(`check-payment: ${row.id} not settled now`, error);
      return json({ status: "processing" });
    }
  };
}
