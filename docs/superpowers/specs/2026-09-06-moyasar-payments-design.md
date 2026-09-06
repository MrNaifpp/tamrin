# Moyasar card payments — design

**Status:** Awaiting review
**Date:** 2026-09-06
**Branch:** `feat/moyasar-payments`

---

## Why

Tamrin collects money peer-to-peer today: a player transfers to the organizer's own
STC Bank / bank account and the organizer confirms it by hand
(`declare_event_payment` → `confirm_payment`). It works, but it is manual on both
ends and nothing verifies that the transfer actually happened.

This adds card and Apple Pay payment through Moyasar, settling into the organizer's
own account via Moyasar's split payments — so the money still ends up where it ends
up today, without anyone typing an IBAN.

## What this is not

Manual transfer is **not** removed. It stays the default and remains the only option
for a workspace that has no verified Moyasar recipient — which is every workspace on
the day this ships. Card payment is strictly additive.

---

## Verified facts (from official Moyasar docs, 2026-09-06)

These are load-bearing. Everything below depends on them.

| Fact | Source |
|---|---|
| `POST /v1/payments`, `GET /v1/payments/{id}`, capture / void / refund endpoints | [Payments API](https://docs.moyasar.com/api/payments/01-create-payment/) |
| Amount is an integer in the smallest currency unit (halalas for SAR) | Payments API |
| Statuses: `initiated`, `paid`, `failed`, `authorized`, `captured`, `refunded`, `voided`, `verified` | Payments API |
| Sources: `creditcard`, `token`, `applepay`, `samsungpay`, `stcpay` | Payments API |
| `splits[]` fields: `amount`, `recipient_id`, `recipient_type` (`Entity`/`Platform`/`Beneficiary`), `reference`, `description`, `fee_source`, `refundable` | Payments API |
| **Splits require merchant enablement and only work for entities created after October 2025** | Payments API |
| Webhook events: `payment_paid`, `payment_faild` *(sic)*, `payment_refunded`, `payment_voided`, `payment_authorized`, `payment_captured`, `payment_verified` | [Webhook reference](https://docs.moyasar.com/api/other/webhooks/webhook-reference/) |
| Webhook payload carries `id`, `type`, `created_at`, `secret_token`, `account_name`, `live`, `data` | Webhook reference |
| Official iOS SDK: `github.com/moyasar/moyasar-ios-sdk`, **v3.2.3**, SPM, iOS 13+, ships `ar.lproj` | Repo `Package.swift` |
| SDK accepts **publishable keys only** — `^pk_(test\|live)_.{40}$` | SDK `PaymentRequest.swift` |
| `PaymentRequest` exposes `manual`, `givenID`, `metadata`, `splits`, `allowedNetworks` | SDK `PaymentRequest.swift` |
| `ApplePayService.authorizePayment(request:token:)` honours `request.manual` | SDK `ApplePayService.swift` |

### Confirmed against the account (2026-09-06, `scripts/moyasar-account-check.sh`)

- Test secret key valid; account reachable; 0 payments; Invoices API reachable.
- The account **can create payable objects in test mode** — a 1.00 SAR invoice was
  created and returned a `checkout.moyasar.com` URL.
- `POST /v1/payments` with a `splits[]` array reaches **field-level validation**:

  ```
  400 validation_error
  "splits.0.recipient_id": ["Must be a valid recipient (Entity, Platform or
                             Beneficiary) UUID."]
  ```

  So the API knows the field and looks the recipient up. This is strong evidence
  that splits are available, but **not proof of entitlement** — validation runs
  before entitlement checks, so a fake id fails identically either way.
  `scripts/moyasar-splits-probe.sh` settles it with a real recipient id.

### Unverified — must be confirmed before relying on it

1. **Webhook authentication mechanism.** Docs describe a `secret_token` field in the
   payload ("the endpoint's secret is assigned by the consumer") but do not state
   whether a signature header also exists. Design assumes shared-secret-in-body and
   compensates by never trusting the body (see below). Revisit if a signature header
   turns out to exist.
2. **Splits entitlement on this account**, and **splits + manual authorization
   together.** No doc states these compose. `scripts/moyasar-splits-probe.sh`
   answers both in one request: it authorizes 1.00 SAR split to a real recipient
   with `manual: true`, reads the resulting status, and voids it. Fallback in
   "Risks".
3. **Whether Moyasar will onboard individual organizers** (no commercial
   registration) as Beneficiaries. This gates the whole feature going live and is a
   commercial question, not a technical one.
4. **How a recipient id is obtained at all.** No documented endpoint lists entities
   or beneficiaries; `recipient_id` only appears in Settlements and Transfers
   responses, which are empty on a new account. Onboarding a workspace as a
   recipient may be a dashboard-only or Moyasar-side operation, which would shape
   how `workspace_moyasar_recipients` rows get created.

---

## Splits — deep findings (2026-09-06)

A full sweep of `docs.moyasar.com` (including its own `/docs-hierarchy/` page listing
every documented page), the marketing site, and the platform terms.

### Splits is barely documented, and that is itself the finding

There is **no splits guide anywhere in the documentation hierarchy**. The feature
appears in exactly two places: the `splits[]` request field on Create Payment, and
the split fields on settlement lines. There is no page explaining how to obtain a
`recipient_id`, no worked example, and no request-side example JSON — only response
examples.

### There is no API to create a recipient

Searched the whole hierarchy: **no entities, recipients, or beneficiaries endpoint
exists.** `recipient_id` only ever appears in *read* responses:

- `GET /settlements/:id/lines` → `recipient_id`, `recipient_type`, `custom_splits`,
  `is_custom_split`, `split_reference`, `split_description`
- `GET /transfers` → `recipient_id`, `recipient_type`

And the Payouts API — the obvious candidate for "stored beneficiary" — does **not**
work that way: `POST /payouts` takes the destination **inline** (`iban`, `name`,
`mobile`, `country`, `city`). There is no stored beneficiary object with an id, so a
payout destination is *not* a splits `recipient_id`.

**Conclusion: creating a splits recipient is not a self-serve API operation.** It is
a Moyasar-side or dashboard action. This decides how `workspace_moyasar_recipients`
rows get filled — by an operator pasting an id, not by an onboarding call the app
makes.

### Two merchant models, and splits belongs to one of them

Moyasar distinguishes **aggregation merchants** from **facilitation merchants**
("direct bank merchants"). The Transfers API is stated to be *"exclusively available
for Moyasar aggregation merchants"* and is served from a different host
(`apimig.moyasar.com`). Splits and transfers belong to the aggregation model — the
one where Moyasar holds funds and distributes them. Tamrin needs to be an
**aggregation** merchant, and this is worth naming explicitly when talking to sales.

### The October 2025 note, read precisely

The exact wording, and it sits in the **response** section:

> "This field is returned for entities created after 2025-10, if you need to recieve
> it, please contact support team." *(sic)*

So it governs whether the field is **returned in responses**, and support can turn it
on. This is a softer constraint than "splits only work for post-October-2025
entities" — which is how it first read. It does not by itself say an older account
cannot *send* splits.

Consistent with a partial rollout, the settlement-line schema notes that its
`splits` field *"currently returns null and is reserved for future use."*

### Constraints that are NOT specified

Genuinely absent from the docs, so they must be established empirically or by asking:

- Whether split amounts must sum to the payment amount.
- Whether the platform's own share must appear as an explicit split.
- Any minimum or maximum number of splits.
- Whether exactly one split must carry `fee_source: true`.

`fee_source` is defined only as *"determine which split will be used to deduct
processing fees"*, and `refundable` as *"indicate if the split should be reversed
when refunding the payment"* (default `true`).

### Who can actually receive money — the decisive product constraint

From the Moyasar FAQ, requirements to hold a merchant account:

> a valid Saudi commercial registration (CR) **or freelance license**, and a Saudi
> commercial bank account linked to it

The Platform Terms define a merchant as *"a natural or legal person"*, so individuals
are eligible in principle — but only through a **freelance license** (وثيقة العمل
الحر) with a bank account linked to it. The platform is obliged to run KYC, and the
PSP *"has the right to refuse the onboarding of any merchant."*

**This is the real wall.** A typical Tamrin organizer — someone arranging weekly
football among friends — has no CR and no freelance license. A freelance license is
free and obtainable online in Saudi Arabia, but requiring one before an organizer can
collect 60 SAR from five friends is a serious adoption barrier, and it is a product
decision rather than an engineering one.

Also relevant to expectations: settlement is *"within seven (7) Business Days from
the date the balance reaches ... one hundred (100) Saudi Riyals or more."* An
organizer would not receive money the same day, unlike today's instant bank transfer.

### What this changes in the design

Nothing structural — and that is the point of having gated card payment behind a
verified recipient. The coexistence decision now looks better than it did: manual
transfer stays the path for the overwhelming majority of workspaces, and card
payment becomes an option for organizers who run their group as an actual business.

---

## The security problem, and the shape of the answer

The Moyasar iOS SDK creates the payment **from the device**, with a publishable key,
carrying the amount and the splits array. A modified client could therefore attempt
to pay 1 SAR for a 60 SAR seat, or aim the split at a different recipient.

Verifying after the fact is not enough — the money has already moved and a refund is
a worse outcome than a rejection.

**Answer: authorize on the device, capture only from the server.**

`PaymentRequest(manual: true)` makes the SDK authorize without capturing. Funds are
held, not taken. The server then fetches the payment with the **secret key**, checks
it against what the database says is owed, and either captures it or voids it. A
tampered amount produces a void — the money never settles.

This holds for Apple Pay too: `ApplePayService` forwards `request.manual` onto the
Apple Pay source.

```
App                    Edge Function                Moyasar                DB
 │
 ├─ create-payment ───────►│
 │                         ├─ auth caller (JWT)
 │                         ├─ compute amount from events + seats owed
 │                         ├─ require verified recipient for workspace
 │                         ├─ insert payments row (pending) ──────────────►│
 │◄─ pk key, amount, splits, given_id, metadata
 │
 ├─ MoyasarSdk CreditCardView / ApplePayService (manual: true)
 │                                    ├──────────────►│ POST /v1/payments
 │                                    │               │ 3-D Secure
 │◄────────────────────── authorized ─┤◄──────────────┤
 │
 ├─ verify-payment ───────►│
 │                         ├─ GET /v1/payments/{id}  ►│   (SECRET key)
 │                         ├─ assert amount, currency, given_id, recipient
 │                         ├─ match   → POST capture ►│
 │                         ├─ mismatch→ POST void    ►│
 │                         └─ settle_payment() ──────────────────────────►│
 │◄─ paid / failed
                                       │
                           moyasar-webhook ◄─── payment_captured ─────────┤
                                       ├─ dedupe by webhook id
                                       ├─ re-fetch from Moyasar (never trust body)
                                       └─ settle_payment()  (idempotent) ►│
```

`settle_payment()` is the **only** thing in the system that moves a seat to
`confirmed`. Both the client-driven path and the webhook path call it, so there is
one place to reason about and one place to test.

---

## Database

### `workspace_moyasar_recipients`

One verified Moyasar recipient per workspace. Its existence is what makes the card
button appear.

```
workspace_id          uuid pk references workspaces(id) on delete cascade
moyasar_recipient_id  text not null
recipient_type        text not null check in ('Entity','Platform','Beneficiary')
status                text not null default 'pending'
                        check in ('pending','verified','disabled')
verified_at           timestamptz
created_at            timestamptz not null default now()
updated_at            timestamptz not null default now()
```

RLS: the workspace owner may `select` their own row. **No insert/update/delete grant
to `authenticated`.** `status = 'verified'` is written by service_role only, after a
human has confirmed onboarding — a workspace cannot promote itself into taking card
payments.

### `payments`

```
id                  uuid pk default gen_random_uuid()
workspace_id        uuid not null references workspaces(id)
event_id            uuid not null references events(id) on delete cascade
user_id             uuid not null references auth.users(id)
seat_count          int  not null check (seat_count > 0)
amount              int  not null check (amount >= 100)   -- halalas
currency            text not null default 'SAR'
status              text not null default 'pending'
                      check in ('pending','processing','paid','failed','cancelled','refunded')
payment_method      text check in ('creditcard','applepay','stcpay','token')
moyasar_payment_id  text unique
given_id            uuid not null unique default gen_random_uuid()
split_recipient_id  text
platform_fee        int  not null default 0               -- built now, zero today
failure_code        text
failure_message     text
last_moyasar_status text
authorized_at       timestamptz
paid_at             timestamptz
created_at          timestamptz not null default now()
updated_at          timestamptz not null default now()
```

`amount >= 100` mirrors Moyasar's documented minimum.

`given_id` is generated server-side and sent to Moyasar as the idempotency key, so a
retried authorization cannot produce two charges.

RLS: `select` for the payer (`user_id = auth.uid()`) and for the workspace owner.
**No insert, update or delete granted to `authenticated` under any condition.** All
writes come from Edge Functions holding service_role. This is what makes "the app
cannot set a payment to paid" true by construction rather than by convention.

### `moyasar_webhook_events`

```
id            text pk        -- Moyasar's own webhook id; the dedupe key
type          text not null
payment_id    uuid references payments(id)
received_at   timestamptz not null default now()
raw           jsonb not null
```

Idempotency is an insert conflict, not application logic: a replayed webhook fails
the primary key and is acknowledged with 200 without re-settling.

### `event_participants.payment_id`

```
alter table public.event_participants
  add column payment_id uuid references public.payments(id);
```

A member pays for their own seat and their guests in one transaction, exactly as
`declare_event_payment` already stamps all their pending rows at once. One payment
covers N participant rows.

### `settle_payment()`

`security definer`, executable by service_role only (revoked from `authenticated`
and `anon`). Takes a Moyasar payment id and an already-verified status. In one
transaction it flips `payments.status` and the covered `event_participants` rows to
`confirmed`, and enqueues the organizer push. Returns early if the payment is
already settled, so calling it twice is safe.

---

## Edge Functions

Written in the existing `send-push` style: Deno, `createClient` with
`SUPABASE_SERVICE_ROLE_KEY`, explicit early returns.

### `create-payment` — `verify_jwt = true`

1. Resolve the caller from the JWT. Never accept a user id in the body.
2. Load the event; assert it is published, not cancelled, registration open.
3. **Compute the amount server-side** from `events.price_per_person` × the caller's
   pending seats (own row + guest rows where `added_by = caller`). The request body
   carries an event id and nothing financial.
4. Reject if a `paid` payment already covers those seats — "already paid" is an
   error, not a second charge.
5. Require a `verified` recipient for the workspace; otherwise return
   `recipient_not_onboarded` and the app falls back to manual transfer.
6. Insert the `payments` row as `pending`.
7. Return `publishable_key`, `amount`, `currency`, `given_id`, `splits[]`,
   `description`, `metadata`. The splits array is **computed here**; the app passes
   it through to the SDK verbatim and has no say in it.

Returning the publishable key rather than compiling it into the binary means
rotating it, or moving between test and live, needs no App Store release — and the
key automatically follows whichever Supabase project the build talks to.

### `verify-payment` — `verify_jwt = true`

1. Resolve the caller; load the `payments` row and assert ownership.
2. `GET https://api.moyasar.com/v1/payments/{id}` with the **secret key**.
3. Assert, all of: status is `authorized` (or already `paid`/`captured`),
   `amount` equals the stored amount, `currency` matches, `given_id` matches, and
   the split recipient equals the workspace's verified recipient.
4. All hold → `POST /v1/payments/{id}/capture` → `settle_payment()`.
5. Any fail → `POST /v1/payments/{id}/void` → mark `failed` with the reason. Nothing
   settles.

### `moyasar-webhook` — `verify_jwt = false`

Gateway JWT verification is off because Moyasar cannot present a Supabase JWT — the
same reasoning already applied to `send-push`. The function's own checks are the
gate.

1. Constant-time compare `secret_token` in the body against `MOYASAR_WEBHOOK_SECRET`;
   401 otherwise.
2. Insert into `moyasar_webhook_events` keyed on the webhook id. Conflict → 200, done.
3. **Re-fetch the payment from Moyasar with the secret key.** The body is treated as
   a notification that something changed, never as the truth about what it changed
   to. This is what makes the unverified webhook-auth mechanism safe to depend on: a
   forged webhook that somehow passed step 1 still cannot assert a payment is paid.
4. Route by real status: `paid`/`captured` → `settle_payment()`; `failed`/`voided` →
   mark failed; `refunded` → mark refunded and release the seats.
5. Always 200 once recorded — a retried delivery must not be re-processed.

URL: `https://<project-ref>.supabase.co/functions/v1/moyasar-webhook`

---

## Swift

**Dependency:** `https://github.com/moyasar/moyasar-ios-sdk`, exact version 3.2.3.
iOS 13+ and Arabic-localized out of the box, which matters for an Arabic-only app.

**`Sirr/core/payment/MoyasarPaymentService.swift`** — async/await, `Logger`, typed
result enums, matching `ManualPaymentService`'s shape. Two calls: `createPayment` and
`verifyPayment`, both via `client.functions.invoke`.

**`Sirr/core/payment/MoyasarPaymentModels.swift`** — request/response DTOs and a
`CardPaymentState` enum with exactly the four states asked for: `processing`,
`success`, `failed(reason)`, `cancelled`.

**`Sirr/Components/CardPaymentSheet.swift`** — wraps the SDK's `CreditCardView` plus
an Apple Pay button, following the existing `STCPaySheet` presentation.

The app never writes payment state. On `.completed` it calls `verifyPayment` and
renders whatever the server says; a local `.paid` from the SDK is treated as
"authorized, pending verification" and nothing more.

**Payment method selection:** `PaymentMethodSelectionSheet` gains a card option,
shown only when `create-payment` reports a verified recipient.

---

## Apple Pay

The project has **no** Apple Pay configuration today — `Sirr/Sirr.entitlements` has
only `aps-environment`, `associated-domains` and `applesignin`.

Code and entitlement will be written in this branch, but **cannot be built or tested
until the manual steps below are done**. The merchant identifier is read from a build
setting; no value is guessed or hardcoded.

Manual steps, for `PAYMENT_SETUP.md`:

1. **Apple Developer** — Certificates, Identifiers & Profiles → Identifiers →
   Merchant IDs → create (suggested `merchant.com.businessech.tmrin`). Then enable
   the Apple Pay Payment Processing capability on App ID `com.businessech.tmrin`.
2. **Moyasar Dashboard** — generate a CSR, upload it, download the payment
   processing certificate, and install it against the Merchant ID.
3. **Xcode** — add the Apple Pay capability to the `Sirr` target and select the
   Merchant ID. This writes `com.apple.developer.in-app-payments` into
   `Sirr.entitlements`.
4. The staging bundle id `com.businessech.tmrin.staging` needs the Merchant ID added
   to its App ID too, or Apple Pay silently no-ops in staging builds.

`supportedNetworks` will be `[.visa, .masterCard, .mada]`; `merchantCapabilities`
`[.capability3DS, .capabilityCredit, .capabilityDebit]`.

---

## Secrets

Supabase secrets only. Nothing in Swift, nothing in `Config/*.xcconfig`, nothing in
git.

```
MOYASAR_SECRET_KEY        sk_test_… / sk_live_…   never leaves the Edge Function
MOYASAR_PUBLISHABLE_KEY   pk_test_… / pk_live_…   returned to the app at request time
MOYASAR_WEBHOOK_SECRET    self-chosen, pasted into the Moyasar dashboard
```

A `supabase/functions/.env.example` documents the names with empty values.

Both Supabase projects need their own set: sandbox `kpcdinxusxycenfnitjc` gets test
keys, production `hzsxwnmbdkrmipjtfzlp` gets live keys. Because the publishable key
comes from the server, a Debug build automatically talks to Moyasar test mode and a
Release build to live — the same guarantee `SupabaseEnvironment` already provides.

---

## Error handling

| Case | Behaviour |
|---|---|
| No network | SDK surfaces it; sheet shows retry. The `payments` row stays `pending` and is reconciled by the webhook or the next verify. |
| `create-payment` fails | No Moyasar call is made. Nothing to clean up. |
| Authorization fails / declined | Payment marked `failed` with Moyasar's message. Seats untouched. |
| User cancels the sheet | `cancelled`. The `pending` row is left for the sweep; no seat changes. |
| Session expired | 401 from the function; app refreshes the Supabase session and retries once. |
| Duplicate webhook | Primary-key conflict on `moyasar_webhook_events` → 200, no re-settle. |
| Unknown `moyasar_payment_id` in a webhook | Recorded, logged, 200. Never creates a payment row from a webhook. |
| Paying an already-paid event | `create-payment` returns `already_paid` before contacting Moyasar. |
| **Amount tampered on the device** | `verify-payment` finds the mismatch and **voids**. No capture, no seat, no refund needed. |
| Recipient tampered on the device | Same — the split recipient is compared to the workspace's verified recipient, and mismatch voids. |
| Authorized but never verified (app killed mid-flow) | The webhook settles it. If neither arrives, the authorization expires on Moyasar's side and the hold is released. |

---

## Testing

Moyasar test mode throughout. SQL tests follow the existing `supabase/tests/` pattern.

**SQL (pgTAP):**
1. `authenticated` cannot insert, update or delete a `payments` row — RLS denies it.
2. `settle_payment()` is not executable by `authenticated`.
3. `settle_payment()` called twice settles once (idempotent).
4. A webhook id inserted twice conflicts.
5. A payer sees only their own payments; a workspace owner sees their workspace's.

**Edge Function (Deno via Docker, per the existing setup):**
6. `create-payment` ignores any amount supplied in the body.
7. `create-payment` refuses a workspace with no verified recipient.
8. `create-payment` refuses an already-paid event.
9. `verify-payment` voids on amount mismatch and does not confirm the seat.
10. `verify-payment` voids on recipient mismatch.
11. `moyasar-webhook` rejects a wrong `secret_token`.
12. `moyasar-webhook` is idempotent across a replayed delivery.

**Manual, on device (per the project's build-check-then-hand-over rule):**
13. Successful card payment → seat confirmed.
14. Failed card (Moyasar's declined test card) → clear failure, no seat.
15. Cancelled sheet → cancelled state, no seat.
16. Airplane mode mid-payment → recovers via webhook.

---

## Files

**New**
```
supabase/migrations/2026090613xxxx_moyasar_payments.sql
supabase/functions/create-payment/index.ts
supabase/functions/verify-payment/index.ts
supabase/functions/moyasar-webhook/index.ts
supabase/functions/_shared/moyasar.ts          API client + amount assertions
supabase/functions/.env.example
supabase/tests/moyasar_payments_test.sql
Sirr/core/payment/MoyasarPaymentService.swift
Sirr/core/payment/MoyasarPaymentModels.swift
Sirr/Components/CardPaymentSheet.swift
PAYMENT_SETUP.md
```

**Changed**
```
supabase/config.toml                  three [functions.*] blocks
Sirr/Components/PaymentMethodSelectionSheet.swift   card option
Sirr/Sirr.entitlements                in-app-payments (Apple Pay)
Sirr.xcodeproj/project.pbxproj        SPM dependency + capability
Config/Base.xcconfig                  APPLE_PAY_MERCHANT_ID (empty until step 1)
```

`project.pbxproj` is normally never committed here. Adding an SPM dependency and a
capability cannot avoid touching it, so that edit is called out for review rather
than folded in silently.

---

## Risks

**Splits are not enabled yet.** The docs state splits need merchant enablement and an
entity created after October 2025. Everything here is built and testable without
them — a workspace with no verified recipient simply gets the manual flow — but no
card payment can reach a real organizer until Moyasar enables it on the account.

**Organizers need a CR or a freelance license.** Now established from Moyasar's own
FAQ, not assumed: a merchant account requires a Saudi CR *or* a freelance license,
plus a Saudi commercial bank account linked to it. Individuals qualify only through
the freelance-license route. Most Tamrin organizers have neither, so card payment
will reach a small minority of workspaces until that changes — which is the strongest
argument for keeping manual transfer as the default rather than a fallback.

**Recipient onboarding is manual.** No API creates a splits recipient. Rows in
`workspace_moyasar_recipients` will be entered by an operator from an id Moyasar
provides, so the design must not assume a self-serve onboarding flow inside the app.

**Splits + manual authorization is unconfirmed.** If they turn out not to compose,
the fallback is server-created invoices: `create-payment` calls `POST /v1/invoices`
with the secret key and returns the hosted URL, which the app opens in
`ASWebAuthenticationSession`. Slightly worse UX, identical security, and the
database, webhook and `settle_payment` layers are unchanged. This is why the design
keeps Moyasar's API surface behind `_shared/moyasar.ts`.

**Apple Pay ships unverified.** Written this branch, per the decision to build both
now, but it cannot compile against a real Merchant ID until the manual steps are
done. It will be marked clearly as untested in the PR.
