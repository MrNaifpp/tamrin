import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeHandler } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(makeHandler({
  publishableKey: Deno.env.get("MOYASAR_PUBLISHABLE_KEY")!,
  // Opt-in, and only where it is set. `supabase secrets set
  // ALLOW_PAYMENTS_WITHOUT_RECIPIENT=true` on the sandbox project lets card and
  // Apple Pay be tested before Moyasar issues a recipient id. Never set it on
  // production: without a split the organizer receives nothing and Tamrin
  // becomes the merchant of record, which is still an open question with
  // Moyasar (docs/moyasar-support-questions.md, Q8).
  allowWithoutRecipient: Deno.env.get("ALLOW_PAYMENTS_WITHOUT_RECIPIENT") === "true",
  async getUserId(auth) {
    if (!auth) return null;
    const asUser = createClient(url, anon, { global: { headers: { Authorization: auth } } });
    const { data } = await asUser.auth.getUser();
    return data.user?.id ?? null;
  },
  async rpc(name, args) {
    const { data, error } = await admin.rpc(name, args);
    if (error) throw error;
    return data as Record<string, unknown>;
  },
}));
