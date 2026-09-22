import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeMoyasarClient } from "../_shared/moyasar.ts";
import { makeHandler, type RefundRow } from "./handler.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(makeHandler({
  sharedSecret: Deno.env.get("REFUND_PAYMENT_SECRET")!,
  moyasar: makeMoyasarClient(Deno.env.get("MOYASAR_SECRET_KEY")!),
  async loadRefund(id) {
    const { data } = await admin.from("refunds")
      .select("id, moyasar_payment_id, amount, status").eq("id", id).maybeSingle();
    return (data as RefundRow | null) ?? null;
  },
  async markProcessing(id) {
    await admin.from("refunds").update({ status: "processing" }).eq("id", id);
  },
  async settle(args) {
    const { data, error } = await admin.rpc("settle_refund", args);
    if (error) throw error;
    return data as { status: string };
  },
}));
