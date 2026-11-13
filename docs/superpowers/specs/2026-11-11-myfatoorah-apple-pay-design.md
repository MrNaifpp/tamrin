# MyFatoorah Apple Pay — design

Date: 2026-11-11 · Status: approved by Naif 2026-11-11

## Where the work lives

On its own branch, `feat/myfatoorah-apple-pay`, cut from `staging`. It merges into
`staging` only after a real Apple Pay payment works on Naif's phone, so no other release
(e.g. 1.9 (10) "pick players") picks up PassKit and the entitlement early.

## Still open (decide before App Review submission, not before building)

How Apple's reviewer reaches Apple Pay: a demo reviewer account in production with an
unpaid seat on a cheap workout, whether a real 1 SAR charge + automatic refund is
acceptable, and the review-notes wording. Not needed to build or test.

## Why

Tamrin signed a better contract with MyFatoorah, so card payments move from Moyasar to
MyFatoorah. Nothing about the product changes: a member who owes for a workout pays in the
app, the seat is confirmed, and money goes back automatically when they withdraw, remove a
guest, or the organizer cancels. All money lands in Tamrin's own MyFatoorah account (no
payouts to organizers, no multi-vendor).

## Decided by Naif

- **Apple Pay only.** No card form, no Visa/Mastercard entry screen. A mada card saved in
  Apple Wallet pays through Apple Pay. Members without Apple Pay keep the manual transfer
  they use today.
- **Money goes to Tamrin's account**, as with Moyasar.
- **Testing on the live Saudi account** with 1-riyal payments, each refunded (option A).
  The live API key goes into the **sandbox** Supabase project (`kpcdinxusxycenfnitjc`)
  while testing; production gets it only at go-live.
- **Integration style:** Apple's own Apple Pay sheet in the app; the server talks to
  MyFatoorah. The MyFatoorah iOS SDK is **not** used (it needs the secret key inside the
  app and runs on their old v2 API).

## Goals

1. Pay for your seats (and your guests' seats) with Apple Pay, through MyFatoorah.
2. Refunds keep working for all three reasons: withdrew, guest removed, event cancelled.
3. The MyFatoorah API key never leaves the server.
4. Fix the two known Moyasar-era bugs instead of carrying them over:
   - **Paid but never collected:** if the app closed after Apple Pay approved, nothing
     captured the money and the seat stayed unconfirmed.
   - **Free guest:** a guest added between tapping pay and the payment settling got
     confirmed without being paid for.
5. Pass App Review: the build that ships PassKit must actually offer working Apple Pay.

## Non-goals

- Card entry form, STC Pay, Google Pay, saved cards, tokenization.
- Payouts to organizers / MyFatoorah multi-vendor (suppliers).
- Payment history screens (still open from the Moyasar list).
- Organizer refunding a removed paid player (still open; separate work).
- Web app / Android payments.

## Anti-goals (would be a failure even if it "works")

- The API key in the app binary, in the repo, or in chat.
- A seat confirmed because the **device** said "paid". Only the server, after asking
  MyFatoorah, confirms a seat.
- Charging someone twice for the same seats (double tap, retry, webhook + app both
  settling).
- Shipping a build with PassKit where Apple Pay doesn't work (the October rejection,
  Guideline 2.1).

## Constraints

- **API:** MyFatoorah **v3** only (`/v3/payments`, `/v3/refunds`). Saudi live base URL
  `https://api-sa.myfatoorah.com`. Auth header `Authorization: Bearer <key>`.
  Amounts are **decimal riyals** (our database stores integer halalas; divide by 100).
- **Apple Pay native** needs MyFatoorah to install our Payment Processing Certificate:
  they send a CSR → we create the certificate on Merchant ID
  `merchant.com.businessech.tmrin` → send `apple_pay.cer` back → they confirm. **This is
  pending.** Until it's confirmed, real Apple Pay payments will be declined; everything
  else can be built and tested.
- Merchant ID, App IDs and provisioning profiles from the Moyasar work stay as they are
  (`PAYMENT_SETUP.md`, "Apple Pay — done on 2026-09-20").
- **Refunds are requests.** Without "Auto Refund" enabled on the account, MyFatoorah's
  finance team executes them by hand; the request also needs enough available balance.
  Our flow must treat a refund as *pending until MyFatoorah says it's done*.
- **Webhook V2** must be enabled in the portal (Integration Settings → Webhook
  Settings). Signature: `MyFatoorah-Signature` header, HMAC-SHA256 (base64) with the
  portal's secret key over the event's fields in a fixed order, e.g. for payments
  `Invoice.Id=…,Invoice.Status=…,Transaction.Status=…,Transaction.PaymentId=…,Invoice.ExternalIdentifier=…`
  and for refunds `Refund.Id=…,Refund.Status=…,Amount.ValueInBaseCurrency=…,ReferencedInvoice.Id=…`.
  Null values become empty strings.
- **Idempotency:** MyFatoorah honours an `Idempotency-Key` header for 250 minutes. Use our
  own row id as the key for every payment and refund call.
- Project rules: migrations reach production by hand-run SQL, never `db push` from
  staging; never commit `project.pbxproj` changes (the project uses synchronized folders,
  so adding/removing Swift files needs no pbxproj edit).

## How it works

### Paying (the happy path)

1. Member taps the Apple Pay button on the event screen.
2. App calls **`create-payment`** (Edge Function). It runs `begin_card_payment`, which
   prices the member's owed seats from the database and returns a quote
   (payment id, amount, currency, seat count). **New:** the payments row also records
   *which* participant rows it covers (fixes the free-guest bug; see below).
3. App shows Apple's sheet with that amount (summary line: workout name · seat count;
   last line "تمرين"). `supportedNetworks = [.mada, .visa, .masterCard]`,
   `countryCode = "SA"`, `merchantCapabilities = [.threeDSecure, .debit, .credit]`.
4. Member approves with Face ID. PassKit hands the app a `PKPaymentToken`.
5. App sends the token to **`pay-apple-pay`** (new Edge Function, replaces
   `verify-payment`): `{ payment_id, token }` where `token` is
   `{ PaymentData, PaymentMethod, TransactionIdentifier }` built from the PKPaymentToken.
6. The server, holding the API key:
   - loads the payments row (must belong to the caller, status `pending`),
   - calls `POST /v3/payments` with `PaymentMethod: "APPLE_PAY"`,
     `SourceOfFund.Token` = the token JSON string, `Order.Amount` = **the database
     amount** (never anything the app sent), `Order.ExternalIdentifier` = our payment id,
     `OperationType: "PAY"`, `Idempotency-Key` = our payment id,
   - reads the result and calls `settle_payment`.
7. Server answers the app `paid` / `failed` / `processing`. App tells Apple Pay
   success/failure, then shows the result. The app never decides; it renders the
   server's answer.

**Why `PAY` and not authorize-then-capture:** with Moyasar the *device* sent the payment,
so we held it and checked the amount before collecting. Now the *server* sends it with the
amount from the database, so there's nothing to check afterwards and nothing to hold.
This also means we don't depend on MyFatoorah enabling "Authorize & Capture". *(My call —
see "Calls I made".)*

### Why the "paid but never collected" bug goes away

The server does the whole payment in one request. If the app dies after sending the
token, the server still finishes. If the app dies *before* sending it, Apple Pay never
reached MyFatoorah, so no money moved. The remaining gap — the server call itself
failing mid-way — is covered by the webhook and a sweep (below).

### Fixing the free-guest bug

`begin_card_payment` writes the covered participant ids onto the payment (new column, or a
small join table — builder's choice). `settle_payment` confirms **only those** rows, not
"every pending seat this member owns right now". A guest added after the quote stays
pending and owes their own payment.

If a covered seat is gone by settle time (the member withdrew, the event was cancelled),
the payment still settles as paid and a refund for those seats is queued through the
existing `request_refund` path, so the money goes back automatically.

### Webhook (`myfatoorah-webhook`, replaces `moyasar-webhook`)

- Verify `MyFatoorah-Signature`; reject on mismatch.
- Record the event by `Event.Reference` (replays hit the primary key and stop).
- `PAYMENT_STATUS_CHANGED`: find our payment by `Invoice.ExternalIdentifier`, then
  **re-fetch** `GET /v3/payments/{paymentId}` and settle from what that returns — the body
  only tells us *something* changed.
- `REFUND_STATUS_CHANGED`: find our refund by the stored MyFatoorah refund id (or the
  `ExternalIdentifier` we sent), re-fetch `GET /v3/refunds/{refundId}`, settle the refund.
- Always return 200 once recorded, so MyFatoorah stops retrying.

### Sweep

A cron job (the existing `retry_pending_refunds` pattern) re-checks:
- payments stuck in `processing` for more than a few minutes → `GET /v3/payments/{id}` → settle;
- refunds stuck `processing` (sent, waiting on MyFatoorah) → `GET /v3/refunds/{id}` → settle.

### Refunds (`refund-payment`, rewritten inside)

Triggers stay exactly as they are (`request_refund`, `post_refund`, the outbox, the
vault secrets `refund_payment_url` / `refund_payment_secret`). Only the call changes:

- `POST /v3/refunds` with the MyFatoorah `PaymentId` and the amount in riyals,
  `Idempotency-Key` = our refunds row id, `ExternalIdentifier` = our refunds row id.
- Store the MyFatoorah refund id on the row; status `processing`.
- MyFatoorah answers `Pending`, `Refunded` or `Canceled`. `Refunded` → `done`
  (settle as today). `Pending` → stay `processing` until the webhook or sweep says
  otherwise.
- **Not enough balance is expected, not final.** MyFatoorah's refundable balance excludes
  money received the same day, so withdrawing on the day you paid can be refused. An API
  refusal for balance → new status `waiting_balance`; the sweep **re-sends** it (same
  Idempotency-Key is *not* reused, since the first attempt was refused) once a day for up
  to 7 days. `Canceled` by MyFatoorah, any other refusal, or 7 days without success →
  `failed`, and Naif gets a push so a person can sort it out. The member keeps seeing
  "refund on its way" until then. *(My call.)*
- `request_refund`'s "never refund more than remains" rule counts refunds that are
  `pending`, `processing` or `waiting_balance`, not just `done`, because refunds can now
  stay open for days.
- MyFatoorah doesn't return a running "total refunded" like Moyasar did, so the
  cumulative `payments.refunded_amount` is the sum of our own `done` refunds for that
  payment.

### Database changes

Production already has the Moyasar tables (applied in the 2026-10-16 bundle) with no card
data in them, because cards were never switched on in production. So:

- Rename provider-specific names to neutral ones: `payments.moyasar_payment_id` →
  `provider_payment_id`, `last_moyasar_status` → `last_provider_status`,
  `refunds.moyasar_payment_id` → `provider_payment_id`, `moyasar_webhook_events` →
  `payment_webhook_events`. Add `refunds.provider_refund_id`, `payments.provider`
  (`'myfatoorah'`).
- `payment_method`: the existing `'applepay'` value is what we store.
- `refunds.status` gains `waiting_balance`.
- Covered participants on the payment (free-guest fix).
- Drop `workspace_moyasar_recipients` and the `p_allow_without_recipient` gate: there are
  no recipients in this model. `begin_card_payment` no longer returns
  `recipient_not_onboarded`.
- Update `settle_payment` / `settle_refund` for MyFatoorah statuses
  (`Transaction.Status` `SUCCESS` → paid; `FAILED` → failed; refund `Refunded` /
  `Pending` / `Canceled`).

### App changes

- `ApplePayButton.swift`: keep Apple's `PayWithApplePayButton` and the PKPayment sheet;
  remove every `MoyasarSdk` use. On authorize, send the token to `pay-apple-pay` and
  complete the sheet with the server's answer. Pure PassKit, no third-party SDK.
- Delete `CardPaymentSheet.swift` and the card path (Apple Pay only). Where the card
  sheet used to be the fallback, the fallback is the manual transfer.
- Rename `MoyasarPaymentService` / `MoyasarPaymentModels` to provider-neutral names and
  drop the publishable key, splits and metadata fields the quote no longer carries.
- `CardPayments.isEnabled`: on when the build talks to a project where the functions are
  live (sandbox now, production at go-live) **and** Apple Pay is available on the device.
  No more `#if canImport(MoyasarSdk)`.
- Re-add `com.apple.developer.in-app-payments` = `[merchant.com.businessech.tmrin]` to
  `Sirr/Sirr.entitlements`.
- Arabic copy stays as it is where the meaning is unchanged.

### Secrets (sandbox now, production at go-live)

`MYFATOORAH_API_KEY`, `MYFATOORAH_BASE_URL` (`https://api-sa.myfatoorah.com`),
`MYFATOORAH_WEBHOOK_SECRET`. Remove `MOYASAR_*` and `ALLOW_PAYMENTS_WITHOUT_RECIPIENT`
once the switch is done. API key permissions: create payments, get payment details,
refunds — nothing else.

## Testing

- Unit tests for every Edge Function handler with a fake MyFatoorah client (same style as
  the Moyasar `handler_test.ts` files, run through the Deno Docker image).
- Signature verification tested against the examples in MyFatoorah's docs.
- Database: rebuild-the-schema check, not migration replays (local `db reset` is broken).
- **Before the certificate is confirmed:** server-side calls against the live API with the
  real key — a refund request on a tiny payment, payment lookup, webhook delivery.
- **After the certificate is confirmed:** on Naif's phone, sandbox-pinned build:
  1. pay 1 SAR with a real mada card in Wallet → seat confirmed;
  2. withdraw → refund lands (check how long without Auto Refund);
  3. pay for self + guest, remove the guest → partial refund;
  4. organizer cancels → full refund;
  5. kill the app right after Face ID → seat still confirms (server or webhook);
  6. add a guest mid-payment → guest stays unpaid.
- Then the App Review build: Release, pointing at production, Apple Pay working.

## Open with MyFatoorah (Naif)

1. Apple Pay CSR → certificate → their confirmation. **Blocks only the device test.**
2. Webhook V2 enabled in the portal; secret key copied into the password manager.
3. Auto Refund: on or off? Off means refunds wait for their finance team.
4. Confirm Apple Pay (with mada) appears in `GET /v3/payment-methods` for the account.

## Left to the builder

- Exact table/column shape for covered participants.
- Sweep timing and retry limits.
- How the app shows `processing` (reuse the current "still confirming" state).
- Error messages beyond the existing Arabic strings.
- Whether `create-payment` keeps its name or becomes `start-payment`.

## Calls I made (Naif to check)

1. **`PAY`, not authorize-then-capture.** Safe because the server sets the amount; avoids
   needing MyFatoorah to enable Auth & Capture.
2. **No MyFatoorah iOS SDK.** Apple's own PassKit only; the key stays on the server.
3. **Rename `moyasar_*` columns to neutral names** rather than leaving the old names.
4. **Drop the Moyasar recipient table and gate**, since all money goes to Tamrin.
5. **Fix both known bugs in this work** rather than separately.
6. **Refunds refused for balance retry daily for 7 days**, then fail and push Naif.
