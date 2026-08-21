# Capacity Policy + Waitlist Promotion (F2 core) — Design

**Date:** 2026-08-21
**Status:** Awaiting review by Naif
**Source:** `docs/ROADMAP.md` — Phase 2, F2 (partial: promotion only; RSVP for free events and the three-list organizer view are out of scope)
**Branch:** `feat/waiting-list`

## Summary

The create-session flow already asks the organizer to choose what happens when a session fills — **قائمة انتظار** or **يقفل عند الاكتمال** — and prints the promise *"ينضم من قائمة الانتظار تلقائيًا عند تحرر مكان."* under the picker. None of it is real. The choice is never saved, the waitlist is never shown, nobody is ever promoted, and the organizer is never told when a member withdraws.

This spec makes the picker mean something: persist the policy, enforce `closed`, surface the waiting list on the event detail page, and promote the first waiter automatically whenever a seat frees — server-side, in the same transaction that freed the seat.

### What is broken today

| # | Symptom | Cause |
|---|---|---|
| 1 | Organizer's capacity choice is discarded on save | `FeedCapacityPolicy` lives only in `MockHomeFeed.swift:19`; no column, no `createEvent` parameter, no `EventData` field. Real events are hardcoded back to `.waitlist` at `MockHomeFeed.swift:1522` and `:1572` |
| 2 | Full event's register button says "انضم لقائمة الانتظار" but joining fails | `EventDetailView.swift:497` flips the label, but the button still opens the register flow, which hits `submit_payment` → `seats_full` and stops. Only `SharedEventView` and `EventHeroDetailView` present `STCPayWaitlistSheet` |
| 3 | "X في قائمة الانتظار" never appears | `waitlistCount(for:)` counts roster rows with `.waitlisted`, but `get_event_participants_lifecycle_impl` selects only from `event_participants` and never reads `event_waitlist` |
| 4 | Nobody is promoted when a seat frees | `decline_event` returns `waiter_ids`, but `EventService.declineEvent` discards the RPC's return value entirely and fires no push |
| 5 | Organizer gets no notification when a member withdraws | `decline_event` enqueues nothing, while its neighbour `cancel_event_occurrence` uses `push_outbox` correctly 90 lines away |

### Confirmed product decisions

| Decision | Choice |
|---|---|
| Where the policy lives | Per session — on `events`, and on `event_templates` so weekly occurrences inherit it |
| Default | `waitlist`, in the DB and in the create flow (already the Swift default) |
| Promoted waiter's state | Inserted directly as **`confirmed`** — no hold window, no pending step, no expiry sweep |
| `pending` payment status | Being removed from the product later; **ignored** here. Seat counting uses `confirmed` only |
| Behaviour when full under `closed` | No waitlist offered. Register control becomes a locked state reading **قفل التسجيل** |
| Behaviour when full under `waitlist` | `STCPayWaitlistSheet` is presented, on every detail screen |
| Switching a live event to `closed` | Existing waiters are kept and still drained as seats free; only *new* waiters are blocked |
| Relationship to `registration_locked` | Untouched. The organizer's manual lock stays a separate control; `closed` never sets it |

### Accepted consequence

While manual STC Pay confirmation still exists, a promoted waiter becomes a confirmed participant **without having paid**. The organizer's money list and seat list will disagree for exactly those rows. This follows directly from promoting straight to `confirmed`, and is accepted because the payment-confirmation step is scheduled for removal.

## Data model

**`events`** and **`event_templates`** both gain:

| column | type | notes |
|---|---|---|
| `capacity_policy` | text NOT NULL default `'waitlist'` check in (`'waitlist'`, `'closed'`) | Column default backfills every existing row to `waitlist`, matching today's hardcoded client behaviour |

`event_waitlist` is unchanged — `joined_at` already provides queue order, and with no hold window there is nothing further to store.

The recurring-event generator copies `capacity_policy` from template to occurrence alongside the fields it already copies.

## Server

### `promote_from_waitlist(p_event_id uuid) returns uuid`

`security definer`. The **caller must already hold `select … for update` on the event row** — this is what serializes promotion against a concurrent `submit_payment`, reusing the locking discipline those RPCs already follow.

Returns the promoted `user_id`, or NULL when it declines to act. It no-ops when any of these hold:

- `registration_locked` is true, or `cancelled_at` is not null
- `max_participants` is null (uncapped — no seat can be "free")
- confirmed participants >= `max_participants` (no free seat)
- no rows in `event_waitlist` for this event

Note it does **not** check `capacity_policy`. `closed` prevents people *joining* the waitlist; it does not strand people already on one. An organizer who switches a live session to `closed` stops new waiters, and the existing queue still drains as seats free. A `closed` session that never had waiters has an empty list, so the helper no-ops on the last condition anyway.

Promotion does **not** touch payment methods. It never resolves a `workspace_payment_methods` row and never returns `payment_method_required`, so an organizer whose payment method was removed still gets their queue drained. The free-event branch of `submit_payment_v2` is the precedent: it already inserts a `confirmed` row carrying only `paid_price_per_person` and `payment_group_size`, with every `payment_method_id` / `paid_to_*` column left null. The promoted row has that same shape.

Otherwise it:

1. Selects the oldest `event_waitlist` row by `joined_at`
2. Inserts an `event_participants` row with `payment_status = 'confirmed'`, `paid_price_per_person = price_per_person` and `payment_group_size = 1`, leaving all payment-method columns null
3. Deletes that waitlist row
4. Enqueues `push_outbox (user_id, 'waitlist_promoted', event_id)`

### Call sites

Called in a **loop** — `while promote_from_waitlist(...) is not null` — at the end of every RPC that frees a seat:

- `decline_event`
- `leave_event`
- `cancel_pending`
- `reject_payment`
- `remove_event_participant`

The loop matters because a member leaving with guests they paid for frees several seats at once, and each should pull in a waiter. The no-op conditions terminate it.

Enqueueing inside the freeing transaction is deliberate: the existing client-fires-push pattern loses the notification whenever the withdrawing member's app is killed before the RPC returns.

### `decline_event` also notifies the organizer

Gains `insert into public.push_outbox (user_id, type, event_id) values (v_event.creator_id, 'member_declined', p_event_id)` — fixing symptom #5, using the pattern `cancel_event_occurrence` already establishes.

### `submit_payment_v2`

This is the live registration path (`workspace_payment_methods.sql:707`). The older `submit_payment` in `stcpay_rpcs.sql` survives only as a legacy shim for old clients and is not modified beyond keeping it consistent.

Two changes:

- The seat cap counts `payment_status = 'confirmed'` only, dropping `'pending'`. It stays **group-aware** — the existing test is `v_current_seats + v_group_size > max_participants`, because one registration can bring guests
- When the event is full and `capacity_policy = 'closed'`, return a distinct `'registration_closed_full'` status so the client can render قفل التسجيل rather than offering a waitlist that will never exist

### `join_waitlist`

Gains a guard: raises / returns a refusal when the event's `capacity_policy = 'closed'`, so the client's UI rule is enforced server-side too and cannot be bypassed by a stale screen.

### `get_event_participants_lifecycle_impl`

Unions `event_waitlist` rows into its result, carrying a `waitlisted` status and ordered by `joined_at` after the participant rows. The Swift roster type already understands `.waitlisted` — this is precisely what `waitlistCount(for:)` looks for and never finds — so no client decoding changes are required.

## Client

**Model / service:** `capacityPolicy` added to `EventData` and `EventRecord`, passed through `EventService.createEvent` and the recurring-template RPC wrapper. The hardcoded `.waitlist` at `MockHomeFeed.swift:1522` and `:1572` is deleted in favour of the decoded value.

**Create/edit flow:** the existing picker at `CreateTeamFlow.swift:828` now writes through to the DB. Default stays `.waitlist`. The policy is editable on a live session via the event settings sheet.

**Event detail (`EventDetailView`):** on a full session, present `STCPayWaitlistSheet` under `waitlist`, or a disabled control reading **قفل التسجيل** under `closed` — replacing today's dead end where the button opens a register flow that cannot succeed.

**Waiting list section:** the event detail page gets a **قائمة الانتظار** section, visually distinct from the confirmed roster, listing waiters in queue order with their position. Shown only when the policy is `waitlist` and the list is non-empty.

**Push:** `waitlist_promoted` ("تحرر مقعد وانضممت للتمرين") and `member_declined` ("اعتذر لاعب عن التمرين") are handled in the push router and deep-link to the event.

## Testing

SQL tests in `supabase/tests/`:

- The oldest waiter by `joined_at` is the one promoted
- `capacity_policy = 'closed'` refuses new `join_waitlist` calls, but waiters already queued from before the switch are still promoted when a seat frees
- Promotion never pushes confirmed count past `max_participants`
- Freeing N seats in one call promotes exactly N waiters, and stops when the list empties
- Two concurrent seat-frees cannot promote the same waiter twice (row lock holds)
- A promoted waiter's `event_waitlist` row is gone and their `event_participants` row is `confirmed`
- `decline_event` enqueues exactly one `member_declined` row addressed to the creator
- An uncapped event (`max_participants` null) never promotes

## Out of scope

RSVP commitment for free events, the three-list organizer view (مؤكدين / قائمة الانتظار / لم يردوا), splitting the twice-daily reminder push by response status, and reliability-weighted waitlist priority — all remain open in ROADMAP F2 and F9.
