import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeHandler, type CardTestDeps, testCardsAllowed } from "./handler.ts";
import { MyFatoorahError } from "../_shared/myfatoorah.ts";
import type { ClaimResult } from "../pay-apple-pay/handler.ts";

type LinkArgs = Parameters<CardTestDeps["mf"]["createCardPayment"]>[0];

function deps(opts: {
  enabled?: boolean;
  claim?: ClaimResult["status"];
  link?: (a: LinkArgs) => Promise<{ invoiceId: string; paymentUrl: string }>;
} = {}) {
  const claims: Array<{ paymentId: string; userId: string; attempt: string }> = [];
  const links: LinkArgs[] = [];
  const settles: Array<Parameters<CardTestDeps["settle"]>[0]> = [];
  const d: CardTestDeps = {
    enabled: opts.enabled ?? true,
    redirectUrl: "https://tamrien.app/",
    newAttemptSuffix: () => "ab12cd34",
    getUserId: async (a) => (a === "Bearer good" ? "user-1" : null),
    claim: async (paymentId, userId, attempt) => {
      claims.push({ paymentId, userId, attempt });
      const c = opts.claim ?? "claimed";
      return c === "claimed" ? { status: c, amount: 6000, currency: "SAR" } : { status: c } as ClaimResult;
    },
    mf: {
      createCardPayment: async (a) => {
        links.push(a);
        return opts.link ? opts.link(a) : { invoiceId: "61", paymentUrl: "https://demo.example/pay/61" };
      },
    },
    settle: async (a) => { settles.push(a); return { status: "failed" }; },
  };
  return { d, claims, links, settles };
}

const post = (body: unknown, auth = "Bearer good") =>
  new Request("http://x/pay-card-test", {
    method: "POST", headers: { authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

Deno.test("only MyFatoorah's test server with the switch on allows test cards", () => {
  assertEquals(testCardsAllowed("true", "https://apitest.myfatoorah.com"), true);
  assertEquals(testCardsAllowed("true", "https://apitest.myfatoorah.com/"), true);
  assertEquals(testCardsAllowed("true", "https://api-sa.myfatoorah.com"), false);
  assertEquals(testCardsAllowed(undefined, "https://apitest.myfatoorah.com"), false);
  assertEquals(testCardsAllowed("false", "https://apitest.myfatoorah.com"), false);
  assertEquals(testCardsAllowed("true", "https://apitest.myfatoorah.com.evil.example"), false);
});

Deno.test("switched off → 403, nothing claimed", async () => {
  const { d, claims } = deps({ enabled: false });
  const res = await makeHandler(d)(post({ payment_id: "pay-1" }));
  assertEquals(res.status, 403);
  assertEquals(claims.length, 0);
});

Deno.test("rejects without auth (401) and without payment_id (400)", async () => {
  const { d } = deps();
  assertEquals((await makeHandler(d)(post({ payment_id: "pay-1" }, "Bearer bad"))).status, 401);
  assertEquals((await makeHandler(d)(post({}))).status, 400);
});

Deno.test("claims a card attempt as the caller and returns the card page link", async () => {
  const { d, claims, links } = deps();
  const res = await makeHandler(d)(post({ payment_id: "pay-1", amount: 1 }));
  assertEquals(await res.json(), { status: "ready", payment_url: "https://demo.example/pay/61" });
  assertEquals(claims, [{ paymentId: "pay-1", userId: "user-1", attempt: "pay-1:cardab12cd34" }]);
  assertEquals(links, [{
    amountHalalas: 6000, currency: "SAR", externalIdentifier: "pay-1:cardab12cd34",
    idempotencyKey: "card:pay-1:cardab12cd34", redirectUrl: "https://tamrien.app/",
  }]);
});

Deno.test("claim answers that open no page", async () => {
  const cases: Array<[ClaimResult["status"], number, unknown]> = [
    ["not_found", 404, { error: "not found" }],
    ["paid", 200, { status: "paid" }],
    ["processing", 200, { status: "processing" }],
    ["not_payable", 409, { status: "failed", reason: "not_payable" }],
    ["event_closed", 409, { status: "failed", reason: "event_closed" }],
  ];
  for (const [claim, code, body] of cases) {
    const { d, links } = deps({ claim });
    const res = await makeHandler(d)(post({ payment_id: "pay-1" }));
    assertEquals(res.status, code, claim);
    assertEquals(await res.json(), body, claim);
    assertEquals(links.length, 0, claim);
  }
});

Deno.test("a clear refusal fails this attempt", async () => {
  const { d, settles } = deps({
    link: async () => { throw new MyFatoorahError(400, '{"IsSuccess":false}', true); },
  });
  const res = await makeHandler(d)(post({ payment_id: "pay-1" }));
  assertEquals(await res.json(), { status: "failed", reason: "refused" });
  assertEquals(settles[0].p_outcome, "failed");
  assertEquals(settles[0].p_attempt, "pay-1:cardab12cd34");
});

Deno.test("no clear answer leaves the row for the sweep and says so", async () => {
  const { d, settles } = deps({ link: async () => { throw new TypeError("network down"); } });
  const res = await makeHandler(d)(post({ payment_id: "pay-1" }));
  assertEquals(res.status, 502);
  assertEquals(await res.json(), { status: "failed", reason: "no_link" });
  assertEquals(settles.length, 0);
});
