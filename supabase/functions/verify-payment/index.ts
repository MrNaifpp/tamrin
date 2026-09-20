import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeMoyasarClient } from "../_shared/moyasar.ts";
import { makeHandler, type PaymentRow } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(makeHandler({
  moyasar: makeMoyasarClient(Deno.env.get("MOYASAR_SECRET_KEY")!),
  async getUserId(auth) {
    if (!auth) return null;
    const asUser = createClient(url, anon, { global: { headers: { Authorization: auth } } });
    const { data } = await asUser.auth.getUser();
    return data.user?.id ?? null;
  },
  async loadPayment(id) {
    const { data } = await admin.from("payments")
      .select("id, user_id, amount, currency, split_recipient_id, status").eq("id", id).maybeSingle();
    return (data as PaymentRow | null) ?? null;
  },
  async settle(args) {
    const { data, error } = await admin.rpc("settle_payment", args);
    if (error) throw error;
    return data as { status: string };
  },
}));
