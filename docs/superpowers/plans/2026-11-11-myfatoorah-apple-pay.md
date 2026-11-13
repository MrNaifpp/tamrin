# MyFatoorah Apple Pay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Moyasar with MyFatoorah for in-app Apple Pay, with the API key server-side only, refunds intact, and the two Moyasar-era bugs fixed.

**Architecture:** The app shows Apple's PassKit sheet and sends the `PKPaymentToken` to a new Edge Function, which calls MyFatoorah `POST /v3/payments` (`OperationType: "PAY"`) with the amount from the database and settles the seats. A signed webhook and a cron sweep re-fetch from MyFatoorah to settle anything the direct call missed. Refunds keep the existing trigger → `refund-payment` pipeline, with MyFatoorah calls inside and a new `waiting_balance` retry state.

**Tech Stack:** Supabase Postgres (plpgsql, pg_cron, pg_net, vault), Deno Edge Functions (TypeScript, std@0.224.0 assert), SwiftUI + PassKit (iOS), MyFatoorah API v3.

**Spec:** `docs/superpowers/specs/2026-11-11-myfatoorah-apple-pay-design.md`

## Global Constraints

- Branch: `feat/myfatoorah-apple-pay`. Do not merge into `staging`. Do not push unless Naif asks.
- Never commit `Sirr.xcodeproj/project.pbxproj`, `.DS_Store`, `Sirr.xcscheme`, or `Localizable.xcstrings` changes that predate this branch. Stage files by name, never `git add -A`.
- MyFatoorah v3 only. Base URL from env `MYFATOORAH_BASE_URL` (`https://api-sa.myfatoorah.com`). Header `Authorization: Bearer ${MYFATOORAH_API_KEY}`.
- Amounts: database stores integer halalas; MyFatoorah takes and returns decimal riyals. Convert only in `_shared/myfatoorah.ts`.
- Every MyFatoorah POST carries an `Idempotency-Key` header.
- The app never sends an amount; the server reads it from `payments.amount`.
- No MyFatoorah iOS SDK, no `MoyasarSdk`. PassKit only.
- Merchant ID `merchant.com.businessech.tmrin`; `countryCode = "SA"`; `supportedNetworks = [.mada, .visa, .masterCard]`.
- Webhook signature: header `MyFatoorah-Signature`, base64(HMAC-SHA256(secret, fields)), fields joined `key=value` with `,`, null → empty string. Payment fields in order: `Invoice.Id, Invoice.Status, Transaction.Status, Transaction.PaymentId, Invoice.ExternalIdentifier`. Refund fields in order: `Refund.Id, Refund.Status, Amount.ValueInBaseCurrency, ReferencedInvoice.Id`.
- Deno tests run through Docker (no local deno):
  `export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"; docker run --rm -v "$PWD/supabase/functions:/app" -w /app denoland/deno:alpine test <file>`
- SQL tests run against the local stack after a schema rebuild (never `db reset`, never re-run a migration): see the "Local Supabase DB workflow" note; `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f <file>`. A pass ends in `ROLLBACK` with no `ERROR`.
- iOS: build-check only (`xcodebuild … build`), never boot a simulator. Naif tests on device.
- Existing Arabic strings stay unless the meaning changes.

## Review Focus

1. **Double tap / retry after decline** — a second Apple Pay attempt on the same payment row must reach MyFatoorah (not a cached decline) and must never charge twice for the same authorization. Owner: Task 4 (`retries with a new token are sent; same token is not re-sent`).
2. **MyFatoorah call throws after money moved** (timeout) — the row must stay `processing`, never `failed`, so the sweep can find it. Owner: Task 4 (`network error leaves processing`) and Task 7.
3. **Guest added between quote and payment** — stays `pending`, not confirmed. Owner: Task 2 (`settle confirms only covered seats`).
4. **Covered seat removed before settle** (withdrew mid-payment) — payment settles, refund queued for that seat's price. Owner: Task 2 (`missing covered seat queues refund`).
5. **Refund same day as payment** (balance refused) — goes `waiting_balance`, not `failed`; failed after 7 days pushes the ops user. Owner: Task 3 and Task 6.

---

### Task 1: MyFatoorah client and webhook signature

**Files:**
- Create: `supabase/functions/_shared/myfatoorah.ts`
- Create: `supabase/functions/_shared/myfatoorah_test.ts`
- Create: `supabase/functions/_shared/myfatoorah_signature.ts`
- Create: `supabase/functions/_shared/myfatoorah_signature_test.ts`

**Interfaces:**
- Produces:
  - `type PaymentOutcome = "paid" | "failed" | "processing"`
  - `type MfPayment = { paymentId: string; invoiceId: string; externalIdentifier: string | null; outcome: PaymentOutcome; amountHalalas: number; currency: string; method: string | null; errorMessage: string | null }`
  - `type MfRefund = { refundId: string; status: "refunded" | "pending" | "canceled"; amountHalalas: number }`
  - `class MyFatoorahError extends Error { status: number; body: string; isBalanceRefusal: boolean }`
  - `makeMyFatoorahClient(apiKey: string, baseUrl: string, fetchImpl?: typeof fetch)` returning:
    - `payWithApplePay(args: { amountHalalas: number; tokenJson: string; externalIdentifier: string; idempotencyKey: string }): Promise<MfPayment>`
    - `getPayment(paymentId: string): Promise<MfPayment>`
    - `createRefund(args: { paymentId: string; amountHalalas: number; externalIdentifier: string; idempotencyKey: string }): Promise<MfRefund>`
    - `getRefund(refundId: string): Promise<MfRefund>`
    - `findPaymentByExternalIdentifier(externalIdentifier: string): Promise<MfPayment | null>` — `GET /v3/invoices/externalIdentifier/{id}`; `null` on 404 or when the invoice has no transaction. Test: `lookup by external identifier maps the latest transaction; 404 → null`.
  - `toRiyals(halalas: number): number`, `toHalalas(riyals: string | number): number` (rounds, so `"10.5"` → `1050`)
  - `verifySignature(secret: string, fields: Array<[string, string | number | null | undefined]>, header: string | null): Promise<boolean>`
  - `paymentSignatureFields(data: Record<string, any>)`, `refundSignatureFields(data: Record<string, any>)` → the ordered pairs above.

- [ ] **Step 1: Write failing client tests** in `myfatoorah_test.ts` with a fake `fetch` that records the request:
  - `payWithApplePay posts v3 payments with PAY and riyal amount` — URL `${base}/v3/payments`, method POST, headers `Authorization: Bearer k`, `Idempotency-Key: key-1`; body `{ PaymentMethod: "APPLE_PAY", OperationType: "PAY", Order: { Amount: 60, ExternalIdentifier: "pay-1" }, SourceOfFund: { Token: "{…}" } }` for `amountHalalas: 6000`.
  - `outcome mapping` — Invoice.Status `PAID` + Transaction.Status `SUCCESS` → `paid`; Transaction.Status `FAILED` → `failed` with `errorMessage` from `Transaction.Error.Message`; anything else → `processing`.
  - `amount parses ValueInBaseCurrency` — `"60"` → `6000`, `"10.5"` → `1050`; currency from `Amount.BaseCurrency`.
  - `createRefund posts v3 refunds` — body `{ PaymentId: "0707…", Amount: 30, ExternalIdentifier: "ref-1" }`, `Idempotency-Key` sent; response `Status: "Pending"` → `status: "pending"`.
  - `non-2xx throws MyFatoorahError` — status and body kept; a body whose message mentions insufficient/available balance sets `isBalanceRefusal = true` (match case-insensitively on `balance`).
- [ ] **Step 2: Run it, expect FAIL** (module not found).
  Run: `docker run --rm -v "$PWD/supabase/functions:/app" -w /app denoland/deno:alpine test _shared/myfatoorah_test.ts`
- [ ] **Step 3: Implement `_shared/myfatoorah.ts`.** Response envelope is `{ IsSuccess, Message, Data }`; treat `IsSuccess: false` as an error too. Payment shape: `Data.TransactionDetails` for POST, `Data` for GET.
- [ ] **Step 4: Write failing signature tests** in `myfatoorah_signature_test.ts`:
  - `payment fields order` — `paymentSignatureFields` on the doc example gives string `Invoice.Id=6409988,Invoice.Status=PAID,Transaction.Status=SUCCESS,Transaction.PaymentId=07076409988323998875,Invoice.ExternalIdentifier=asdqwd-f13sdf-fasjkz`.
  - `null becomes empty` — `Invoice.ExternalIdentifier=` when null.
  - `valid signature passes, tampered field fails, missing header fails` — compute the expected header in the test with WebCrypto HMAC-SHA256 over the string, base64.
- [ ] **Step 5: Implement `_shared/myfatoorah_signature.ts`** with WebCrypto; compare in constant time.
- [ ] **Step 6: Run both test files, expect PASS.**
- [ ] **Step 7: Commit**
```bash
git add supabase/functions/_shared/myfatoorah.ts supabase/functions/_shared/myfatoorah_test.ts supabase/functions/_shared/myfatoorah_signature.ts supabase/functions/_shared/myfatoorah_signature_test.ts
git commit -m "feat(payments): MyFatoorah v3 client and webhook signature"
```

---

### Task 2: Schema switch, covered seats, settle_payment

**Files:**
- Create: `supabase/migrations/20261111100000_myfatoorah_payments.sql`
- Create: `supabase/tests/myfatoorah_payments_test.sql`
- Modify (references only, if they break on rename): `supabase/tests/card_payment_rpcs_test.sql`, `supabase/tests/moyasar_payments_schema_test.sql` — delete these two; their cases move into the new test.

**Interfaces:**
- Produces (SQL):
  - Renames: `payments.moyasar_payment_id → provider_payment_id`, `payments.last_moyasar_status → last_provider_status`, `refunds.moyasar_payment_id → provider_payment_id`, table `moyasar_webhook_events → payment_webhook_events`.
  - New columns: `payments.provider text not null default 'myfatoorah'`, `refunds.provider_refund_id text unique`, `refunds.next_attempt_at timestamptz`.
  - New table `public.payment_seats (payment_id uuid references payments on delete cascade, participant_id uuid, price int not null check (price > 0), primary key (payment_id, participant_id))`. RLS on, no policies, revoke all from anon/authenticated. `participant_id` has **no** FK (the seat row may be deleted; the price must survive).
  - Drop `workspace_moyasar_recipients`.
  - `begin_card_payment(p_event_id uuid, p_user_id uuid) returns json` — same statuses minus `recipient_not_onboarded`; returns `{status:'ready', payment_id, amount, currency, seat_count, event_name}`. Inserts `payment_seats` rows for the seats it priced. Reuses an open `pending` payment only if its `payment_seats` set equals the current owed set; otherwise marks the old one `cancelled` and creates a new one.
  - `settle_payment(p_payment_id uuid, p_provider_payment_id text, p_outcome text, p_payment_method text, p_amount int, p_currency text) returns json` where `p_outcome in ('paid','failed','processing')`. Returns `{status: 'settled'|'already_settled'|'amount_mismatch'|'failed'|'processing', seats?: int, refund_id?: uuid}`.
  - Drop the old 7-arg `settle_payment` and 3-arg `begin_card_payment` signatures explicitly.

- [ ] **Step 1: Write the failing SQL test** `myfatoorah_payments_test.sql` (same fixture style as `refunds_test.sql`: `begin; … rollback;`, `pg_temp.set_auth`, `raise exception` on mismatch, a `raise notice 'PASS …'` per case):
  - `quote records covered seats` — member + 1 guest owe 60 SAR each → `amount = 12000`, 2 `payment_seats` rows with `price = 6000`.
  - `settle paid confirms only covered seats` — add a second guest after the quote, settle `'paid'` with amount 12000 → covered 2 are `confirmed`, the new guest stays `pending`, `payments.status = 'paid'`, one `push_outbox` row `payment_paid` to the event creator.
  - `missing covered seat queues refund` — delete the guest's participant row after the quote, settle `'paid'` → payment `paid`, member seat confirmed, one `refunds` row with `amount = 6000`, `seats = 1`, `reason = 'withdrew'`.
  - `amount mismatch fails` — settle `'paid'` with 11000 → `amount_mismatch`, no seat confirmed.
  - `processing then failed` — `'processing'` sets `status = 'processing'`; `'failed'` sets `failed`; `'failed'` after `paid` returns `already_settled`.
  - `provider id cannot change` — second settle with a different `p_provider_payment_id` raises.
  - `stale quote is replaced` — owed set changes between two `begin_card_payment` calls → first payment `cancelled`, second has the new seat set.
  - `authenticated cannot write` — as an authenticated user, insert into `payments` and `payment_seats` fails.
- [ ] **Step 2: Rebuild the local schema, apply migrations up to `20261109100000`, run the test, expect FAIL** (function signature / table missing).
- [ ] **Step 3: Write the migration.** Leftover refund in `settle_payment`: `price` sum of `payment_seats` rows whose `participant_id` no longer exists in `event_participants` (or is not `pending`/`confirmed` for this payment) → `public.request_refund(p_payment_id, <count>, <sum>, 'withdrew')`, called after `status = 'paid'` is written. Keep `security definer`, `set search_path = public`; grant execute on both functions to `service_role` only.
- [ ] **Step 4: Apply the new migration, run the test, expect PASS.** Also run `supabase/tests/refunds_test.sql` and `payment_reset_test.sql`; fix any reference to renamed columns *in the migration* (re-create affected functions there), not in old migration files.
- [ ] **Step 5: Commit** the migration, the new test, and the two deleted tests.
```bash
git commit -m "feat(payments): provider-neutral schema, covered seats, MyFatoorah settle"
```

---

### Task 3: Refund states, retry rules, failure push

**Files:**
- Create: `supabase/migrations/20261111110000_myfatoorah_refunds.sql`
- Modify: `supabase/tests/refunds_test.sql` (rename columns, add cases)
- Modify: `supabase/functions/send-push/` copy file that maps `type` → Arabic text (find it by grepping `refund_issued`), plus its test.

**Interfaces:**
- Consumes: Task 2 renames.
- Produces (SQL):
  - `refunds.status` check: `('pending','processing','waiting_balance','done','failed')`.
  - `settle_refund(p_refund_id uuid, p_status text, p_provider_refund_id text default null, p_failure_message text default null) returns json`, `p_status in ('refunded','pending','waiting_balance','failed')`:
    - `refunded` → as today (cumulative = `refunded_amount + amount`, clamp, `done`, push `refund_issued`).
    - `pending` → `status = 'processing'`, store `provider_refund_id`.
    - `waiting_balance` → `status = 'waiting_balance'`, `attempts = attempts + 1`, `next_attempt_at = now() + interval '1 day'`; if `created_at < now() - interval '7 days'` treat as `failed`.
    - `failed` → `failed`, message, and one `push_outbox` row type `refund_failed` to the user id in vault secret `ops_user_id` (skip silently if unset).
  - `request_refund`: the "remaining" cap subtracts `done` **and** open (`pending`,`processing`,`waiting_balance`) refund amounts and seats, not just `payments.refunded_amount`.
  - `retry_pending_refunds()`: re-posts rows where `(status = 'pending' and created_at < now() - '3 minutes' and attempts < 5)` or `(status = 'processing' and updated_at < now() - '10 minutes')` or `(status = 'waiting_balance' and next_attempt_at <= now())`.
  - Drop the old 4-arg `settle_refund`.

- [ ] **Step 1: Add failing cases to `refunds_test.sql`:**
  - `pending keeps processing` — `settle_refund(id,'pending','R1')` → `processing`, `provider_refund_id = 'R1'`, `payments.refunded_amount` unchanged.
  - `waiting_balance schedules next day` — status `waiting_balance`, `next_attempt_at` between now+23h and now+25h.
  - `waiting_balance after 7 days fails and pushes ops` — set vault `ops_user_id`, backdate `created_at` 8 days → `failed`, one `refund_failed` outbox row for that user.
  - `open refunds count toward the cap` — payment 12000, one `processing` refund of 6000 → `request_refund(…, 1, 12000, …)` creates a row of 6000, not 12000.
  - `sweep picks due rows only` — `retry_pending_refunds()` returns the count of: one old `pending`, one stale `processing`, one due `waiting_balance`; ignores a fresh `processing` and a not-yet-due `waiting_balance`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Add `refund_failed` copy in send-push** — title `استرداد متعثر`, body `تعذّر إرجاع مبلغ لأحد اللاعبين. راجع لوحة MyFatoorah.`; extend the copy test with that type.
- [ ] **Step 5: Run SQL and send-push copy tests, expect PASS.**
- [ ] **Step 6: Commit** (`feat(payments): refunds wait for balance and alert ops on failure`).

---

### Task 4: `create-payment` and `pay-apple-pay`

**Files:**
- Modify: `supabase/functions/create-payment/handler.ts`, `index.ts`, `handler_test.ts`
- Create: `supabase/functions/pay-apple-pay/handler.ts`, `index.ts`, `handler_test.ts`
- Delete: `supabase/functions/verify-payment/` (whole folder), `supabase/functions/_shared/moyasar.ts`, `moyasar_test.ts`, `payment_checks.ts`, `payment_checks_test.ts`

**Interfaces:**
- Consumes: Task 1 client; Task 2 `begin_card_payment`, `settle_payment`.
- Produces (HTTP, user JWT required):
  - `create-payment` POST `{event_id}` → `{status:'ready', payment_id, amount, currency, seat_count, event_name}` or `{status: 'free_event'|'nothing_due'|'already_paid'|'event_closed'}`.
  - `pay-apple-pay` POST `{payment_id, token}` where `token = {PaymentData: object, PaymentMethod: {displayName, network, type}, TransactionIdentifier: string}` → `{status:'paid'}` | `{status:'failed', reason}` | `{status:'processing'}`.
- `makeHandler(deps: PayDeps)` with `PayDeps = { getUserId(auth): Promise<string|null>; loadPayment(id): Promise<{id,user_id,amount,currency,status,provider_payment_id}|null>; markProcessing(id): Promise<void>; mf: ReturnType<typeof makeMyFatoorahClient>; settle(args): Promise<{status:string}> }`.

- [ ] **Step 1: Update `create-payment/handler_test.ts`** — no `publishable_key`, `splits`, `metadata`, `given_id` in the ready body; no `p_allow_without_recipient` in the rpc args. Run, expect FAIL; then update `handler.ts`/`index.ts` (drop `MOYASAR_PUBLISHABLE_KEY`, `ALLOW_PAYMENTS_WITHOUT_RECIPIENT`); run, expect PASS.
- [ ] **Step 2: Write failing `pay-apple-pay/handler_test.ts`:**
  - `rejects without auth (401)`, `rejects someone else's payment (404)`, `missing token (400)`.
  - `already paid returns paid without calling MyFatoorah`.
  - `sends database amount, not body amount` — body carries `amount: 1`; client receives `amountHalalas: 6000`, `externalIdentifier: "pay-1"`, `tokenJson` = `JSON.stringify(token)`.
  - `idempotency key is payment id plus TransactionIdentifier` — `pay:pay-1:tx-A`.
  - `retries with a new token are sent; same token is not re-sent` — every Apple Pay authorization has its own `TransactionIdentifier`, so the key decides: two calls with `tx-A` both reach the client with the **same** key `pay:pay-1:tx-A` (MyFatoorah returns the cached result, no second charge); after a `failed` outcome, a call with `tx-B` reaches the client with key `pay:pay-1:tx-B`. A `failed` row may be paid again (status `failed` is accepted like `pending`).
  - `paid outcome settles and answers paid` — `settle` gets `p_outcome:'paid'`, `p_amount: 6000`, `p_currency:'SAR'`, `p_payment_method:'applepay'`.
  - `failed outcome settles failed with reason` — reason is MyFatoorah's `errorMessage`.
  - `network error leaves processing` — client throws a non-`MyFatoorahError` → `markProcessing` called, `settle` not called with `failed`, response `{status:'processing'}` (HTTP 200).
- [ ] **Step 3: Run, expect FAIL. Implement. Run, expect PASS.** `markProcessing` is called **before** the MyFatoorah call so a crash mid-call still leaves a row the sweep finds.
- [ ] **Step 4: Delete the Moyasar function folders and shared files listed above.** Run every remaining `*_test.ts` under `supabase/functions` to prove nothing still imports them.
- [ ] **Step 5: Commit** (`feat(payments): Apple Pay through MyFatoorah on the server`).

---

### Task 5: `myfatoorah-webhook`

**Files:**
- Create: `supabase/functions/myfatoorah-webhook/handler.ts`, `index.ts`, `handler_test.ts`
- Delete: `supabase/functions/moyasar-webhook/`
- Modify: `supabase/config.toml` — `[functions.myfatoorah-webhook] verify_jwt = false` (copy the moyasar-webhook entry, remove that entry).

**Interfaces:**
- Consumes: Task 1 client + signature; Task 2 `settle_payment`; Task 3 `settle_refund`.
- `WebhookDeps = { secret: string; recordEvent({reference, code, raw}): Promise<'new'|'duplicate'>; findPaymentById(id): Promise<{id}|null>; findRefundById(id): Promise<{id}|null>; mf; settlePayment(args); settleRefund(args) }`. `payment_webhook_events.id` stores `Event.Reference`.

- [ ] **Step 1: Write failing tests:**
  - `bad signature → 401, nothing recorded`.
  - `replayed reference → duplicate, no settle`.
  - `payment event re-fetches and settles from GET, not from the body` — body says `PAID`, GET returns `FAILED` → `settlePayment` gets `'failed'`.
  - `payment event for unknown ExternalIdentifier → 200 ignored`.
  - `refund event re-fetches GET /v3/refunds and settles` — `Refunded` → `settleRefund(id,'refunded', refundId)`; `Canceled` → `'failed'`; `Pending` → `'pending'`. Refund row found by `Data.Refund.ExternalIdentifier` (our refunds id).
  - `other event codes → 200 ignored`.
- [ ] **Step 2: Run, FAIL. Implement. Run, PASS.**
- [ ] **Step 3: Commit** (`feat(payments): signed MyFatoorah webhook`).

---

### Task 6: `refund-payment` on MyFatoorah

**Files:**
- Modify: `supabase/functions/refund-payment/handler.ts`, `index.ts`, `handler_test.ts`

**Interfaces:**
- Consumes: Task 1 `createRefund`, `getRefund`, `MyFatoorahError.isBalanceRefusal`; Task 3 `settle_refund`.
- `RefundRow = { id, provider_payment_id, provider_refund_id: string|null, amount, status, attempts }`.

- [ ] **Step 1: Rewrite the tests:**
  - `pending row → createRefund with idempotency key "refund:<id>:<attempts>"`, `externalIdentifier = id`; `Pending` → `settle(…,'pending', refundId)`; `Refunded` → `'refunded'`.
  - `balance refusal → 'waiting_balance'`; `other MyFatoorahError → 'failed'` with message.
  - `processing row with provider_refund_id → getRefund, never createRefund`.
  - `waiting_balance row → createRefund again` with the incremented attempts key.
  - `done/failed row → duplicate, no calls`.
  - `network error (not MyFatoorahError) → row left as is, 200` so the sweep retries.
- [ ] **Step 2: Run, FAIL. Implement. Run, PASS.**
- [ ] **Step 3: Commit** (`feat(payments): refunds through MyFatoorah`).

---

### Task 7: Payment sweep

**Files:**
- Create: `supabase/functions/payment-sweep/handler.ts`, `index.ts`, `handler_test.ts`
- Create: `supabase/migrations/20261111120000_payment_sweep.sql`
- Modify: `supabase/config.toml` (`verify_jwt = false` for `payment-sweep`)

**Interfaces:**
- Shared-secret gate like `refund-payment` (vault `payment_sweep_url`, `payment_sweep_secret`; env `PAYMENT_SWEEP_SECRET`).
- Handler: `loadStuck(): Promise<Array<{id, provider_payment_id: string|null, amount, currency}>>` (status `processing`, `updated_at < now() - 3 minutes`, `provider = 'myfatoorah'`, limit 50); for each: if `provider_payment_id` is null (the server died before MyFatoorah answered) → `findPaymentByExternalIdentifier(id)`; `null` and older than 30 minutes → `settle_payment(…,'failed',…)` with `failure_code = 'no_provider_payment'`, `null` and younger → leave; otherwise `getPayment` (or the lookup result) → `settle_payment` with the mapped outcome.
- Migration: `retry_processing_payments()` posts to the sweep via `net.http_post` (copy `post_refund`), cron `retry-processing-payments` every 5 minutes, unschedule-by-name first.

- [ ] **Step 1: Failing tests:** `401 without secret`; `processing with id → getPayment → settle paid`; `still processing → no settle`; `no provider id, found by external identifier → settle paid`; `no provider id, not found, older than 30 min → failed`; `not found, younger → untouched`.
- [ ] **Step 2: Run, FAIL. Implement. Run, PASS.** Apply the migration locally and check `select jobname from cron.job` lists `retry-processing-payments`.
- [ ] **Step 3: Commit** (`feat(payments): sweep stuck MyFatoorah payments`).

---

### Task 8: App — PassKit-only Apple Pay

**Files:**
- Modify: `Sirr/Components/ApplePayButton.swift`
- Rename+modify: `Sirr/core/payment/MoyasarPaymentService.swift` → `ApplePayPaymentService.swift`; `MoyasarPaymentModels.swift` → `ApplePayPaymentModels.swift`
- Modify: `Sirr/core/payment/CardPayments.swift`, `Sirr/features/home/EventDetailView.swift` (call sites near lines 490, 908, 967–985, 1095–1098, 2793–2799, 3091–3092, 3427)
- Delete: `Sirr/Components/CardPaymentSheet.swift`
- Modify: `Sirr/Sirr.entitlements` — add `com.apple.developer.in-app-payments` = `[merchant.com.businessech.tmrin]`

**Interfaces:**
- Consumes: Task 4 HTTP shapes.
- Produces (Swift):
  - `struct PaymentQuote: Decodable { paymentId: UUID; amount: Int; currency: String; seatCount: Int; eventName: String }` (+ `amountInRiyals`).
  - `enum PaymentStart { case ready(PaymentQuote), freeEvent, nothingDue, alreadyPaid, eventClosed }`.
  - `enum PaymentVerdict { case paid, processing, failed(reason: String?) }`.
  - `final class ApplePayPaymentService { static let shared; func startPayment(eventId: UUID) async throws -> PaymentStart; func pay(paymentId: UUID, token: PKPaymentToken) async throws -> PaymentVerdict }` — `pay` builds `{payment_id, token:{PaymentData: <JSONSerialization of token.paymentData>, PaymentMethod:{displayName, network, type}, TransactionIdentifier}}`.
  - `ApplePayButton.present(quote:eventName:onResult:)` with `onResult: (PaymentOutcome) -> Void`, `enum PaymentOutcome { case paid, processing, failed(String), cancelled }`. In `didAuthorizePayment`, call `pay`, map `paid`/`processing` → `.success`, `failed` → `.failure`.
  - `CardPayments.isEnabled: Bool` = `SupabaseEnvironment.host.hasPrefix("kpcdinxusxycenfnitjc.")` (production added at go-live); button shown when `CardPayments.isEnabled && ApplePayButton.isAvailable`, else the manual transfer.

- [ ] **Step 1: Make the changes.** Remove every `#if canImport(MoyasarSdk)` branch; keep the existing summary items, Arabic strings, button style and `isAvailable` logic. Where `CardPaymentSheet` was presented, present the manual transfer (`showPaymentReview = true`). The `.processing` result shows the existing "still confirming" state.
- [ ] **Step 2: Build-check.**
  Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -configuration Debug -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO | tail -5`
  Expected: `** BUILD SUCCEEDED **`; `grep -rn "Moyasar" Sirr --include=*.swift` returns nothing.
- [ ] **Step 3: Confirm `git status` shows no `project.pbxproj` change.** Commit the Swift files and entitlements by name (`feat(app): Apple Pay through our server, no payment SDK`).

---

### Task 9: Sandbox deploy and setup notes

**Files:**
- Modify: `PAYMENT_SETUP.md` — replace the Moyasar sections with MyFatoorah: secrets, webhook URL, CSR → certificate steps, the 1-riyal test checklist from the spec's "Testing" section, how to read `waiting_balance`/`failed` refunds.
- Delete: `scripts/moyasar-account-check.sh`, `scripts/moyasar-splits-probe.sh`

- [ ] **Step 1: Write `PAYMENT_SETUP.md`.**
- [ ] **Step 2: Hand Naif the paste-ready commands** (he runs them; never echo the key):
  - `supabase secrets set MYFATOORAH_API_KEY=… MYFATOORAH_BASE_URL=https://api-sa.myfatoorah.com MYFATOORAH_WEBHOOK_SECRET=… PAYMENT_SWEEP_SECRET=… --project-ref kpcdinxusxycenfnitjc`
  - vault rows `payment_sweep_url`, `payment_sweep_secret`, `ops_user_id` (SQL editor).
  - Migrations 20261111100000/110000/120000 applied to the sandbox by Naif in the SQL editor.
  - `supabase functions deploy create-payment pay-apple-pay myfatoorah-webhook refund-payment payment-sweep send-push --project-ref kpcdinxusxycenfnitjc`
  - Portal → Integration Settings → Webhook Settings: URL `https://kpcdinxusxycenfnitjc.supabase.co/functions/v1/myfatoorah-webhook`, V2, events Payment + Refund status changed, retries 5.
- [ ] **Step 3: After Naif confirms**, check the sweep by calling `payment-sweep` with the secret (expect `{checked: 0}`), and check the vault digests match the function secrets (sha256 compare, as in `PAYMENT_SETUP.md`).
- [ ] **Step 4: Commit** (`docs(payments): MyFatoorah setup and test checklist`).

Device testing (spec "Testing", steps 1–6) waits for MyFatoorah's certificate confirmation. Production rollout and App Review are out of this plan.
