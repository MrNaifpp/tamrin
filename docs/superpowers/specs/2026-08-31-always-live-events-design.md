# Always-live events and the 24-hour payment grace

Date: 2026-08-31
Status: approved, not yet implemented

## Why

Two problems, one design.

**The events cannot be published.** `cf5ae1e` rebuilt the poster card and deleted
its action bar — `actionBar`, `hasActions`, `ForEach(actions)`,
`EventPosterCardActionCell` and `EventActionPressStyle` all went. What survived
was the `actions` parameter and the `self.actions = actions` that stores it, so
`cardActions(for:)` still computes the whole list and hands it to a card that
draws none of it. A stored property that is assigned raises no warning, so
nothing failed and nothing was logged.

The only place that sets `publishConfirmation` is inside that dead list, at
`DesignerHomeView.swift:726`. The detail page never offered publishing. So there
is no way to publish an event in this version, and since a new event is created
as a draft that only its organizer can see, every event made in this version is
invisible to the group.

**The draft step is not wanted.** Rather than restore the publish button, the
draft state goes away: an event is live the moment it is created.

## Decisions

Draft and published are removed as a concept. Every event is live at creation,
and every event that becomes visible sends a push — including each weekly
rollover.

A member who has not declared payment is never blocked. The finished card lingers
on their home page for 24 hours from the event's start, and then the debt is
waived. Nothing in the app enforces payment; the organizer handles that with the
person.

## Behaviour

### Creating

Creating an event makes it live, invites every workspace member, and pushes them.
There is no state in which an event exists but the group cannot see it.

### The weekly rollover

For a Sunday 9–11pm weekly exercise:

| When | What happens |
|---|---|
| Sunday 11:00pm | Occurrence ends. Next Sunday opens for **everyone**, invited and pushed. |
| Sunday 11:00pm | The finished card leaves the home page of everyone who has settled. |
| Monday 9:00pm | For anyone who has not, the finished card leaves too, and the debt is waived. |

Both transitions ride the per-minute `recurring-events` cron, so each lands
within a minute of its time rather than exactly on it.

The deadline is `start_date + 24 hours`, not end + 24. A two-hour session and a
four-hour one both give the same 24 hours from kickoff, and the deadline is
predictable from the time the group already knows.

### The member who owes

Nothing is withheld. They receive next Sunday at 11pm with everyone else and can
register for it while still owing. The only difference on their screen is that
the finished card stays **above** the new one, carrying «دفع القطة».

That card is removed on whichever comes first:

- they declare payment — removed immediately, debt stands as declared
- `start_date + 24h` passes — removed, and `payment_status` becomes `waived`

"Not declared" is today's condition: `payment_status = 'pending'` and
`payment_declared_at is null`.

Guest rows are treated the same. A guest carries `user_id is null` and
`added_by = <member>`, and the member who brought them sees and owes for them,
so their rows waive on the same deadline.

### What is deliberately not enforced

A member can play every week, never pay, and be waived every Monday. The app
will not block, warn, or count. This is a deliberate reversal of today's
behaviour, where an undeclared payment excludes a member from the next
occurrence indefinitely, and it is the single largest behavioural change here.
The organizer is expected to deal with it by talking to the person or removing
them from the workspace.

## Server changes

**Remove.** `publish_event`. Its work moves into creation. Removing it also
retires the errors `Event is not published` and `Template is not published`, and
their Arabic messages at `ServerErrorMessage.swift:68` and `:138` — no event can
be in that state any more.

**Remove.** The debt gate inside `publish_recurring_event_internal`
(`20260829100000_roll_recurring_events_after_end.sql`, the `not exists` on
`debt_event` joined through `series_key`). Every member is invited to the next
occurrence unconditionally. `series_key` itself stays: it is what keeps an
occurrence attached to its series across a template edit, and the waiver still
needs to find the previous occurrence in the same series.

**Change.** `create_event` stamps `published_at = now()`, invites all workspace
members, and queues `event_invited` pushes — the invite half of what
`publish_event` used to do, minus the gate.

**Add.** A waiver step on the existing `recurring-events` cron, which
`20260829100000` reschedules to run every minute. For any occurrence whose
`start_date + 24h` has passed, every `pending` participant row with a null
`payment_declared_at` becomes `waived`. Riding the existing job means the
waiver lands within a minute of the deadline and adds no new schedule.

`payment_status` is currently constrained to `('pending', 'confirmed',
'rejected')` by `20260617200000_add_payment_status_to_participants.sql`, so the
check constraint has to be widened to admit `waived` before anything can write
it. Existing readers filter on `in ('pending', 'confirmed')`, so a waived row
drops out of the owed set without those queries changing.

The step is idempotent: it only ever moves `pending` to `waived`, so a re-run
finds nothing left to move.

**Keep.** The `published_at` column, always stamped at creation. Dropping it
would mean rewriting the RLS policies on `events` and `event_templates`,
`get_my_feed`, and the template visibility rules — a wide change for no
behavioural difference, because a column that is never null gates nothing. It
stays as a record of when the event was made.

## App changes

**Restore the action bar** in `EventPosterCard`. This is the fix for the
original bug and everything else here is invisible without it. The owner gets
تعديل, تخطي and حذف; a member gets registration, اعتذار and دفع القطة. Publish is
simply not in the list.

**Remove** the publish action from `cardActions(for:)`, the
`publishConfirmation` state and its sheet, `AdminPublishEventSheet`, and the
«منشور» / «نشر الموعد» tag states on the card.

**Remove** `EventService.publishEvent` and `MockHomeFeed.publish`.

**Keep the finished card in the shelf** while the member owes and the deadline
has not passed. Today a past occurrence is dropped from the upcoming shelf; it
now survives for that member under `requiresPaymentAction && now < start + 24h`,
sorted above the new occurrence.

## Testing

`supabase/tests/` already covers this area, and two of its files describe the
behaviour being removed. `recurring_payment_gate_test.sql` asserts that an
undeclared payment withholds the next occurrence — the exact rule this design
deletes, so it is rewritten to assert the opposite. `event_lifecycle_test.sql`
covers publication and loses its publish cases.

The rollover and the waiver are both time-dependent. The suite's existing
convention is to place events relative to `now()` and to move `start_date` /
`end_date` backwards to simulate a finished occurrence, rather than to wait or
to inject a clock; the new cases follow it.

- an event created is immediately visible to a member, and pushes them
- at end time the next occurrence opens for a settled member and for an owing one
- the finished card is present for an owing member at end + 1 minute, absent at
  start + 24h + 1 minute, and its rows read `waived`
- declaring payment during the window removes the card without waiting
- the waiver cron run twice changes nothing the second time
- a guest row added by an owing member waives with them
- an owing member can register for the next occurrence — the assertion that
  fails today

## Out of scope

Removing the `published_at` column. Any payment enforcement, warning, or
counter. The lineup's own publish (`publish_event_lineup`) is a different
feature and is untouched.

## Risks

The waiver destroys debt on a schedule. If the group later wants to know who
never paid, `waived` is the only trace, and it does not distinguish "forgiven
because the organizer agreed" from "forgiven because 24 hours passed". A
`waived_reason` would separate them; it is not in this design because nothing
reads it yet.
