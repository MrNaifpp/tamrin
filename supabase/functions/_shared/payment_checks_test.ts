import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { checkAuthorized } from "./payment_checks.ts";

const base = { id: "p1", status: "authorized", amount: 6000, currency: "SAR",
  splits: [{ recipient_id: "rcp_1", amount: 6000 }] };
const expected = { amount: 6000, currency: "SAR", recipientId: "rcp_1" };

Deno.test("matching authorized payment passes", () => {
  assertEquals(checkAuthorized(base, expected), { ok: true });
});
Deno.test("tampered amount is caught", () => {
  assertEquals(checkAuthorized({ ...base, amount: 100 }, expected), { ok: false, reason: "amount" });
});
Deno.test("wrong currency is caught", () => {
  assertEquals(checkAuthorized({ ...base, currency: "USD" }, expected), { ok: false, reason: "currency" });
});
Deno.test("redirected split recipient is caught", () => {
  assertEquals(
    checkAuthorized({ ...base, splits: [{ recipient_id: "rcp_evil", amount: 6000 }] }, expected),
    { ok: false, reason: "recipient" },
  );
});
Deno.test("no splits when a recipient is expected is caught", () => {
  assertEquals(checkAuthorized({ ...base, splits: null }, expected), { ok: false, reason: "recipient" });
});
Deno.test("already paid is accepted as well as authorized", () => {
  assertEquals(checkAuthorized({ ...base, status: "paid" }, expected), { ok: true });
});
Deno.test("failed status is not accepted", () => {
  assertEquals(checkAuthorized({ ...base, status: "failed" }, expected), { ok: false, reason: "status" });
});
