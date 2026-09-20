import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { makeHandler } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(makeHandler({
  publishableKey: Deno.env.get("MOYASAR_PUBLISHABLE_KEY")!,
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
