import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeMyFatoorahClient } from "../_shared/myfatoorah.ts";
import type { ClaimResult } from "../pay-apple-pay/handler.ts";
import { makeHandler, testCardsAllowed } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const baseUrl = Deno.env.get("MYFATOORAH_BASE_URL") ?? "https://api-sa.myfatoorah.com";

Deno.serve(makeHandler({
  // Never set ALLOW_TEST_CARD_PAYMENTS in production. Even if it were, the
  // base URL must be MyFatoorah's test server for this to run.
  enabled: testCardsAllowed(Deno.env.get("ALLOW_TEST_CARD_PAYMENTS"), baseUrl),
  redirectUrl: "https://tamrien.app/",
  newAttemptSuffix: () => crypto.randomUUID().replaceAll("-", "").slice(0, 8),
  mf: makeMyFatoorahClient(Deno.env.get("MYFATOORAH_API_KEY") ?? "", baseUrl),
  async getUserId(auth) {
    if (!auth) return null;
    const asUser = createClient(url, anon, { global: { headers: { Authorization: auth } } });
    const { data } = await asUser.auth.getUser();
    return data.user?.id ?? null;
  },
  async claim(paymentId, userId, attempt) {
    const { data, error } = await admin.rpc("claim_payment_attempt", {
      p_payment_id: paymentId, p_user_id: userId, p_attempt: attempt,
    });
    if (error) throw error;
    return data as ClaimResult;
  },
  async settle(args) {
    const { data, error } = await admin.rpc("settle_payment", args);
    if (error) throw error;
    return data as { status: string };
  },
}));
