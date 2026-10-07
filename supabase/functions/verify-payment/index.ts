import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeMoyasarClient } from "../_shared/moyasar.ts";
import { makeHandler, type PaymentRow } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const secretKey = Deno.env.get("MOYASAR_SECRET_KEY") ?? "";

// Config fingerprint, once per cold start. A wrong key and a MISSING key are
// indistinguishable from outside: Moyasar answers 401 authentication_error to
// both, and a missing one makes the client send the literal text "undefined"
// as the username. This says which value the function actually received
// without revealing it — compare `sha256` against the DIGEST column of
// `supabase secrets list`, which is a plain SHA256 of the stored value.
// Sixteen hex characters of a hash is not reversible and is not a credential.
{
  const bytes = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secretKey)),
  );
  console.log("verify-payment: MOYASAR_SECRET_KEY", {
    length: secretKey.length,
    sha256: Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 16),
  });
}

Deno.serve(makeHandler({
  moyasar: makeMoyasarClient(secretKey),
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
