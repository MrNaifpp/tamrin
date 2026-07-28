# Pre-Test Flow Fixes — Design

**Date:** 2026-06-28
**Status:** Draft (awaiting review)
**Branch:** phase_1

## Context

Preparing the Tamrin (تمرين) app for its first round of real testers. A flow
review surfaced four items to address before handing the app out. The payment
**gateway** (real money movement + automatic payment matching) is explicitly
**out of scope** — it will be built later. Until then, the existing manual STC
Pay confirm flow stays in place. All events are **paid**; there is no free-event
path in the product.

## Goals

1. Stop ended events from cluttering the list.
2. Make end time a required, validated field at event creation.
3. Ship Apple-only sign-in (remove the dead Google button).
4. Let a joiner register friends alongside themselves ("بسجل معي أحد").
5. Send a twice-daily reminder to confirmed joiners about upcoming events.

## Non-Goals

- Payment gateway / automatic payment-to-joiner matching (deferred).
- Event "Settings" gear action (design exists, implementation deferred).
- Realtime updates to participant status (still poll-on-appear).

---

## Feature 1 — Hide ended events + require end time

### Problem
`EventService.getEventsForCurrentUser()` fetches every event the user is in,
ordered by `start_date`, with **no date filter**. Worse, `EventData.from(record:)`
converts `start_date` into a display `String` and discards the real `Date`, so
the client cannot even tell which events are in the past.

### Design
- **iOS model (`EventData.swift`):** carry the real `startDate: Date` and
  `endDate: Date?` through from `EventRecord` (keep the formatted `date` string
  for display). `EventRecord` already decodes both.
- **List filter (`EventPageView` / `loadEvents`):** after fetch, drop any event
  where `coalesce(endDate, startDate) < now`. Client-side keeps the two-path
  (creator + participant) query untouched. The `coalesce` is defensive for any
  legacy rows with a null `end_date`; new events always have one.
- **Create form (`NewEventView`):** end time becomes a **required** field.
  Validation: end must be present and strictly after start; the create button
  stays disabled until satisfied.

### Why client-side filter
The fetch combines two queries (events created + events joined) and sorts in
Swift. A single client-side filter is simpler and lower-risk than adding a
`gte` predicate to both server queries.

---

## Feature 2 — Apple-only sign-in

Remove the disabled Google ("قريباً") button from `LoginOnbord.swift` and make
the Apple Sign-In button full-width in its place. No backend impact. Apple
Sign-In remains the sole social provider, plus the existing email/OTP path.

---

## Feature 3 — Add friends as a participant list (guests)

### Decision
When a joiner adds friends, each friend becomes its **own row** in
`event_participants` (a list), not a single aggregated row. This keeps
seat-counting as a plain `count(*)`.

### Data model (`event_participants` migration)
- `user_id` → **nullable** (guests have no account).
- add `guest_name text` (null for real users).
- add `added_by uuid references auth.users(id)` (the paying joiner who owns the
  guest row; null for self rows / equals self).
- replace `unique (event_id, user_id)` with a **partial unique index**:
  `unique (event_id, user_id) where user_id is not null` — allows multiple guest
  rows (null user_id) per event while still preventing a real user from joining
  twice.

### RPC changes (`stcpay_rpcs` migration)
- **`submit_payment`** gains a `p_guest_names text[]` param (default `'{}'`).
  Within the existing `for update` lock on the event row:
  - seat check uses group size: `current_seats + 1 + array_length(guests) <= max`,
    else return `seats_full`.
  - insert the self row (`user_id = p_user_id`) **plus one row per guest**
    (`user_id = null`, `guest_name = g`, `added_by = p_user_id`), all
    `payment_status = 'pending'` with the same `paid_to_number` snapshot.
  - return `creator_id`, `paid_to_number`, and `group_size` so the client can
    show `price × group_size`.
- **`confirm_payment` / `reject_payment` / `cancel_pending`** operate on the
  joiner's whole group: all rows where `event_id = ?` and
  (`user_id = joiner` **or** `added_by = joiner`). Confirm flips them all to
  `confirmed`; reject/cancel deletes them all and frees those seats (existing
  waitlist-notify path then applies to the freed seats).

### iOS changes
- **`STCPaySheet`:** amount = `pricePerPerson × group_size`.
- **`EnrollmentSheetView` (`EventHeroDetailView.swift`):** the locally collected
  friend names (currently discarded in `handleEnroll`) are passed into
  `submitPayment` as `guestNames`.
- **`STCPayService.submitPayment`:** add `guestNames: [String]` param; surface
  `group_size` in `SubmitPaymentResult.submitted`.
- **`ParticipantRecord` / participant list:** add `guestName` and `addedBy`;
  render guest rows nested under (or tagged with) the joiner who added them.

### RLS
Reads are already covered (creator sees all participants for their events;
joiners see their own rows). Writes go through `security definer` RPCs, so the
RPC owns the multi-row insert/delete. Keep a delete policy allowing a user to
remove rows where `added_by = auth.uid()` for direct guest removal if needed.

---

## Feature 4 — Twice-daily "upcoming events" reminder

### Decision
A 4-hour-precise reminder is incompatible with a twice-daily cron, so this is a
**twice-daily upcoming-events reminder** instead. Each run notifies confirmed
joiners of events starting before the next run.

### Schedule
- Add **pg_cron** (extension not currently used; available on hosted Supabase).
- Two runs/day spaced **exactly 12h apart** — **08:00 and 20:00 Asia/Riyadh**
  (UTC+3, no DST), i.e. `05:00` and `17:00` UTC cron entries. A 12h spacing +
  12h look-ahead window tiles the day with no gaps, so no event is missed
  between runs.

### Logic (`enqueue_event_reminders()` SQL function, `security definer`)
- Add `reminder_sent_at timestamptz` to `events` for dedup.
- Each run selects events where:
  - `start_date > now()` and `start_date <= now() + interval '12 hours'`
    (12h look-ahead; with 12h run spacing every upcoming event is caught), and
  - `reminder_sent_at is null`, and
  - the event has at least one `confirmed` participant.
- For each such event, insert one `push_outbox` row per **confirmed** participant
  with a real `user_id` (guests excluded — no device), then set
  `reminder_sent_at = now()`.
- The existing `push_outbox` insert trigger fans out to `send-push` — no Edge
  Function changes needed beyond a new notification copy/type
  (e.g. `event_reminder`).

### Why dedup via `reminder_sent_at`
Overlapping windows between the two daily runs could otherwise double-send;
stamping the event once guarantees a single reminder per event.

---

## Migrations Summary

1. `*_event_participants_guests.sql` — nullable `user_id`, add `guest_name`,
   `added_by`; swap unique constraint for partial unique index.
2. `*_stcpay_rpcs_guests.sql` — update `submit_payment`, `confirm_payment`,
   `reject_payment`, `cancel_pending` for groups.
3. `*_events_reminder.sql` — add `reminder_sent_at`; create
   `enqueue_event_reminders()`; enable `pg_cron`; schedule two daily jobs.

## Testing

- **Hide/end-time:** create an event with a past end → absent from list; create
  with end before start → blocked; in-progress event (started, not ended) →
  still visible.
- **Apple-only:** Google button gone; Apple button works end-to-end.
- **Guests:** add 2 friends → 3 pending rows, amount = price×3, seat count
  reflects 3; creator confirm → all 3 confirmed; reject → all 3 removed and
  seats freed (waitlist notified). Seat cap respected when group would overflow.
- **Reminder:** event starting within window with a confirmed joiner → one push,
  `reminder_sent_at` stamped; second cron run → no duplicate; pending-only joiner
  → no push; guest rows → no push.

## Deferred / Open

- Payment gateway + automatic matching (Feature #4 from the flow review).
- Event Settings gear action.
- Realtime participant-status updates.
