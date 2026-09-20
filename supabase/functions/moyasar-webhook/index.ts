import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeMoyasarClient } from "../_shared/moyasar.ts";
import { makeHandler } from "./handler.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(makeHandler({
  webhookSecret: Deno.env.get("MOYASAR_WEBHOOK_SECRET")!,
  moyasar: makeMoyasarClient(Deno.env.get("MOYASAR_SECRET_KEY")!),
  async recordEvent(e) {
    const { error } = await admin.from("moyasar_webhook_events").insert({ id: e.id, type: e.type, raw: e.raw });
    if (!error) return "new";
    if (error.code === "23505") return "duplicate";
    throw error;
  },
  async findPaymentByMetadata(paymentId) {
    const { data } = await admin.from("payments").select("id, amount, currency").eq("id", paymentId).maybeSingle();
    return (data as { id: string; amount: number; currency: string } | null) ?? null;
  },
  async linkEvent(webhookId, paymentId) {
    await admin.from("moyasar_webhook_events").update({ payment_id: paymentId }).eq("id", webhookId);
  },
  async settle(args) {
    const { data, error } = await admin.rpc("settle_payment", args);
    if (error) throw error;
    return data as { status: string };
  },
}));
