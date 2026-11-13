import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeMyFatoorahClient } from "../_shared/myfatoorah.ts";
import { makeHandler, type OwnPayment } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(makeHandler({
  now: () => new Date(),
  mf: makeMyFatoorahClient(
    Deno.env.get("MYFATOORAH_API_KEY") ?? "",
    Deno.env.get("MYFATOORAH_BASE_URL") ?? "https://api-sa.myfatoorah.com",
  ),
  async getUserId(auth) {
    if (!auth) return null;
    const asUser = createClient(url, anon, { global: { headers: { Authorization: auth } } });
    const { data } = await asUser.auth.getUser();
    return data.user?.id ?? null;
  },
  async loadPayment(id) {
    const { data } = await admin.from("payments")
      .select("id, user_id, status, provider, provider_payment_id, current_attempt, amount, currency, updated_at")
      .eq("id", id).maybeSingle();
    return (data as OwnPayment | null) ?? null;
  },
  async settle(args) {
    const { data, error } = await admin.rpc("settle_payment", args);
    if (error) throw error;
    return data as { status: string };
  },
}));
