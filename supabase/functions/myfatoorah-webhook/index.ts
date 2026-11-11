import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeMyFatoorahClient } from "../_shared/myfatoorah.ts";
import { makeHandler } from "./handler.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(makeHandler({
  secret: Deno.env.get("MYFATOORAH_WEBHOOK_SECRET") ?? "",
  mf: makeMyFatoorahClient(
    Deno.env.get("MYFATOORAH_API_KEY") ?? "",
    Deno.env.get("MYFATOORAH_BASE_URL") ?? "https://api-sa.myfatoorah.com",
  ),
  async recordEvent(e) {
    const { error } = await admin.from("payment_webhook_events")
      .insert({ id: e.reference, type: e.name, raw: e.raw });
    if (!error) return "new";
    if (error.code === "23505") return "duplicate";
    throw error;
  },
  async linkEvent(reference, paymentId) {
    await admin.from("payment_webhook_events").update({ payment_id: paymentId }).eq("id", reference);
  },
  async findPaymentById(id) {
    const { data } = await admin.from("payments").select("id").eq("id", id).maybeSingle();
    return (data as { id: string } | null) ?? null;
  },
  async findRefundById(id) {
    const { data } = await admin.from("refunds").select("id").eq("id", id).maybeSingle();
    return (data as { id: string } | null) ?? null;
  },
  async settlePayment(args) {
    const { data, error } = await admin.rpc("settle_payment", args);
    if (error) throw error;
    return data as { status: string };
  },
  async settleRefund(args) {
    const { data, error } = await admin.rpc("settle_refund", args);
    if (error) throw error;
    return data as { status: string };
  },
}));
