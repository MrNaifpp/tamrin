# STC Pay Manual Confirmation — Design

**Status:** Approved, ready for implementation plan
**Date:** 2026-06-16
**Owner:** @MrNaifpp

## Context

Sirr currently uses Apple Pay (`Sirr/core/payment/PaymentService.swift`) for paid event joins. The integration is a sandbox stub — `paymentAuthorizationController(_:didAuthorizePayment:handler:)` marks every authorization as success without forwarding the token to a real gateway. No money moves.

For the first deployable release we are replacing this with a **manual STC Pay flow with creator-side confirmation**. The joiner sends money outside the app via STC Pay; the event creator confirms in-app that the money arrived. This avoids the cost and compliance burden of a payment gateway while still giving creators a reliable way to collect for paid events.

## Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Who confirms a payment | Event creator (decentralized; no admin override) |
| 2 | Source of the STC Pay number | User profile (one-time setup) |
| 3 | Proof submitted by joiner | None — joiner just taps "أرسلت المبلغ" |
| 4 | Seat reservation timing | Held immediately as `pending` on submit |
| 5 | Apple Pay code | Removed completely (`PaymentService.swift` deleted) |
| 6 | Notifications | In-app status + APNs push |
| 7 | Guardrail for creators without STC Pay number | Block creation of paid events until number is set |
| 8 | Overflow behavior when seats are full | Waitlist; push all waiters when a seat opens, first to pay wins |

Explicit non-decisions (out of scope for v1): refunds in-app, disputes/chat, multiple STC Pay numbers per creator, screenshot proof upload, admin override, auto-expire on pending requests, rejection history tracking.

## Data Model

### `users` table — additions

```sql
alter table public.users
  add column if not exists stc_pay_number text;
-- Normalized to +9665XXXXXXXX on save. Validated against ^(\+9665|05)\d{8}$.
```

### `event_participants` table — additions

```sql
alter table public.event_participants
  add column if not exists payment_status text not null default 'confirmed'
    check (payment_status in ('pending', 'confirmed', 'rejected')),
  add column if not exists paid_to_number text;
-- paid_to_number is a snapshot of the creator's stc_pay_number at submit time,
-- so the creator's pending inbox shows the number the joiner actually paid to
-- even if the creator's profile number changes later.
```

`payment_status` accounting:
- Free events (`price_per_person = 0`) insert with `'confirmed'`.
- Paid events insert with `'pending'`.
- `'pending'` and `'confirmed'` both count toward `max_participants`. Seats are held immediately.
- `'rejected'` rows are deleted (not retained). Joiner can submit again.

### New table — `event_waitlist`

```sql
create table public.event_waitlist (
  event_id uuid references public.events(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
```

### New table — `device_tokens`

```sql
create table public.device_tokens (
  user_id uuid references auth.users(id) on delete cascade,
  apns_token text not null,
  platform text not null default 'ios',
  updated_at timestamptz not null default now(),
  primary key (user_id, apns_token)
);
```

### RPCs

All run with `security definer`, `set search_path = public`.

**`submit_payment(p_event_id, p_user_id)`** — paid-event join path.
- Acquires `select count(*) ... for update` on `event_participants` for the event.
- If `count >= max_participants`: returns `{ status: 'seats_full' }` so the client can route to the waitlist sheet.
- If the user already has a row for this event: returns `{ status: 'already_joined' }`.
- Reads `users.stc_pay_number` for the event's creator. If null: returns `{ status: 'creator_missing_number' }` (defensive; the guardrail at event-creation time should make this unreachable).
- Inserts `event_participants` row with `payment_status='pending'` and `paid_to_number=<creator's number>`.
- Returns `{ status: 'submitted' }`. The Swift client then fires a push to the creator.

**`confirm_payment(p_event_id, p_user_id, p_creator_id)`**
- Validates `p_creator_id` equals `events.creator_id`. Raises otherwise.
- Updates the matching `event_participants` row from `'pending'` to `'confirmed'`.
- Returns `boolean`. Client fires push to joiner on success.

**`reject_payment(p_event_id, p_user_id, p_creator_id)`** — creator-initiated rejection.
- Same authorization check (`p_creator_id` must equal `events.creator_id`).
- Deletes the matching pending row.
- After the delete, runs the seat-freed waitlist push: selects all `event_waitlist` rows for this event and returns the user list to the client. The client iterates and sends pushes via the Edge Function.
- Returns the list of waitlist `user_id`s for the client to notify.

**`cancel_pending(p_event_id, p_user_id)`** — joiner-initiated self-cancel.
- Authorizes by row ownership: deletes only where `event_participants.user_id = p_user_id` AND `payment_status = 'pending'`. No-op if the row was already confirmed (a joiner can't cancel a confirmed seat through this path — they `leave_event` instead).
- Same waitlist push behavior as `reject_payment`.
- Returns the list of waitlist `user_id`s for the client to notify.

**`join_waitlist(p_event_id, p_user_id)`**
- Inserts into `event_waitlist`. Idempotent (primary key collision → no-op).

**`leave_waitlist(p_event_id, p_user_id)`**
- Deletes from `event_waitlist`.

**Existing `leave_event(p_event_id, p_user_id)`** — extend to also return the waitlist user list (same pattern as `reject_payment`), so the client can push waiters that a seat opened.

### Migration order

Each concern in its own file, all additive:

1. `20260616100000_add_stc_pay_number_to_users.sql`
2. `20260616200000_add_payment_status_to_participants.sql`
3. `20260616300000_create_event_waitlist.sql`
4. `20260616400000_create_device_tokens.sql`
5. `20260616500000_stcpay_rpcs.sql` — all new + modified RPCs

## Screens & Flows

### A. Profile — STC Pay number setup
New section in the profile screen: **"رقم STC Pay"** with an input field and Save button. Saudi mobile validation on submit. Normalize to `+9665XXXXXXXX`. Editable anytime.

### B. Event creation — guardrail
`NewEventView`: when `price_per_person > 0` and Save is tapped, if `users.stc_pay_number IS NULL` → present a bottom sheet **"أضف رقم STC Pay لاستلام المدفوعات"** with inline input. Save is blocked until the number is provided. Once provided, the event saves normally.

### C. Joiner — paid event detail
`EventHeroDetailView` and `SharedEventView`: the existing "ادفع وانضم — Apple Pay" button is replaced with **"ادفع عبر STC Pay"**.

Tap behavior:
- Call `submit_payment` (single round trip). The RPC handles the seat-cap check atomically.
- On `submitted`: open a confirmation sheet showing creator's STC Pay number (large, with copy-to-clipboard button) and the SAR amount. Single primary action: **"أرسلت المبلغ"** — this just dismisses the sheet. The pending row has already been written; the sheet is informational.
- On `seats_full`: sheet flips to a waitlist sheet — message **"المقاعد ممتلئة"** with primary action **"انضم لقائمة الانتظار"**. Tap calls `join_waitlist`.
- On `already_joined`: no-op + toast.
- On `creator_missing_number`: toast **"صاحب الحدث لم يضف رقم STC Pay بعد"** (defensive).

After submission, the event-detail button changes to a yellow pill **"بانتظار تأكيد صاحب الحدث"** with a secondary link **"إلغاء الطلب"**. Tapping "إلغاء الطلب" calls `cancel_pending` (joiner self-cancel RPC, separate from creator's `reject_payment` so the auth model is unambiguous).

### D. Creator — pending requests inbox
On the creator's event card (their own events list) and on the event detail when viewed as creator: a badge **"N طلبات بانتظار التأكيد"** when `pending > 0`.

Tap → sheet listing each pending joiner: display name (from `users.name`), submitted-at time, `paid_to_number` shown small under the name. Two actions per row: **"تأكيد"** (green primary) and **"رفض"** (red secondary). Confirmations are not undoable in v1 (no "unconfirm" — keeps the audit story simple).

### E. Joiner — after confirmation
- Push: **"تم تأكيد دفعتك لحدث {event_name}"**.
- Event card / detail shows green pill **"مؤكد"**.
- Joiner can `leave_event` like any confirmed participant.

### F. Joiner — after rejection
- Push: **"تم رفض الدفعة لحدث {event_name}"**.
- Seat freed. Joiner can submit again if they want. Out-of-band communication is on the joiner and creator.

### G. Waitlist — seat opens
When `leave_event`, `reject_payment`, or `cancel_pending` succeeds and the resulting seat count is below `max_participants`:
- RPC returns the list of waiter `user_id`s.
- Swift client iterates and calls the `send-push` Edge Function with payload **"مقعد متاح في {event_name} — اضغط للدفع"** + deep-link to the event detail.
- All waiters see the same prompt. First to tap → `submit_payment` → wins. Losers get **"امتلأت المقاعد"** toast and remain on the waitlist for the next opening.
- The winner's `event_waitlist` row is removed atomically inside `submit_payment`.

## Push Notifications

- Add the **Push Notifications** capability + `UserNotifications` framework to the Sirr target.
- Register for remote notifications in `SirrApp.init` (or post-sign-in in `AppState`), upsert `apns_token` into `device_tokens` on every successful registration.
- APNs auth key: `AuthKey.p8` already in the repo. Wire it into the Edge Function as a Supabase secret (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_AUTH_KEY`).
- New Supabase Edge Function `send-push`:
  - Input: `{ user_id, title, body, data }`.
  - Fetches `apns_token` from `device_tokens`.
  - Builds JWT signed with APNs key, POSTs to APNs HTTP/2 endpoint.
  - Returns success/failure.
- Push triggers (called from Swift after the relevant RPC returns):
  - `submit_payment` → push to creator: **"طلب دفع جديد لحدث {event_name}"**.
  - `confirm_payment` → push to joiner: **"تم تأكيد دفعتك لحدث {event_name}"**.
  - `reject_payment` → push to joiner: **"تم رفض الدفعة لحدث {event_name}"**, then push to all waiters: **"مقعد متاح في {event_name}"**.
  - `cancel_pending` (joiner self-cancel) → push to all waiters.
  - `leave_event` (confirmed user leaving) → push to all waiters.

Pushes are fire-and-forget; failures are logged via `Logger(subsystem: ..., category: "STCPay")` but do not block the UI.

## Validation & Errors

- STC Pay number regex: `^(\+9665|05)\d{8}$`. Normalize to `+9665XXXXXXXX` on save (strip leading 0, prepend `+966`).
- Reject empty/whitespace on save.
- All RPC errors surface as Arabic toasts; the existing toast pattern in the views is reused.

## Logging

`Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "STCPay")` — log:
- Every RPC call (event_id, user_id, result).
- Push send attempt + result.
- Validation failures on STC Pay number input.

## Code to Delete

- `Sirr/core/payment/PaymentService.swift` (the file)
- All `import PassKit` and `PaymentService` references in `SharedEventView.swift` and `EventHeroDetailView.swift`
- The `merchant.businessech.com.test` identifier and any Apple Pay entitlements in `Sirr.entitlements` and `Info.plist`

## Out of Scope (explicit YAGNI)

- Refunds initiated in-app (handled out-of-band between creator and joiner)
- Disputes / in-app chat
- Multiple STC Pay numbers per creator
- Screenshot upload as proof
- Admin (platform) override of creator decisions
- Auto-expire on pending requests
- Rejection history / abuse tracking
- "Unconfirm" — confirmations are terminal in v1
