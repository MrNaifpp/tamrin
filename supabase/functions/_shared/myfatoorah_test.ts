import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  makeMyFatoorahClient, methodLabel, MyFatoorahError, refundInBaseCurrency, toHalalas, toRiyals,
} from "./myfatoorah.ts";

type Seen = { url: string; method: string; headers: Headers; body: unknown };

function fakeFetch(status: number, response: unknown) {
  const seen: Seen[] = [];
  const impl = (async (input: string | URL | Request, init?: RequestInit) => {
    seen.push({
      url: String(input),
      method: init?.method ?? "GET",
      headers: new Headers(init?.headers),
      body: init?.body ? JSON.parse(String(init.body)) : undefined,
    });
    return new Response(JSON.stringify(response), { status });
  }) as typeof fetch;
  return { seen, impl };
}

const base = "https://api-sa.example";

function transaction(invoiceStatus: string, txStatus: string, extra: Record<string, unknown> = {}) {
  return {
    Invoice: { Id: "7323767", Status: invoiceStatus, ExternalIdentifier: "pay-1" },
    Transaction: {
      Status: txStatus,
      PaymentMethod: "Apple Pay",
      PaymentId: "0707-1",
      Error: { Code: "", Message: txStatus === "FAILED" ? "DECLINED : Do not honour" : "" },
    },
    Amount: { BaseCurrency: "SAR", ValueInBaseCurrency: "60" },
    ...extra,
  };
}

Deno.test("payWithApplePay posts v3 payments with PAY and riyal amount", async () => {
  const { seen, impl } = fakeFetch(200, {
    IsSuccess: true,
    Data: { InvoiceId: "7323767", PaymentId: "0707-1", TransactionDetails: transaction("PAID", "SUCCESS") },
  });
  const mf = makeMyFatoorahClient("k", base, impl);
  await mf.payWithApplePay({ amountHalalas: 6000, currency: "SAR", tokenJson: "{\"a\":1}", externalIdentifier: "pay-1", idempotencyKey: "key-1" });

  assertEquals(seen.length, 1);
  assertEquals(seen[0].url, `${base}/v3/payments`);
  assertEquals(seen[0].method, "POST");
  assertEquals(seen[0].headers.get("authorization"), "Bearer k");
  assertEquals(seen[0].headers.get("idempotency-key"), "key-1");
  assertEquals(seen[0].body, {
    PaymentMethod: "APPLE_PAY",
    OperationType: "PAY",
    Order: { Amount: 60, Currency: "SAR", ExternalIdentifier: "pay-1" },
    SourceOfFund: { Token: "{\"a\":1}" },
  });
});

Deno.test("outcome mapping", async () => {
  const cases: Array<[string, string, string]> = [
    ["PAID", "SUCCESS", "paid"],
    ["PENDING", "FAILED", "failed"],
    ["PENDING", "INPROGRESS", "processing"],
    ["PENDING", "AUTHORIZE", "processing"],
  ];
  for (const [inv, tx, want] of cases) {
    const { impl } = fakeFetch(200, { IsSuccess: true, Data: transaction(inv, tx) });
    const p = await makeMyFatoorahClient("k", base, impl).getPayment("0707-1");
    assertEquals(p.outcome, want, `${inv}/${tx}`);
  }
  const { impl } = fakeFetch(200, { IsSuccess: true, Data: transaction("PENDING", "FAILED") });
  const failed = await makeMyFatoorahClient("k", base, impl).getPayment("0707-1");
  assertEquals(failed.errorMessage, "DECLINED : Do not honour");
});

Deno.test("getPayment reads ids, method and currency", async () => {
  const { seen, impl } = fakeFetch(200, { IsSuccess: true, Data: transaction("PAID", "SUCCESS") });
  const p = await makeMyFatoorahClient("k", base, impl).getPayment("0707-1");
  assertEquals(seen[0].url, `${base}/v3/payments/0707-1`);
  assertEquals(seen[0].method, "GET");
  assertEquals(p.paymentId, "0707-1");
  assertEquals(p.invoiceId, "7323767");
  assertEquals(p.externalIdentifier, "pay-1");
  assertEquals(p.currency, "SAR");
  assertEquals(p.method, "Apple Pay");
});

Deno.test("amount parses ValueInBaseCurrency", () => {
  assertEquals(toHalalas("60"), 6000);
  assertEquals(toHalalas("10.5"), 1050);
  assertEquals(toHalalas(0.1), 10);
  assertEquals(toRiyals(6000), 60);
  assertEquals(toRiyals(1050), 10.5);
});

Deno.test("createRefund posts v3 refunds", async () => {
  const { seen, impl } = fakeFetch(200, {
    IsSuccess: true,
    Data: { Refund: { Id: "309962", Status: "Pending" }, Amount: { ValueInBaseCurrency: 30 } },
  });
  const r = await makeMyFatoorahClient("k", base, impl).createRefund({
    paymentId: "0707-1", baseAmount: 30, externalIdentifier: "ref-1", idempotencyKey: "refund:ref-1:0",
  });
  assertEquals(seen[0].url, `${base}/v3/refunds`);
  assertEquals(seen[0].body, { PaymentId: "0707-1", Amount: 30, ExternalIdentifier: "ref-1" });
  assertEquals(seen[0].headers.get("idempotency-key"), "refund:ref-1:0");
  assertEquals(r, { refundId: "309962", status: "pending", amountHalalas: 3000 });
});

Deno.test("getRefund maps Refunded and Canceled", async () => {
  for (const [s, want] of [["Refunded", "refunded"], ["Canceled", "canceled"], ["REFUNDED", "refunded"]]) {
    const { seen, impl } = fakeFetch(200, {
      IsSuccess: true,
      Data: { Refund: { Id: "309963", Status: s }, Amount: { ValueInBaseCurrency: 60 } },
    });
    const r = await makeMyFatoorahClient("k", base, impl).getRefund("309963");
    assertEquals(seen[0].url, `${base}/v3/refunds/309963`);
    assertEquals(r.status, want);
  }
});

function routedFetch(routes: Array<{ match: (url: string, method: string) => boolean; status: number; body: unknown }>) {
  const seen: Seen[] = [];
  const impl = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const method = init?.method ?? "GET";
    seen.push({ url, method, headers: new Headers(init?.headers), body: init?.body ? JSON.parse(String(init.body)) : undefined });
    const r = routes.find((x) => x.match(url, method));
    if (!r) return new Response("no route", { status: 599 });
    return new Response(typeof r.body === "string" ? r.body : JSON.stringify(r.body), { status: r.status });
  }) as typeof fetch;
  return { seen, impl };
}

// MyFatoorah's v3 lookup puts our reference in the URL path, and their server
// returns an error page for a ":" in it (seen on the test server 2026-11-12).
// The status lookup takes it in the body, so any reference works.
Deno.test("lookup by our reference finds the successful payment, then reads it with v3", async () => {
  const ref = "a72ce64e-af3c-44e9-93fe-3902b2439f4c:card032454a5";
  const { seen, impl } = routedFetch([
    {
      match: (u, m) => u.endsWith("/v2/GetPaymentStatus") && m === "POST", status: 200,
      body: { IsSuccess: true, Data: { InvoiceId: 7367020, InvoiceStatus: "Paid", CustomerReference: ref,
        InvoiceTransactions: [
          { TransactionStatus: "Failed", PaymentId: "0707-old" },
          { TransactionStatus: "Succss", PaymentId: "07077367020394975874" },
        ] } },
    },
    {
      match: (u, m) => u.endsWith("/v3/payments/07077367020394975874") && m === "GET", status: 200,
      body: { IsSuccess: true, Data: transaction("PAID", "SUCCESS", {
        Invoice: { Id: "7367020", Status: "PAID", ExternalIdentifier: ref },
        Transaction: { Status: "SUCCESS", PaymentId: "07077367020394975874", PaymentMethod: "VISA/MASTER", Error: {} },
      }) },
    },
  ]);
  const p = await makeMyFatoorahClient("k", base, impl).findPaymentByExternalIdentifier(ref);
  assertEquals(seen[0].url, `${base}/v2/GetPaymentStatus`);
  assertEquals(seen[0].body, { Key: ref, KeyType: "CustomerReference" });
  assertEquals(p?.paymentId, "07077367020394975874");
  assertEquals(p?.outcome, "paid");
  assertEquals(p?.externalIdentifier, ref);
});

Deno.test("lookup by our reference: no invoice, or an invoice with no attempt, is null", async () => {
  const none = routedFetch([{ match: () => true, status: 200,
    body: { IsSuccess: false, Message: "No invoices match this External Identifier!", Data: null } }]);
  assertEquals(await makeMyFatoorahClient("k", base, none.impl).findPaymentByExternalIdentifier("x"), null);
  const empty = routedFetch([{ match: () => true, status: 200,
    body: { IsSuccess: true, Data: { InvoiceStatus: "Pending", InvoiceTransactions: [] } } }]);
  assertEquals(await makeMyFatoorahClient("k", base, empty.impl).findPaymentByExternalIdentifier("x"), null);
});

Deno.test("non-2xx throws MyFatoorahError", async () => {
  const { impl } = fakeFetch(400, { IsSuccess: false, Message: "Bad things" });
  const err = await assertRejects(
    () => makeMyFatoorahClient("k", base, impl).getPayment("x"),
    MyFatoorahError,
  );
  assertEquals(err.status, 400);
  assert(err.body.includes("Bad things"));
  assertEquals(err.isBalanceRefusal, false);
});

Deno.test("IsSuccess false is an error too, and a balance refusal is flagged", async () => {
  const { impl } = fakeFetch(200, { IsSuccess: false, Message: "Insufficient available Balance to refund" });
  const err = await assertRejects(
    () => makeMyFatoorahClient("k", base, impl).createRefund({
      paymentId: "p", baseAmount: 1, externalIdentifier: "r", idempotencyKey: "i",
    }),
    MyFatoorahError,
  );
  assertEquals(err.isBalanceRefusal, true);
});

Deno.test("only a clear answer is definitive: 4xx or IsSuccess false; 5xx and garbage are not", async () => {
  const cases: Array<[number, string, boolean]> = [
    [400, JSON.stringify({ IsSuccess: false, Message: "Invalid token" }), true],
    [200, JSON.stringify({ IsSuccess: false, Message: "Declined" }), true],
    [502, JSON.stringify({ IsSuccess: false, Message: "Bad gateway" }), false],
    [504, "<html>Gateway Timeout</html>", false],
    [200, "<html>not json</html>", false],
  ];
  for (const [status, body, want] of cases) {
    const impl = (async () => new Response(body, { status })) as typeof fetch;
    const err = await assertRejects(() => makeMyFatoorahClient("k", base, impl).getPayment("x"), MyFatoorahError);
    assertEquals(err.definitive, want, `${status} ${body}`);
  }
});

Deno.test("lookup by external identifier: a clear 'no invoice' answer of any 4xx is null; a 5xx throws", async () => {
  const noMatch = fakeFetch(400, { IsSuccess: false, Message: "No invoices match the provided external identifier" });
  assertEquals(await makeMyFatoorahClient("k", base, noMatch.impl).findPaymentByExternalIdentifier("x"), null);
  const down = fakeFetch(503, { IsSuccess: false });
  await assertRejects(() => makeMyFatoorahClient("k", base, down.impl).findPaymentByExternalIdentifier("x"), MyFatoorahError);
});

Deno.test("payWithApplePay states the currency", async () => {
  const { seen, impl } = fakeFetch(200, {
    IsSuccess: true,
    Data: { InvoiceId: "1", PaymentId: "p", TransactionDetails: transaction("PAID", "SUCCESS") },
  });
  await makeMyFatoorahClient("k", base, impl).payWithApplePay({
    amountHalalas: 100, currency: "SAR", tokenJson: "{}", externalIdentifier: "e", idempotencyKey: "i",
  });
  assertEquals((seen[0].body as { Order: { Currency: string } }).Order.Currency, "SAR");
});

Deno.test("amount and currency are the ones we asked for; the account's own are kept apart", async () => {
  const { impl } = fakeFetch(200, {
    IsSuccess: true,
    Data: transaction("PAID", "SUCCESS", {
      Amount: {
        BaseCurrency: "KWD", ValueInBaseCurrency: "4.917",
        DisplayCurrency: "SAR", ValueInDisplayCurrency: "60",
      },
    }),
  });
  const p = await makeMyFatoorahClient("k", base, impl).getPayment("0707-1");
  assertEquals(p.amountHalalas, 6000);
  assertEquals(p.currency, "SAR");
  assertEquals(p.baseCurrency, "KWD");
  assertEquals(p.baseValue, 4.917);
});

Deno.test("without display fields the base amount is the amount", async () => {
  const { impl } = fakeFetch(200, { IsSuccess: true, Data: transaction("PAID", "SUCCESS") });
  const p = await makeMyFatoorahClient("k", base, impl).getPayment("0707-1");
  assertEquals([p.amountHalalas, p.currency, p.baseCurrency, p.baseValue], [6000, "SAR", "SAR", 60]);
});

Deno.test("refundInBaseCurrency: riyals stay riyals; dinars are the paid share, to 3 places, never more", () => {
  const sar = { amountHalalas: 6000, currency: "SAR", baseCurrency: "SAR", baseValue: 60 };
  assertEquals(refundInBaseCurrency(3000, sar), 30);
  const kwd = { amountHalalas: 6000, currency: "SAR", baseCurrency: "KWD", baseValue: 4.917 };
  assertEquals(refundInBaseCurrency(3000, kwd), 2.459);
  assertEquals(refundInBaseCurrency(6000, kwd), 4.917);
  assertEquals(refundInBaseCurrency(9000, kwd), 4.917);
});

Deno.test("methodLabel: Apple Pay is applepay, every card is creditcard", () => {
  assertEquals(methodLabel("Apple Pay"), "applepay");
  assertEquals(methodLabel("MADA"), "creditcard");
  assertEquals(methodLabel("VISA/MASTER"), "creditcard");
  assertEquals(methodLabel(null), "applepay");
});

Deno.test("createCardPayment asks for a hosted card page and returns its link", async () => {
  const { seen, impl } = fakeFetch(200, {
    IsSuccess: true, Data: { InvoiceId: "61", PaymentId: null, PaymentURL: "https://demo.example/pay/61" },
  });
  const r = await makeMyFatoorahClient("k", base, impl).createCardPayment({
    amountHalalas: 6000, currency: "SAR", externalIdentifier: "pay-1:card1", idempotencyKey: "card:pay-1:card1",
    redirectUrl: "https://tamrien.app/",
  });
  assertEquals(seen[0].url, `${base}/v3/payments`);
  assertEquals(seen[0].headers.get("idempotency-key"), "card:pay-1:card1");
  assertEquals(seen[0].body, {
    PaymentMethod: "CARD",
    Order: { Amount: 60, Currency: "SAR", ExternalIdentifier: "pay-1:card1" },
    IntegrationUrls: { Redirection: "https://tamrien.app/" },
  });
  assertEquals(r, { invoiceId: "61", paymentUrl: "https://demo.example/pay/61" });
});
