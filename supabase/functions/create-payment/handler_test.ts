import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler } from "./handler.ts";

const ready = {
  status: "ready", payment_id: "pay-uuid", given_id: "given-uuid", amount: 12000,
  currency: "SAR", seat_count: 2, recipient_id: "rcp_1", recipient_type: "Beneficiary",
  platform_fee: 0, event_name: "تمرين",
};

function deps(over: Partial<Parameters<typeof makeHandler>[0]> = {}) {
  const calls: unknown[] = [];
  return {
    calls,
    getUserId: async (auth: string | null) => (auth === "Bearer good" ? "user-1" : null),
    rpc: async (_name: string, args: unknown) => { calls.push(args); return ready; },
    publishableKey: "pk_test_x",
    allowWithoutRecipient: false,
    ...over,
  };
}

const post = (body: unknown, auth = "Bearer good") =>
  new Request("http://x/create-payment", {
    method: "POST", headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("rejects a missing or bad JWT", async () => {
  const res = await makeHandler(deps())(post({ event_id: "e1" }, "Bearer bad"));
  assertEquals(res.status, 401);
});

Deno.test("requires event_id", async () => {
  const res = await makeHandler(deps())(post({}));
  assertEquals(res.status, 400);
});

Deno.test("ignores any amount the client sends and uses the caller from the JWT", async () => {
  const d = deps();
  const res = await makeHandler(d)(post({ event_id: "e1", amount: 1, user_id: "someone-else" }));
  const body = await res.json();
  assertEquals(d.calls, [{ p_event_id: "e1", p_user_id: "user-1", p_allow_without_recipient: false }]);
  assertEquals(body.amount, 12000);
});

Deno.test("returns the publishable key and a server-built splits array", async () => {
  const res = await makeHandler(deps())(post({ event_id: "e1" }));
  const body = await res.json();
  assertEquals(body.publishable_key, "pk_test_x");
  assertEquals(body.splits, [{ recipient_id: "rcp_1", recipient_type: "Beneficiary", amount: 12000, fee_source: true, refundable: true }]);
  assertEquals(body.metadata, { payment_id: "pay-uuid", event_id: "e1", user_id: "user-1" });
});

Deno.test("passes a non-ready status through without a key", async () => {
  const d = deps({ rpc: async () => ({ status: "recipient_not_onboarded" }) });
  const res = await makeHandler(d)(post({ event_id: "e1" }));
  const body = await res.json();
  assertEquals(body, { status: "recipient_not_onboarded" });
});

Deno.test("the recipient-less opt-in is the server's to set, never the body's", async () => {
  const d = deps({ allowWithoutRecipient: true });
  await makeHandler(d)(post({ event_id: "e1", allow_without_recipient: false }));
  assertEquals(d.calls, [{ p_event_id: "e1", p_user_id: "user-1", p_allow_without_recipient: true }]);
});

Deno.test("no recipient means no splits array at all", async () => {
  const d = deps({
    allowWithoutRecipient: true,
    rpc: async () => ({ ...ready, recipient_id: null, recipient_type: null }),
  });
  const res = await makeHandler(d)(post({ event_id: "e1" }));
  const body = await res.json();
  assertEquals(body.splits, []);
  assertEquals(body.amount, 12000);
});
