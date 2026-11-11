// MyFatoorah v3 REST client. Bearer auth with the account's API key; only ever
// runs inside an Edge Function, so the key never reaches the app.
//
// The database counts money in integer halalas and MyFatoorah in decimal
// riyals. This file is the only place that converts between the two.

export type PaymentOutcome = "paid" | "failed" | "processing";

export type MfPayment = {
  paymentId: string;
  invoiceId: string;
  externalIdentifier: string | null;
  outcome: PaymentOutcome;
  amountHalalas: number;
  currency: string;
  method: string | null;
  errorMessage: string | null;
};

export type MfRefund = {
  refundId: string;
  status: "refunded" | "pending" | "canceled";
  amountHalalas: number;
};

export class MyFatoorahError extends Error {
  /// MyFatoorah refuses a refund when the account's refundable balance is too
  /// low, which excludes money received the same day. That is a "try again
  /// later", not a "no", so the refund pipeline treats it apart.
  readonly isBalanceRefusal: boolean;
  constructor(public status: number, public body: string) {
    super(`MyFatoorah ${status}: ${body.slice(0, 300)}`);
    this.isBalanceRefusal = /balance/i.test(body);
  }
}

export function toRiyals(halalas: number): number {
  return Math.round(halalas) / 100;
}

export function toHalalas(riyals: string | number): number {
  return Math.round(Number(riyals) * 100);
}

// deno-lint-ignore no-explicit-any
type Json = any;

function outcomeOf(invoiceStatus: string | undefined, txStatus: string | undefined): PaymentOutcome {
  const tx = (txStatus ?? "").toUpperCase();
  if ((invoiceStatus ?? "").toUpperCase() === "PAID" && tx === "SUCCESS") return "paid";
  if (tx === "FAILED") return "failed";
  return "processing";
}

function paymentFrom(invoice: Json, tx: Json, amount: Json): MfPayment {
  const outcome = outcomeOf(invoice?.Status, tx?.Status);
  const message = tx?.Error?.Message;
  return {
    paymentId: String(tx?.PaymentId ?? ""),
    invoiceId: String(invoice?.Id ?? ""),
    externalIdentifier: invoice?.ExternalIdentifier ? String(invoice.ExternalIdentifier) : null,
    outcome,
    amountHalalas: toHalalas(amount?.ValueInBaseCurrency ?? 0),
    currency: String(amount?.BaseCurrency ?? ""),
    method: tx?.PaymentMethod ? String(tx.PaymentMethod) : null,
    errorMessage: outcome === "failed" && message ? String(message) : null,
  };
}

function refundFrom(data: Json): MfRefund {
  const s = String(data?.Refund?.Status ?? "").toLowerCase();
  const status = s === "refunded" ? "refunded" : s === "canceled" || s === "cancelled" ? "canceled" : "pending";
  return {
    refundId: String(data?.Refund?.Id ?? ""),
    status,
    amountHalalas: toHalalas(data?.Amount?.ValueInBaseCurrency ?? 0),
  };
}

export function makeMyFatoorahClient(
  apiKey: string,
  baseUrl: string,
  fetchImpl: typeof fetch = fetch,
) {
  const root = baseUrl.replace(/\/+$/, "");

  async function call(
    method: "GET" | "POST",
    path: string,
    body?: Record<string, unknown>,
    idempotencyKey?: string,
  ): Promise<Json> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    };
    if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;
    const res = await fetchImpl(`${root}${path}`, {
      method,
      headers,
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const text = await res.text();
    if (!res.ok) throw new MyFatoorahError(res.status, text);
    let parsed: Json;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new MyFatoorahError(res.status, text);
    }
    if (parsed?.IsSuccess === false) throw new MyFatoorahError(res.status, text);
    return parsed?.Data;
  }

  return {
    async payWithApplePay(args: {
      amountHalalas: number;
      tokenJson: string;
      externalIdentifier: string;
      idempotencyKey: string;
    }): Promise<MfPayment> {
      const data = await call("POST", "/v3/payments", {
        PaymentMethod: "APPLE_PAY",
        OperationType: "PAY",
        Order: { Amount: toRiyals(args.amountHalalas), ExternalIdentifier: args.externalIdentifier },
        SourceOfFund: { Token: args.tokenJson },
      }, args.idempotencyKey);
      const d = data?.TransactionDetails ?? {};
      const p = paymentFrom(d.Invoice, d.Transaction, d.Amount);
      return {
        ...p,
        paymentId: p.paymentId || String(data?.PaymentId ?? ""),
        invoiceId: p.invoiceId || String(data?.InvoiceId ?? ""),
      };
    },

    async getPayment(paymentId: string): Promise<MfPayment> {
      const d = await call("GET", `/v3/payments/${encodeURIComponent(paymentId)}`);
      return paymentFrom(d?.Invoice, d?.Transaction, d?.Amount);
    },

    async findPaymentByExternalIdentifier(externalIdentifier: string): Promise<MfPayment | null> {
      let d: Json;
      try {
        d = await call("GET", `/v3/invoices/externalIdentifier/${encodeURIComponent(externalIdentifier)}`);
      } catch (e) {
        if (e instanceof MyFatoorahError && e.status === 404) return null;
        throw e;
      }
      const txs: Json[] = Array.isArray(d?.Transactions) ? d.Transactions : [];
      if (txs.length === 0) return null;
      // A successful attempt wins over any earlier declines on the same invoice.
      const tx = txs.find((t) => String(t?.Status).toUpperCase() === "SUCCESS") ?? txs[txs.length - 1];
      return paymentFrom(d?.Invoice, tx, d?.Amount);
    },

    async createRefund(args: {
      paymentId: string;
      amountHalalas: number;
      externalIdentifier: string;
      idempotencyKey: string;
    }): Promise<MfRefund> {
      const d = await call("POST", "/v3/refunds", {
        PaymentId: args.paymentId,
        Amount: toRiyals(args.amountHalalas),
        ExternalIdentifier: args.externalIdentifier,
      }, args.idempotencyKey);
      return refundFrom(d);
    },

    async getRefund(refundId: string): Promise<MfRefund> {
      return refundFrom(await call("GET", `/v3/refunds/${encodeURIComponent(refundId)}`));
    },
  };
}
