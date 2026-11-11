import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeMyFatoorahClient } from "../_shared/myfatoorah.ts";
import { makeHandler, type StuckPayment } from "./handler.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(makeHandler({
  sharedSecret: Deno.env.get("PAYMENT_SWEEP_SECRET") ?? "",
  now: () => new Date(),
  mf: makeMyFatoorahClient(
    Deno.env.get("MYFATOORAH_API_KEY") ?? "",
    Deno.env.get("MYFATOORAH_BASE_URL") ?? "https://api-sa.myfatoorah.com",
  ),
  async loadStuck() {
    const cutoff = new Date(Date.now() - 3 * 60_000).toISOString();
    const { data, error } = await admin.from("payments")
      .select("id, provider_payment_id, amount, currency, updated_at")
      .eq("status", "processing")
      .eq("provider", "myfatoorah")
      .lt("updated_at", cutoff)
      .order("updated_at", { ascending: true })
      .limit(50);
    if (error) throw error;
    return (data ?? []) as StuckPayment[];
  },
  async settle(args) {
    const { data, error } = await admin.rpc("settle_payment", args);
    if (error) throw error;
    return data as { status: string };
  },
}));
