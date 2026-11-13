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
  /// In the currency we asked for (riyals). On MyFatoorah's test server the
  /// account works in KWD and converts, so this is read from the "display"
  /// fields, falling back to the account's own when they are absent.
  amountHalalas: number;
  currency: string;
  /// The account's own currency and the value MyFatoorah holds in it. Refunds
  /// are sent in this currency.
  baseCurrency: string;
  baseValue: number;
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
  /// True only when MyFatoorah clearly answered "no": a 4xx, or a well-formed
  /// `IsSuccess: false`. A 5xx, a gateway page or an unreadable body says
  /// nothing about whether money moved, so callers must treat it as "unknown".
  readonly definitive: boolean;
  constructor(public status: number, public body: string, wellFormed = false) {
    super(`MyFatoorah ${status}: ${body.slice(0, 300)}`);
    this.isBalanceRefusal = /balance/i.test(body);
    this.definitive = status >= 400 && status < 500 ? true : status < 400 && wellFormed;
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

/// Our payment method label for MyFatoorah's: Apple Pay or a card.
export function methodLabel(method: string | null | undefined): "applepay" | "creditcard" {
  if (!method || /apple/i.test(method)) return "applepay";
  return "creditcard";
}

/// What to refund, in the account's own currency, for `halalas` of a payment.
/// Live in Saudi Arabia the two currencies are the same riyals. On the test
/// server the account is in KWD, so the refund is that share of what the
/// account received, to three places, and never more than the whole.
export function refundInBaseCurrency(
  halalas: number,
  p: Pick<MfPayment, "amountHalalas" | "currency" | "baseCurrency" | "baseValue">,
): number {
  if (p.baseCurrency === p.currency || p.amountHalalas <= 0) return toRiyals(halalas);
  const baseThousandths = Math.round(p.baseValue * 1000);
  const share = Math.round((baseThousandths * Math.min(halalas, p.amountHalalas)) / p.amountHalalas);
  return share / 1000;
}

function paymentFrom(invoice: Json, tx: Json, amount: Json): MfPayment {
  const outcome = outcomeOf(invoice?.Status, tx?.Status);
  const message = tx?.Error?.Message;
  const baseCurrency = String(amount?.BaseCurrency ?? "");
  const baseValue = Number(amount?.ValueInBaseCurrency ?? 0);
  const hasDisplay = amount?.DisplayCurrency != null && amount?.ValueInDisplayCurrency != null;
  return {
    paymentId: String(tx?.PaymentId ?? ""),
    invoiceId: String(invoice?.Id ?? ""),
    externalIdentifier: invoice?.ExternalIdentifier ? String(invoice.ExternalIdentifier) : null,
    outcome,
    amountHalalas: toHalalas(hasDisplay ? amount.ValueInDisplayCurrency : baseValue),
    currency: hasDisplay ? String(amount.DisplayCurrency) : baseCurrency,
    baseCurrency,
    baseValue,
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
    if (parsed?.IsSuccess === false) throw new MyFatoorahError(res.status, text, true);
    return parsed?.Data;
  }

  async function getPayment(paymentId: string): Promise<MfPayment> {
    const d = await call("GET", `/v3/payments/${encodeURIComponent(paymentId)}`);
    return paymentFrom(d?.Invoice, d?.Transaction, d?.Amount);
  }

  return {
    async payWithApplePay(args: {
      amountHalalas: number;
      currency: string;
      tokenJson: string;
      externalIdentifier: string;
      idempotencyKey: string;
    }): Promise<MfPayment> {
      const data = await call("POST", "/v3/payments", {
        PaymentMethod: "APPLE_PAY",
        OperationType: "PAY",
        Order: {
          Amount: toRiyals(args.amountHalalas),
          Currency: args.currency,
          ExternalIdentifier: args.externalIdentifier,
        },
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

    getPayment,

    /// Finds the payment made for our reference (MyFatoorah's ExternalIdentifier).
    ///
    /// Not `GET /v3/invoices/externalIdentifier/{ref}`: that puts the reference
    /// in the URL path, and MyFatoorah's server answers a ":" there with an error
    /// page (seen on the test server, 2026-11-12). The status lookup takes the
    /// reference in the body, which works for any reference; it only tells us
    /// which payment it was, and the v3 payment read gives the details.
    async findPaymentByExternalIdentifier(externalIdentifier: string): Promise<MfPayment | null> {
      let d: Json;
      try {
        d = await call("POST", "/v2/GetPaymentStatus", {
          Key: externalIdentifier,
          KeyType: "CustomerReference",
        });
      } catch (e) {
        // "No invoices match" arrives as a clear no; a 5xx does not.
        if (e instanceof MyFatoorahError && e.definitive) return null;
        throw e;
      }
      const txs: Json[] = Array.isArray(d?.InvoiceTransactions) ? d.InvoiceTransactions : [];
      if (txs.length === 0) return null;
      // A successful attempt wins over earlier declines on the same invoice.
      // MyFatoorah spells it "Succss" in this API; match both spellings.
      const tx = txs.find((t) => /^succ?e?ss$/i.test(String(t?.TransactionStatus ?? "")))
        ?? txs[txs.length - 1];
      const paymentId = tx?.PaymentId ? String(tx.PaymentId) : "";
      if (!paymentId) return null;
      return await getPayment(paymentId);
    },

    async createCardPayment(args: {
      amountHalalas: number;
      currency: string;
      externalIdentifier: string;
      idempotencyKey: string;
      redirectUrl: string;
    }): Promise<{ invoiceId: string; paymentUrl: string }> {
      const d = await call("POST", "/v3/payments", {
        PaymentMethod: "CARD",
        Order: {
          Amount: toRiyals(args.amountHalalas),
          Currency: args.currency,
          ExternalIdentifier: args.externalIdentifier,
        },
        IntegrationUrls: { Redirection: args.redirectUrl },
      }, args.idempotencyKey);
      const paymentUrl = String(d?.PaymentURL ?? "");
      if (!paymentUrl) throw new MyFatoorahError(200, JSON.stringify(d ?? null));
      return { invoiceId: String(d?.InvoiceId ?? ""), paymentUrl };
    },

    /// `baseAmount` is in the account's own currency (see refundInBaseCurrency).
    async createRefund(args: {
      paymentId: string;
      baseAmount: number;
      externalIdentifier: string;
      idempotencyKey: string;
    }): Promise<MfRefund> {
      const d = await call("POST", "/v3/refunds", {
        PaymentId: args.paymentId,
        Amount: args.baseAmount,
        ExternalIdentifier: args.externalIdentifier,
      }, args.idempotencyKey);
      return refundFrom(d);
    },

    async getRefund(refundId: string): Promise<MfRefund> {
      return refundFrom(await call("GET", `/v3/refunds/${encodeURIComponent(refundId)}`));
    },
  };
}
