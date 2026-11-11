import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler, type RefundDeps, type RefundRow } from "./handler.ts";
import { type MfRefund, MyFatoorahError } from "../_shared/myfatoorah.ts";

type CreateArgs = Parameters<RefundDeps["mf"]["createRefund"]>[0];

function deps(opts: {
  row?: Partial<RefundRow>;
  create?: (a: CreateArgs) => Promise<MfRefund>;
  get?: (id: string) => Promise<MfRefund>;
} = {}) {
  const log: string[] = [];
  const creates: CreateArgs[] = [];
  const settles: Array<Parameters<RefundDeps["settle"]>[0]> = [];
  const row: RefundRow = {
    id: "ref-1", provider_payment_id: "0707-1", provider_refund_id: null,
    amount: 3000, status: "pending", attempts: 0, ...(opts.row ?? {}),
  };
  const d: RefundDeps = {
    sharedSecret: "s",
    loadRefund: async (id) => (id === row.id ? row : null),
    markProcessing: async () => { log.push("processing"); },
    mf: {
      createRefund: async (a) => {
        creates.push(a);
        log.push("create");
        return opts.create ? opts.create(a) : { refundId: "R1", status: "pending", amountHalalas: a.amountHalalas };
      },
      getRefund: async (id) => {
        log.push(`get:${id}`);
        return opts.get ? opts.get(id) : { refundId: id, status: "refunded", amountHalalas: 3000 };
      },
    },
    settle: async (a) => { settles.push(a); log.push(`settle:${a.p_status}`); return { status: "ok" }; },
  };
  return { d, log, creates, settles };
}

const post = (body: unknown, auth = "Bearer s") =>
  new Request("http://x/refund-payment", {
    method: "POST", headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("rejects a wrong shared secret", async () => {
  const { d, log } = deps();
  assertEquals((await makeHandler(d)(post({ refund_id: "ref-1" }, "Bearer nope"))).status, 401);
  assertEquals(log, []);
});

Deno.test("pending row → createRefund with idempotency key refund:<id>:<attempts>", async () => {
  const { d, creates, settles, log } = deps();
  await makeHandler(d)(post({ refund_id: "ref-1" }));
  assertEquals(creates, [{
    paymentId: "0707-1", amountHalalas: 3000, externalIdentifier: "ref-1", idempotencyKey: "refund:ref-1:0",
  }]);
  assertEquals(log[0], "processing");
  assertEquals(settles, [{ p_refund_id: "ref-1", p_status: "pending", p_provider_refund_id: "R1", p_failure_message: null }]);
});

Deno.test("Refunded right away settles refunded", async () => {
  const { d, settles } = deps({ create: async () => ({ refundId: "R1", status: "refunded", amountHalalas: 3000 }) });
  await makeHandler(d)(post({ refund_id: "ref-1" }));
  assertEquals(settles[0].p_status, "refunded");
});

Deno.test("balance refusal → waiting_balance", async () => {
  const { d, settles } = deps({
    create: async () => { throw new MyFatoorahError(400, '{"Message":"Insufficient available balance"}'); },
  });
  await makeHandler(d)(post({ refund_id: "ref-1" }));
  assertEquals(settles[0].p_status, "waiting_balance");
  assertEquals(settles[0].p_failure_message?.includes("balance"), true);
});

Deno.test("other MyFatoorahError → failed with message", async () => {
  const { d, settles } = deps({ create: async () => { throw new MyFatoorahError(400, "Payment not found"); } });
  await makeHandler(d)(post({ refund_id: "ref-1" }));
  assertEquals(settles[0].p_status, "failed");
  assertEquals(settles[0].p_failure_message?.includes("Payment not found"), true);
});

Deno.test("processing row with provider_refund_id → getRefund, never createRefund", async () => {
  const { d, creates, settles, log } = deps({ row: { status: "processing", provider_refund_id: "R9" } });
  await makeHandler(d)(post({ refund_id: "ref-1" }));
  assertEquals(creates.length, 0);
  assertEquals(log[0], "get:R9");
  assertEquals(settles[0], { p_refund_id: "ref-1", p_status: "refunded", p_provider_refund_id: "R9", p_failure_message: null });
});

Deno.test("canceled by MyFatoorah on a status check → failed", async () => {
  const { d, settles } = deps({
    row: { status: "processing", provider_refund_id: "R9" },
    get: async () => ({ refundId: "R9", status: "canceled", amountHalalas: 3000 }),
  });
  await makeHandler(d)(post({ refund_id: "ref-1" }));
  assertEquals(settles[0].p_status, "failed");
});

Deno.test("processing row without a provider id resends with the same key", async () => {
  const { d, creates } = deps({ row: { status: "processing", attempts: 0 } });
  await makeHandler(d)(post({ refund_id: "ref-1" }));
  assertEquals(creates[0].idempotencyKey, "refund:ref-1:0");
});

Deno.test("waiting_balance row → createRefund again with the incremented attempts key", async () => {
  const { d, creates } = deps({ row: { status: "waiting_balance", attempts: 2 } });
  await makeHandler(d)(post({ refund_id: "ref-1" }));
  assertEquals(creates[0].idempotencyKey, "refund:ref-1:2");
});

Deno.test("done/failed row → duplicate, no calls", async () => {
  for (const status of ["done", "failed"]) {
    const { d, log } = deps({ row: { status } });
    const res = await makeHandler(d)(post({ refund_id: "ref-1" }));
    assertEquals(await res.json(), { status: "duplicate" });
    assertEquals(log, []);
  }
});

Deno.test("network error (not MyFatoorahError) → row left as is, 200", async () => {
  const { d, settles } = deps({ create: async () => { throw new TypeError("network down"); } });
  const res = await makeHandler(d)(post({ refund_id: "ref-1" }));
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { status: "retry" });
  assertEquals(settles.length, 0);
});
