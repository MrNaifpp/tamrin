import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler } from "./handler.ts";

const ready = {
  status: "ready", payment_id: "pay-uuid", amount: 12000,
  currency: "SAR", seat_count: 2, event_name: "تمرين",
};

function deps(over: Partial<Parameters<typeof makeHandler>[0]> = {}) {
  const calls: unknown[] = [];
  return {
    calls,
    getUserId: async (auth: string | null) => (auth === "Bearer good" ? "user-1" : null),
    rpc: async (_name: string, args: unknown) => { calls.push(args); return ready; },
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
  assertEquals(d.calls, [{ p_event_id: "e1", p_user_id: "user-1" }]);
  assertEquals(body.amount, 12000);
});

Deno.test("the ready quote carries only what Apple Pay needs", async () => {
  const res = await makeHandler(deps())(post({ event_id: "e1" }));
  assertEquals(await res.json(), {
    status: "ready", payment_id: "pay-uuid", amount: 12000,
    currency: "SAR", seat_count: 2, event_name: "تمرين",
  });
});

Deno.test("passes a non-ready status through", async () => {
  for (const status of ["free_event", "nothing_due", "already_paid", "event_closed", "processing"]) {
    const d = deps({ rpc: async () => ({ status }) });
    const res = await makeHandler(d)(post({ event_id: "e1" }));
    assertEquals(await res.json(), { status });
  }
});
