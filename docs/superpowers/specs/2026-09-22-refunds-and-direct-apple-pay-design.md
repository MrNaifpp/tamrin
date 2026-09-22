# Refunds, and one tap to Apple Pay — design

**Status:** Awaiting review
**Date:** 2026-09-22
**Branch:** `feat/moyasar-payments`
**Builds on:** `docs/superpowers/specs/2026-09-06-moyasar-payments-design.md`

---

## Why

Card payment works end to end now, which creates a problem it did not have while
it was theoretical: money can arrive and there is no way to send it back. A
player who apologises and cannot come has paid for a seat they will not use, and
an organizer who cancels has collected for a workout that will not happen.

This adds refunds, and removes the payment-method chooser that card payment made
redundant.

## What this is not

Manual transfer is untouched. A bank transfer or STC Pay never passed through
Tamrin, so there is nothing to send back, and those stay a conversation between
the player and the organizer exactly as today. Everything here applies to card
and Apple Pay payments only.

---

## Decisions

| Question | Decision |
|---|---|
| Who approves a refund | Nobody. Card payment confirms itself, so the organizer's approval step does not exist here |
| When a withdrawal refunds | Any time before the workout starts. After it starts, withdrawing still frees the seat but returns nothing |
| Partial refunds | Supported. Removing one guest returns that seat's share |
| Who removes a guest | The player who added them. Today only the organizer can remove anyone |
| Organizer cancels | Everyone who paid by card is refunded in full, with no time window |
| Paying | Pressing pay opens Apple Pay directly, with no chooser in between |

---

## Verified facts

These are load-bearing. Everything below depends on them.

| Fact | Source |
|---|---|
| `POST /v1/payments/{id}/refund`, secret key | [Refund Payment](https://docs.moyasar.com/api/payments/05-refund-payment/) |
| Body `{"amount": N}` in halalas refunds partially; no body refunds in full | Refund Payment |
| A refund may not exceed the charged amount; for a captured payment the ceiling is the captured amount | Refund Payment |
| `ApiPayment` carries `refunded` (integer) and `refunded_at`, so Moyasar reports a cumulative refunded total | SDK `ApiPayment.swift` |
| A custom button that starts Apple Pay **must not** show the Apple Pay name or logo, and must not imitate the system button | [Apple Pay HIG](https://developer.apple.com/design/human-interface-guidelines/apple-pay) |
| The Apple Pay mark communicates availability; it does not initiate payment | Apple Pay HIG |
| `manual: true` yields `authorized` for Apple Pay | Confirmed on the sandbox, 2026-09-21 |

### Unverified — must not be depended on

1. **Whether Moyasar allows more than one partial refund against a payment.**
   Undocumented. The design never issues a second refund on an assumption: it
   tracks its own cumulative total and refuses to exceed the original amount, so
   a refusal from Moyasar surfaces as a failed refund row rather than a silent
   loss. Added to `docs/moyasar-support-questions.md`.
2. **What a payment's `status` becomes after a partial refund.** Undocumented.
   Nothing here branches on that status. The `refunded` integer is the truth.

---

## How the existing code constrains this

Three facts about today's code shape the whole design.

**`decline_event` deletes the seat rows.** It removes the caller's row and the
rows of the guests they added, records the reason, tells the organizer, and
drains the waitlist. Once those rows are gone, nothing connects the payment to
what it covered. So a refund must be computed and recorded **inside the same
transaction, before the delete**.

**`cancel_event_occurrence` does not delete seats.** It sets `cancelled_at` and
notifies. The roster survives, so refunding everyone is a straightforward sweep
of that event's paid payments.

**`remove_event_participant` is organizer-only.** A player cannot remove their
own guest today, so that capability is new.

There is also an established pattern for a database change that must reach an
Edge Function: `push_outbox` takes an insert, an `AFTER INSERT` trigger reads the
URL and shared secret from `vault.decrypted_secrets`, and `net.http_post` calls
the function. Refunds follow it exactly rather than inventing a second mechanism.

---

## The shape

```
player withdraws / removes a guest        organizer cancels
            │                                     │
            └──────────────┬──────────────────────┘
                           ▼
            one transaction in Postgres
              ├─ compute the amount from the seats, before deleting them
              ├─ insert refunds row (pending)
              └─ change the seats / cancel the event
                           │
                   AFTER INSERT trigger
                           ▼
            refund-payment  (holds the secret key)
              ├─ read the refunds row (amount comes from here, never a request)
              ├─ POST /v1/payments/{id}/refund  {"amount": …}
              └─ settle_refund()  ───────────────────► payments.refunded_amount
                           │
              moyasar-webhook (payment_refunded)
              └─ reconcile against Moyasar's cumulative `refunded`
```

The amount is computed in the database and read from the database. No request
body ever names a figure, exactly as with `begin_card_payment`.

---

## Database

### `refunds`

One row per refund attempt. Its existence is the instruction to issue one; its
status is the record of what happened.

```
id                  uuid pk default gen_random_uuid()
payment_id          uuid not null references public.payments(id) on delete cascade
event_id            uuid not null references public.events(id) on delete cascade
user_id             uuid not null references auth.users(id) on delete cascade
seats               int  not null check (seats > 0)
amount              int  not null check (amount > 0)        -- halalas
reason              text not null check (reason in ('withdrew','guest_removed','event_cancelled'))
status              text not null default 'pending'
                      check (status in ('pending','processing','done','failed'))
moyasar_payment_id  text not null
failure_code        text
failure_message     text
attempts            int  not null default 0
created_at          timestamptz not null default now()
updated_at          timestamptz not null default now()
```

RLS: the payer may `select` their own rows, and the workspace owner may select
their workspace's. **No insert, update or delete for `authenticated`.** Rows are
written by `security definer` functions and by service_role only.

### `payments` gains two columns

```
refunded_amount int not null default 0 check (refunded_amount >= 0)
refunded_seats  int not null default 0 check (refunded_seats  >= 0)

constraint payments_refund_within_amount check (refunded_amount <= amount)
constraint payments_refund_within_seats  check (refunded_seats  <= seat_count)
```

Both are cumulative. The two check constraints are what make "we cannot refund
more than was paid" true by construction rather than by careful coding.

**No new status value.** `payments.status` stays `paid` while a payment is
partially refunded, and becomes `refunded` only when `refunded_amount` reaches
`amount`. This falls out well: `begin_card_payment` refuses a second payment
while a `paid` row exists, which is right for someone who still holds seats, and
allows one again once they have been refunded in full.

### `settle_refund()`

`security definer`, service_role only. Takes a refund id, the status Moyasar
reported, and Moyasar's cumulative refunded total. In one transaction it marks
the refund `done` or `failed`, raises `payments.refunded_amount` and
`refunded_seats`, flips the payment to `refunded` when it is whole, and enqueues
a push to the payer. Returns early if the refund is already settled, so calling
it twice is safe.

### `request_refund()`

Internal, `security definer`, not granted to anyone. Takes a payment, a seat
count and an amount, guards the amount against what remains refundable, and
inserts the `refunds` row. The three trigger points call it rather than writing
the row themselves, so the guard exists once.

### `retry_pending_refunds()`

A refund is money we owe. If the trigger's HTTP call never lands, the row sits
`pending` and nothing else would ever notice, so a scheduled function re-fires
any refund still `pending` after a few minutes and under a small attempt ceiling.
It is the same arrangement `enqueue_event_reminders` already has, and it is what
makes the row rather than the HTTP call the source of truth.

### `remove_my_guest(p_participant_id uuid)` — new

The player-facing half of `remove_event_participant`. Asserts the caller added
that guest, that the row is a guest and not a manual entry, removes it, requests
a refund for that seat when the workout has not started and the seat was paid by
card, and drains the waitlist. Returns the same envelope shape as its
organizer-only sibling.

### `decline_event()` — changed

Before the delete, and only when `now() < events.start_date`, it groups the seats
about to be removed by their `payment_id` and requests a refund of each payment's
remaining amount. Seats with no `payment_id`, or whose payment is not `paid`, are
skipped silently: there is nothing to return.

After the start time the function behaves exactly as it does today. The seat is
freed and no money moves.

### `cancel_event_occurrence()` — changed

After setting `cancelled_at`, requests a full-remainder refund for every `paid`
payment on that event. No time window applies, because this is the organizer's
decision rather than the player's. Skipping a recurring occurrence is covered
automatically when it cancels the generated event.

### `settle_payment()` — changed

Its `refunded` branch today releases every seat the payment covered. That is
wrong once a refund can be partial. It becomes a reconciliation: compare
Moyasar's cumulative `refunded` against `payments.refunded_amount`, record any
difference we did not issue ourselves (a refund made from the Moyasar dashboard,
for instance), and release seats only when the payment is refunded in full.

---

## Edge Function

### `refund-payment` — `verify_jwt = false`

Called server to server by the trigger, carrying a shared secret in the
`Authorization` header, the same arrangement `send-push` already uses and for the
same reason: Postgres cannot present a Supabase JWT.

1. Compare the bearer token against `REFUND_PAYMENT_SECRET`; 401 otherwise.
2. Load the `refunds` row. Not `pending` means a duplicate delivery; acknowledge
   and stop.
3. Mark it `processing`, incrementing `attempts`.
4. `POST /v1/payments/{moyasar_payment_id}/refund` with `{"amount": …}` from the
   row, using the secret key.
5. Re-read the payment so the cumulative `refunded` total comes from Moyasar
   rather than from our arithmetic, then call `settle_refund()`.
6. Any failure marks the row `failed` with Moyasar's message and returns 200. The
   delivery is recorded, not retried into a loop.

Every boundary is labelled the way `verify-payment` now labels its own, so a
failure names where it happened instead of arriving as a bare 500.

---

## Swift

### The pay button

Pressing pay opens Apple Pay. Because that control now starts the transaction,
Apple's guidelines require it to be the **system** Apple Pay button: a custom
button that starts Apple Pay may not carry the Apple Pay name or logo, and may
not imitate the system one. Using the real button is also what puts the Apple
mark on it, which is what was asked for.

Three cases, in order:

- **Quote ready and Apple Pay available** — the system Apple Pay button replaces
  "دفع القطة". One tap opens Wallet. No chooser, no intermediate sheet.
- **Quote ready, no Apple Pay on the device** — the ordinary "ادفع بالبطاقة"
  button, with no Apple mark, opening the card form directly.
- **No quote** — the workspace takes no card, so the existing review sheet opens
  for manual transfer, exactly as today.

The quote is fetched when the detail screen appears for a member who owes money,
rather than when the review sheet opens, because the button's identity now
depends on it.

### Removing a guest

Guests a member added gain a remove action in the roster, calling
`remove_my_guest`. The confirmation says whether money comes back.

### Withdrawal copy

The withdrawal sheet states the outcome before the person commits: their money
returns, or it does not because the workout has started, or there is nothing to
return because they paid by transfer.

### Push copy

One new type, `refund_issued`, telling the payer the money is on its way back
and naming the workout.

---

## Error handling

| Case | Behaviour |
|---|---|
| Moyasar refuses a second partial refund | The row is `failed` with their message. Seats are already freed; the money is not. Surfaced to the organizer rather than swallowed |
| Refund would exceed what remains | `request_refund` refuses before any row is written. The check constraints are the backstop |
| Payment not `paid` (pending, failed, authorized) | No refund row. An uncaptured authorization expires on its own |
| Payment was manual | No refund row, and the withdrawal copy says so |
| Workout already started | Withdrawal still works, no refund row |
| `refund-payment` unreachable | The row stays `pending` and is retried by the sweep, so a failed HTTP call does not lose the refund |
| Duplicate trigger delivery | The row is no longer `pending`; acknowledged without a second refund |
| Refund issued from the Moyasar dashboard | The webhook reconciliation raises `refunded_amount` to match, so our books agree with theirs |
| Split already settled to the organizer | Moyasar refuses; the row is `failed` with the reason, and it is a commercial matter, not a code one |

---

## Testing

**SQL**

1. Declining before the start writes a refund row for the whole remaining amount.
2. Declining after the start writes none, and still frees the seat.
3. Removing one guest refunds exactly that seat's price, not a share of the total.
4. A second guest removal cannot push the cumulative refund past the amount paid.
5. Cancelling an event writes one full refund row per paid payment, and none for
   manual payers.
6. `settle_refund` is idempotent across a replay.
7. `settle_refund` marks the payment `refunded` only when the last halala is back.
8. `authenticated` cannot insert, update or delete a `refunds` row.
9. A payer sees only their own refunds; the workspace owner sees their workspace's.
10. `remove_my_guest` refuses a guest the caller did not add.

**Edge Function**

11. `refund-payment` sends the amount from the row and ignores any amount in the body.
12. A wrong shared secret is refused.
13. A Moyasar error marks the row `failed` and settles nothing.
14. A duplicate delivery does not issue a second refund.

**Manual, on device**

15. Pay, withdraw before the start, money returns and the seat frees.
16. Pay for self and two guests, remove one, only that share returns.
17. Organizer cancels, every card payer is refunded.
18. Withdraw after the start, seat frees, nothing returns, copy says so.
19. A device without Apple Pay gets the card form directly.

---

## Files

**New**
```
supabase/migrations/20260922100000_refunds.sql          table, columns, settle_refund
supabase/migrations/20260922110000_refund_triggers.sql  request_refund, the three
                                                        trigger points, the retry
                                                        sweep, and the reworked
                                                        settle_payment refund branch
supabase/tests/refunds_test.sql
supabase/functions/refund-payment/index.ts
supabase/functions/refund-payment/handler.ts
supabase/functions/refund-payment/handler_test.ts
```

**Changed**
```
supabase/functions/_shared/moyasar.ts          refund(); `refunded` on the payment type
supabase/functions/moyasar-webhook/handler.ts  reconcile cumulative refunds
supabase/functions/send-push/copy.ts           refund_issued
supabase/config.toml                           [functions.refund-payment]
Sirr/core/payment/MoyasarPaymentService.swift  quote fetched for the detail screen
Sirr/features/home/EventDetailView.swift       Apple Pay button, guest removal, copy
Sirr/features/home/MockHomeFeed.swift          removeMyGuest, refund-aware reload
Sirr/Components/ApplePayButton.swift           usable as the primary action
```

---

## Risks

**Multiple partial refunds are unproven.** If Moyasar allows only one refund per
payment, removing a second guest fails. The failure is visible and the money is
merely not returned, rather than lost, and the question is already on its way to
them. Fallback: refund the remainder in full and re-charge for the seats that
stay, which is worse UX and needs no schema change.

**A refund can outrun settlement.** Once splits are live and an organizer has
been paid out, reversing their share may fail. The row records the reason and it
becomes a commercial conversation. This is the same wall the original design
already documented.

**The chooser is going away for card workspaces.** Anyone who prefers a different
card than the one in Wallet loses a step they had. The card form is still one tap
further on, and Wallet itself offers card selection, so the loss is small.

**Nothing here helps manual payers.** The most common case today, a bank
transfer, still cannot be refunded by the app at all. That is worth saying out
loud rather than discovering later.
