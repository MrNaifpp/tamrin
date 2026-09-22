import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler } from "./handler.ts";

const row = { id: "ref-1", moyasar_payment_id: "moy-1", amount: 12000, status: "pending" };
const refunded = { id: "moy-1", status: "refunded", amount: 24000, currency: "SAR", refunded: 12000 };

function deps(over: Record<string, unknown> = {}) {
  const log: string[] = [];
  const settled: Array<Record<string, unknown>> = [];
  return {
    log,
    settled,
    sharedSecret: "refsec",
    loadRefund: async (id: string) => (id === "ref-1" ? { ...row } : null),
    markProcessing: async () => { log.push("processing"); },
    moyasar: {
      fetchPayment: async () => { log.push("fetch"); return refunded; },
      capture: async () => refunded,
      voidPayment: async () => refunded,
      refund: async (_id: string, amount?: number) => {
        log.push(`refund:${amount}`);
        return refunded;
      },
    },
    settle: async (args: Record<string, unknown>) => {
      settled.push(args);
      return { status: args.p_status === "refunded" ? "settled" : "failed" };
    },
    ...over,
  };
}

const post = (body: unknown, auth = "Bearer refsec") =>
  new Request("http://x/refund-payment", {
    method: "POST",
    headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("a wrong shared secret is refused and nothing is called", async () => {
  const d = deps();
  const res = await makeHandler(d)(post({ refund_id: "ref-1" }, "Bearer nope"));
  assertEquals(res.status, 401);
  assertEquals(d.log, []);
});

Deno.test("the amount comes from the row, never from the request", async () => {
  const d = deps();
  const res = await makeHandler(d)(post({ refund_id: "ref-1", amount: 999999 }));
  assertEquals(res.status, 200);
  assertEquals(d.log, ["processing", "refund:12000", "fetch"]);
  assertEquals(d.settled[0].p_refunded_total, 12000);
  assertEquals(d.settled[0].p_status, "refunded");
});

Deno.test("a row that is no longer pending is a duplicate delivery", async () => {
  const d = deps({ loadRefund: async () => ({ ...row, status: "done" }) });
  const res = await makeHandler(d)(post({ refund_id: "ref-1" }));
  assertEquals((await res.json()).status, "duplicate");
  assertEquals(d.log, []);
});

Deno.test("a Moyasar refusal is recorded against the row, not thrown away", async () => {
  const d = deps();
  d.moyasar.refund = async () => { throw new Error("Moyasar 400: already refunded"); };
  const res = await makeHandler(d)(post({ refund_id: "ref-1" }));
  assertEquals(res.status, 200);
  assertEquals(d.settled[0].p_status, "failed");
  assertEquals(String(d.settled[0].p_failure_message).includes("already refunded"), true);
});

Deno.test("an unknown refund id is 404", async () => {
  const res = await makeHandler(deps())(post({ refund_id: "nope" }));
  assertEquals(res.status, 404);
});

Deno.test("a missing refund id is 400", async () => {
  const res = await makeHandler(deps())(post({}));
  assertEquals(res.status, 400);
});
