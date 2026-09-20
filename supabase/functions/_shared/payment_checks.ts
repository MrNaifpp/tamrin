// The gate between "the device says it paid" and "the seat is confirmed".
// Pure so it can be tested without a network.
import type { MoyasarPayment } from "./moyasar.ts";

export type Expected = { amount: number; currency: string; recipientId: string | null };
export type CheckResult = { ok: true } | { ok: false; reason: "amount" | "currency" | "recipient" | "status" };

const ACCEPTABLE = new Set(["authorized", "paid", "captured"]);

export function checkAuthorized(p: MoyasarPayment, e: Expected): CheckResult {
  if (!ACCEPTABLE.has(p.status)) return { ok: false, reason: "status" };
  if (p.amount !== e.amount) return { ok: false, reason: "amount" };
  if (p.currency !== e.currency) return { ok: false, reason: "currency" };
  if (e.recipientId !== null) {
    const splits = p.splits ?? [];
    const toRecipient = splits
      .filter((s) => s.recipient_id === e.recipientId)
      .reduce((sum, s) => sum + s.amount, 0);
    const toOthers = splits
      .filter((s) => s.recipient_id !== e.recipientId)
      .reduce((sum, s) => sum + s.amount, 0);
    if (toRecipient !== e.amount || toOthers !== 0) return { ok: false, reason: "recipient" };
  }
  return { ok: true };
}
