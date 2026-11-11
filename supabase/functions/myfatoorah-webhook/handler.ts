// MyFatoorah tells us something changed. The signature gets it past the door,
// the event reference gets recorded (a replay stops there), and then the
// payment or refund is fetched again with our key. Whatever MyFatoorah answers
// to that GET is what gets settled; the body only says where to look.
import { json } from "../_shared/cors.ts";
import type { MfPayment, MfRefund } from "../_shared/myfatoorah.ts";
import {
  paymentSignatureFields,
  refundSignatureFields,
  type SignatureField,
  verifySignature,
} from "../_shared/myfatoorah_signature.ts";
import { paymentIdOf, type SettleArgs } from "../pay-apple-pay/handler.ts";

export type SettleRefundArgs = {
  p_refund_id: string;
  p_status: "refunded" | "pending" | "waiting_balance" | "failed";
  p_provider_refund_id: string | null;
  p_failure_message: string | null;
};

export type WebhookDeps = {
  secret: string;
  recordEvent(e: { reference: string; name: string; raw: unknown }): Promise<"new" | "duplicate">;
  linkEvent(reference: string, paymentId: string): Promise<void>;
  /// Undo recordEvent, so a retry of an event we failed to process is not
  /// mistaken for a replay.
  forgetEvent(reference: string): Promise<void>;
  findPaymentById(id: string): Promise<{ id: string } | null>;
  findRefundByProviderId(providerRefundId: string): Promise<{ id: string } | null>;
  mf: {
    getPayment(paymentId: string): Promise<MfPayment>;
    getRefund(refundId: string): Promise<MfRefund>;
  };
  settlePayment(args: SettleArgs): Promise<{ status: string }>;
  settleRefund(args: SettleRefundArgs): Promise<{ status: string }>;
};

// deno-lint-ignore no-explicit-any
type Json = any;

const PAYMENT_STATUS_CHANGED = 1;
const REFUND_STATUS_CHANGED = 2;

export function refundStatusFor(remote: MfRefund["status"]): SettleRefundArgs["p_status"] {
  if (remote === "refunded") return "refunded";
  if (remote === "canceled") return "failed";
  return "pending";
}

export function makeHandler(deps: WebhookDeps) {
  async function process(code: number, reference: string, data: Json): Promise<Response> {
    if (code === PAYMENT_STATUS_CHANGED) {
      // Our ExternalIdentifier is the attempt: "<payment id>:<attempt>".
      const attempt = data?.Invoice?.ExternalIdentifier;
      const row = typeof attempt === "string" && attempt
        ? await deps.findPaymentById(paymentIdOf(attempt))
        : null;
      const providerId = data?.Transaction?.PaymentId;
      if (!row || typeof providerId !== "string" || !providerId) {
        return json({ status: "ignored", reason: "unknown payment" });
      }
      const remote = await deps.mf.getPayment(providerId);
      if (remote.externalIdentifier !== attempt) {
        return json({ status: "ignored", reason: "payment belongs to another order" });
      }
      await deps.linkEvent(reference, row.id);
      const settled = await deps.settlePayment({
        p_payment_id: row.id,
        p_provider_payment_id: remote.paymentId,
        p_outcome: remote.outcome,
        p_payment_method: "applepay",
        p_amount: remote.amountHalalas,
        p_currency: remote.currency,
        p_attempt: attempt,
      });
      return json({ status: settled.status });
    }

    // The refund payload carries no identifier of ours; MyFatoorah's refund id
    // is stored on the row when the refund is created.
    const providerRefundId = data?.Refund?.Id != null ? String(data.Refund.Id) : null;
    const refund = providerRefundId ? await deps.findRefundByProviderId(providerRefundId) : null;
    if (!refund || !providerRefundId) return json({ status: "ignored", reason: "unknown refund" });

    const remote = await deps.mf.getRefund(providerRefundId);
    const status = refundStatusFor(remote.status);
    const settled = await deps.settleRefund({
      p_refund_id: refund.id,
      p_status: status,
      p_provider_refund_id: remote.refundId || providerRefundId,
      p_failure_message: status === "failed" ? "Canceled by MyFatoorah" : null,
    });
    return json({ status: settled.status });
  }

  return async (req: Request): Promise<Response> => {
    const body = await req.json().catch(() => null);
    if (!body || typeof body !== "object") return json({ error: "bad body" }, 400);

    const code = Number(body?.Event?.Code);
    const reference = typeof body?.Event?.Reference === "string" ? body.Event.Reference : null;
    const data = body?.Data ?? {};

    let fields: SignatureField[];
    if (code === PAYMENT_STATUS_CHANGED) fields = paymentSignatureFields(data);
    else if (code === REFUND_STATUS_CHANGED) fields = refundSignatureFields(data);
    // We only subscribe to these two; anything else gets an OK so it is not retried.
    else return json({ status: "ignored", reason: "event" });

    if (!(await verifySignature(deps.secret, fields, req.headers.get("myfatoorah-signature")))) {
      return json({ error: "unauthorized" }, 401);
    }
    if (!reference) return json({ error: "missing reference" }, 400);

    const name = typeof body?.Event?.Name === "string" ? body.Event.Name : String(code);
    if ((await deps.recordEvent({ reference, name, raw: body })) === "duplicate") {
      return json({ status: "duplicate" });
    }

    try {
      return await process(code, reference, data);
    } catch (error) {
      console.error(`myfatoorah-webhook: ${reference} failed, forgetting it for the retry`, error);
      await deps.forgetEvent(reference).catch(() => {});
      return json({ error: "failed" }, 500);
    }
  };
}
