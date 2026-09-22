import { assertEquals, assertStringIncludes } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler } from "./handler.ts";

const row = { id: "pay-1", user_id: "user-1", amount: 6000, currency: "SAR", split_recipient_id: "rcp_1", status: "pending" };
const authorized = { id: "moy-1", status: "authorized", amount: 6000, currency: "SAR",
  source: { type: "creditcard" }, splits: [{ recipient_id: "rcp_1", amount: 6000 }] };

function deps(moyasarPayment = authorized) {
  const log: string[] = [];
  return {
    log,
    getUserId: async (a: string | null): Promise<string | null> => (a === "Bearer good" ? "user-1" : null),
    loadPayment: async (id: string) => (id === "pay-1" ? row : null),
    moyasar: {
      fetchPayment: async () => { log.push("fetch"); return moyasarPayment; },
      capture: async () => { log.push("capture"); return { ...moyasarPayment, status: "captured" }; },
      voidPayment: async () => { log.push("void"); return { ...moyasarPayment, status: "voided" }; },
      refund: async () => { log.push("refund"); return { ...moyasarPayment, status: "refunded" }; },
    },
    settle: async (args: { p_moyasar_status: string }) => {
      log.push(`settle:${args.p_moyasar_status}`);
      return { status: args.p_moyasar_status === "captured" ? "settled" : "failed" };
    },
  };
}

const post = (body: unknown, auth = "Bearer good") =>
  new Request("http://x/verify-payment", {
    method: "POST", headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("valid authorization is captured then settled", async () => {
  const d = deps();
  const res = await makeHandler(d)(post({ payment_id: "pay-1", moyasar_payment_id: "moy-1" }));
  assertEquals((await res.json()).status, "paid");
  assertEquals(d.log, ["fetch", "capture", "settle:captured"]);
});

Deno.test("tampered amount is voided, never captured", async () => {
  const d = deps({ ...authorized, amount: 100 });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", moyasar_payment_id: "moy-1" }));
  const body = await res.json();
  assertEquals(body, { status: "failed", reason: "amount" });
  assertEquals(d.log, ["fetch", "void", "settle:voided"]);
});

Deno.test("redirected recipient is voided", async () => {
  const d = deps({ ...authorized, splits: [{ recipient_id: "rcp_evil", amount: 6000 }] });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", moyasar_payment_id: "moy-1" }));
  assertEquals((await res.json()).reason, "recipient");
  assertEquals(d.log.includes("capture"), false);
});

Deno.test("a payment that is not the caller's is 404", async () => {
  const d = deps();
  d.getUserId = async () => "someone-else";
  const res = await makeHandler(d)(post({ payment_id: "pay-1", moyasar_payment_id: "moy-1" }));
  assertEquals(res.status, 404);
});

Deno.test("still initiated (3DS not finished) reports processing without capture", async () => {
  const d = deps({ ...authorized, status: "initiated" });
  const res = await makeHandler(d)(post({ payment_id: "pay-1", moyasar_payment_id: "moy-1" }));
  assertEquals((await res.json()).status, "processing");
  assertEquals(d.log, ["fetch"]);
});

Deno.test("a throwing boundary names itself instead of becoming an opaque 500", async () => {
  const d = deps();
  d.moyasar.fetchPayment = async () => { throw new Error("Moyasar 401: invalid secret key"); };
  const res = await makeHandler(d)(post({ payment_id: "pay-1", moyasar_payment_id: "moy-1" }));
  const body = await res.json();
  assertEquals(res.status, 500);
  assertEquals(body.reason, "server_error:moyasar_fetch");
  assertStringIncludes(body.detail, "invalid secret key");
});
