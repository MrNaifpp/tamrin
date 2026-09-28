# An unpaid workout blocks registering until it is paid

Date: 2026-09-29
Branch: `feat/moyasar-payments`

## Why

Today an unpaid seat is forgiven 24 hours after its workout starts
(`waive_expired_event_debts`, run by the per-minute recurring job). The unpaid
workout disappears from home, and the member can go on booking without ever
paying. With card and Apple Pay payments in place, a member can always pay from
the app, so nothing justifies forgiving the debt any more.

The new rule: **a debt stays until it is paid, and while it stays, the member
cannot register for another workout in the same group.** They still see every
workout. The refusal comes when they try to register, with a clear message and a
way to pay.

A registration block existed before and was removed on 2026-08-30
(`20260830200000_drop_previous_payment_gate.sql`). It trapped people: the error
reached them as raw English, and the unpaid workout was not on their home page,
so they could neither pay nor book. This design fixes both: the error is Arabic,
and the unpaid workout stays on home with its pay button.

## Decisions

| Question | Decision |
| --- | --- |
| Which debts block? | Any unpaid seat on an **ended** workout in the **same workspace**. Other workspaces are not affected. |
| Whose seats count? | The member's own seat and every guest they added. |
| Declared transfers? | The declare-then-confirm flow is retired. A seat is paid or unpaid; an organizer who received money directly uses «وصلتني القطة». |
| "Ask the organizer" | Text only in the error sheet. No button, no notification. |
| Old forgiven debts | Stay forgiven (`waived`). The rule applies from now on. |
| Old unanswered declarations | Marked `waived` once, so they do not suddenly block anyone. |
| Waitlist promotion | A member who owes is skipped; the seat goes to the next person. |
| Promotion notification | On a paid workout it reminds the member to pay. |

## Definition of a debt

One helper decides it everywhere, so the block, the home page and the waitlist
can never disagree:

```
public.unpaid_debt_event(p_workspace_id uuid, p_user_id uuid) returns uuid
```

It returns the id of the member's oldest unpaid ended workout in that workspace,
or null. A row counts when all of these hold:

- `event_participants.payment_status = 'pending'`
- the row is the member's own (`user_id = p_user_id`) or a guest they added
  (`user_id is null and added_by = p_user_id`)
- the event belongs to `p_workspace_id`
- the event is not cancelled (`cancelled_at is null`)
- the event has ended (`coalesce(end_date, start_date) < now()`)

`payment_declared_at` is deliberately not part of it. `confirmed`, `rejected` and
`waived` rows never count. The function is `security definer`, `stable`, and
executable only by `postgres`/`service_role` (callers are other definer
functions).

## Server changes (one migration)

### 1. Debts stop expiring

- The recurring job wrapper stops calling `waive_expired_event_debts()`. The
  function is left in place, unused, so the change can be undone with one line.
- One-time cleanup in the same migration: every `pending` row on an ended,
  non-cancelled event with `payment_declared_at is not null` becomes `waived`.
  These are old "I transferred" claims nobody answered.
- The `waived` status keeps its meaning (forgiven under the old rule). After this
  migration nothing writes it.

### 2. The block

`guard_event_registration_insert` gains one rule, placed after the existing
membership and "event has ended" checks:

- The payer is `new.user_id` on `event_waitlist`, otherwise
  `coalesce(new.user_id, new.added_by)`.
- Skip the rule when the payer is the workspace owner or the event's creator.
  This also keeps organizer-added players (`add_manual_participant`) working.
- Otherwise, if `unpaid_debt_event(v_event.workspace_id, payer)` is not null,
  raise:
  - `message`: `عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل.`
  - `hint`: `payment_owed:<unpaid event id>`, the tag the app matches on and
    the workout it opens. It rides in `hint`, not `detail`: PostgREST sends
    `details` while supabase-swift's `PostgrestError` decodes `detail`, so a
    `detail` value never reaches the app.

Because the trigger fires on every insert into `event_participants` and
`event_waitlist`, one rule covers self-registration, adding guests
(`register_event_guest_batch_impl`, guest-only batches) and joining the waitlist
(`register_event_seat` inserts into `event_waitlist` when the workout is full).

### 3. The stale guest-request refusal goes

The same trigger refuses self-registration while an unpaid guest-only batch
exists («Pending guest request must be resolved before self registration»). It
belongs to the retired declare-then-confirm flow and is removed. Paying covers
the member and their guests together, so there is nothing to wait for.

### 4. Every workout is shown

`get_workspace_events` stops hiding the next occurrence of a series from a member
who owes for an earlier one (the `not exists (… debt …)` clause added in
`20260831130000_hold_next_until_debt_clears.sql`). Its `requires_payment_action`
column and the clause that keeps an unpaid ended workout in the list both switch
to the helper's definition (dropping `payment_declared_at is null`), so the
workout that blocks is always the workout on home. `get_my_feed` calls
`get_workspace_events`, so it follows.

### 5. Waitlist promotion skips debtors

`promote_from_waitlist` picks the earliest waiter for whom
`unpaid_debt_event(workspace, user)` is null, instead of the earliest waiter. A
skipped member stays on the waitlist, in their place. Without this, the new rule
would raise inside `drain_waitlist` and fail the action that freed the seat (for
example another member's withdrawal).

### 6. The promotion notification reminds to pay

`promote_from_waitlist` writes `waitlist_promoted_unpaid` instead of
`waitlist_promoted` when the workout is paid (`total_price > 0`). New copy in
`send-push/copy.ts`:

- title: `لاعب اعتذر، أنت في القائمة✨`
- body: `انضممت إلى القائمة الرئيسية في {eventName}. لا تنسَ تدفع القطة 💳`

A free workout keeps `waitlist_promoted` and its current copy.

## App changes

### 1. Home

No change. `DesignerHomeView` already keeps a past workout on home while
`requiresPaymentAction` is true, and `EventDetailView` already shows its pay
control (`overduePaymentCTA`). The workout disappeared only because the debt was
forgiven.

### 2. Recognising the refusal

`RegistrationOutcome` gains `case paymentOwed(eventId: UUID)`. Every feed
function that registers (self-registration, adding guests, joining the waitlist)
checks the caught error: a `PostgrestError` whose `hint` is `payment_owed:`
followed by a UUID becomes `.paymentOwed`. Anything else keeps its
current handling. The Swift compiler lists every `switch` over the outcome that
must handle the new case.

### 3. The sheet

All three paths run inside `RegistrationFlowSheet`, so the refusal is a new
step of that sheet (like its existing `closedAtCapacity` step), not a second
sheet on top:

- title: «عليك قطة سابقة»
- body: «ما دفعت قطتك في {اسم التمرين}. ادفعها عشان تقدر تسجّل.»
- note: «إذا حوّلت للمنظم مباشرة، اطلب منه يأكد إنه وصلته.»
- primary button «ادفع الآن»: closes the sheet and opens the unpaid workout's
  detail screen, where its Apple Pay button is. Home presents workouts with
  `fullScreenCover(item:)`; setting that item to the unpaid workout replaces the
  open one, which is SwiftUI's documented behaviour for an item change.
- secondary button «لاحقاً»: dismisses.

The workout's name comes from the feed's loaded occurrences by id. If it is not
loaded, the feed reloads once; if it is still missing, the body drops the name
(«ما دفعت قطتك في تمرين سابق…») and «ادفع الآن» returns to home, where the
unpaid workout is listed.

## Testing

Database tests in `supabase/tests`, run on the local copy:

- A member who owes cannot register, add guests, or join the waitlist in the same
  workspace. The error carries the Arabic message, `hint = payment_owed` and the
  hint `payment_owed:<unpaid event id>`.
- Another workspace is unaffected. A cancelled unpaid workout does not count. The
  workspace owner and the event creator are never blocked. An organizer-added
  player is still inserted as `confirmed`.
- After a card payment settles, or the organizer confirms, registration works at
  once.
- Nothing is waived after 24 hours any more.
- The one-time cleanup waives only ended, non-cancelled, declared `pending` rows.
- Promotion skips a waiter who owes, promotes the next one, and the withdrawal
  that freed the seat succeeds. The skipped waiter is still on the waitlist.
- A paid workout's promotion writes `waitlist_promoted_unpaid`; a free one writes
  `waitlist_promoted`.
- A member with an unpaid guest-only batch can register themselves.
- `get_workspace_events` shows the next occurrence to a member who owes, and
  `requires_payment_action` matches the helper.
- Existing suites updated: `recurring_payment_gate_test.sql` (the hold and the
  "no block" probe flip to "shown" and "blocked"), `linger_unpaid_occurrence_test.sql`
  (next week is shown while owed), `merge_guests_and_waitlist_test.sql` (a paid
  promotion writes `waitlist_promoted_unpaid`), and
  `register_event_guest_only_test.sql` (the removed refusal).
  `waive_expired_event_debts_test.sql` stays as it is: the function is kept and
  still waives when called directly; the new test asserts the job no longer
  calls it.

Edge Function test: `copy_test.ts` covers `waitlist_promoted_unpaid`.

App: build check, then Naif tests on device: owe for a workout, try to register
for another in the same group, see the sheet, tap «ادفع الآن», pay, register.

## Rollout

1. Migration to the sandbox (`supabase db push` against `kpcdinxusxycenfnitjc`),
   `send-push` redeployed there.
2. Device test on a sandbox-pinned build.
3. Production only with the rest of the payments branch.

**Warning for production:** the block is server-side, so it reaches every
installed build the moment the migration lands. Old builds show the Arabic
message as plain text, without the sheet or «ادفع الآن». They do keep the unpaid
workout on home with its pay button, so a member is never left without a way to
pay.

## Out of scope

- Organizer marking a seat unpaid (see the organizer payment controls item).
- Reopening debts already waived.
- A notification or button for "ask the organizer".
- Blocking across workspaces.
