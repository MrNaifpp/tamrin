# Fill Milestone Notifications — Design

**Date:** 2026-08-27
**Status:** Awaiting review by Naif
**Source:** Requested directly — "each 1/4 of the event fill tell the owner"
**Branch:** `feat/event-fill-notifications`

## Summary

An organizer publishes a session and then has no idea how it is going without opening the app and counting. This spec tells them, unprompted, each time their session crosses a quarter of its capacity — and when it fills.

Nothing notifies on capacity today. The eleven push types in `send-push/copy.ts` cover money, reminders, invitations, waitlist promotion and withdrawals; none of them says anything about how full a session is.

## Confirmed product decisions

| Decision | Choice |
|---|---|
| Audience | The event's **owner only** (`events.creator_id`) |
| Milestones | 25 / 50 / 75 / 100 percent of `max_participants` |
| Small sessions | Below 8 seats, only **50 and 100** announce |
| Repeats | **Never.** Each milestone announces once for the life of the event |
| Withdrawal then rejoin | Silent. The mark is a high-water mark and never decreases |
| Owner fills the seats themselves | **Silent**, but the milestone is still spent |
| Telling the whole group at 75% | **Out of scope.** `remind_event_members` already does this on a button |

### Why "once, ever"

The alternative — re-arming a milestone when the roster drops below it — lets one indecisive player produce an unbounded number of identical notifications by joining and leaving. A high-water mark costs one `smallint` and removes the failure mode entirely.

### Why small sessions differ

On a 4-seat session a quarter is one player, so quarters would mean a notification per join. Halving the milestone set below 8 seats keeps the feature meaningful at both ends: the organizer of a 4-a-side game hears *نص العدد* and *اكتمل*, and the organizer of a 20-player session hears all four.

### Why the owner's own actions are silent

An organizer adding five players by hand with «تسجيل لاعب يدويًا» does not need their own phone to tell them the session is now half full. The milestone is still marked as spent, so it cannot fire later when an unrelated player joins — the organizer would receive news they had already acted on.

## Data model

One column on `events`, following the `reminder_sent_at` / `register_reminder_sent_at` / `payment_reminder_sent_at` precedent already there:

```sql
alter table public.events
  add column if not exists fill_notified_pct smallint not null default 0;

comment on column public.events.fill_notified_pct is
  'High-water mark of the fill milestone already announced to the owner: 0, 25, 50, 75 or 100. Never decreases, so a withdrawal cannot re-arm a milestone.';
```

## Where it fires

Eight functions insert into `event_participants`:

```
add_manual_participant      promote_from_waitlist
create_event                register_event_guest_batch_impl
generate_recurring_events   register_event_seat
join_event                  submit_payment_v2_before_guest_only
```

The check is therefore a **trigger**, not a call added to each of them:

```sql
create trigger trg_announce_event_fill
  after insert on public.event_participants
  referencing new table as new_rows
  for each statement
  execute function public.announce_event_fill();
```

Two reasons for the trigger over eight call sites. It cannot be forgotten by the ninth path added later — the failure mode that produced both guest bugs in this same sprint, where `20260820100000_pay_after_registering` converted some call sites and missed the guest one. And `event_participants` already carries `trg_guard_event_participant_insert`, so this follows an established pattern rather than inventing one.

**Statement-level with a transition table**, because guests insert as a batch. A row-level trigger would re-evaluate the roster once per guest and could announce two milestones for a single five-guest request.

## Logic

`public.announce_event_fill()` — `security definer`, `search_path = public`. For each distinct `event_id` in `new_rows`:

1. `select * from events where id = ... for update` — the lock is what makes the high-water mark safe against two players registering at once.
2. Return without acting if `published_at is null`, `cancelled_at is not null`, or `max_participants is null`. No capacity means no percentage.
3. Count seats:
   ```sql
   select count(*) from event_participants
   where event_id = ... and payment_status in ('pending', 'confirmed')
   ```
   This matches every other capacity check in the schema. Waitlist rows live in `event_waitlist` and are excluded naturally.
4. `v_pct := floor(v_seated * 100 / v_capacity)`
5. Choose the **highest** milestone that is `<= v_pct` and `> fill_notified_pct`, from `{25,50,75,100}` when capacity `>= 8`, otherwise `{50,100}`. If there is none, stop.
6. `update events set fill_notified_pct = <that milestone>`.
7. If `auth.uid() is distinct from creator_id`, insert one `push_outbox` row for `creator_id`.

Step 5 taking the highest is what makes a batch jumping 40% → 80% announce 75% once rather than 50% and 75% together. Step 6 running before step 7's condition is what makes an owner-caused crossing spend the milestone silently.

`auth.uid()` is null under `generate_recurring_events` when it runs from a scheduled context. That is not the owner, so the branch behaves correctly — but those events are unpublished at creation and stop at step 2 regardless.

## Copy

`push_outbox` carries only `(user_id, type, event_id)`, and `copyFor(type, eventName)` receives nothing further, so the percentage cannot travel as data. It lives in the type name instead — which keeps the existing one-type-one-copy shape and needs no change to `push_outbox` or `send-push/index.ts`.

Four cases added to `send-push/copy.ts`:

| Type | Title | Body |
|---|---|---|
| `event_fill_25` | التمرين بدأ يمتلئ ⚽ | ربع مقاعد {name} انحجزت |
| `event_fill_50` | نص العدد اكتمل 🔥 | نص مقاعد {name} انحجزت |
| `event_fill_75` | ٣ أرباع المقاعد راحت ⏳ | {name} قارب يكتمل — باقي ربع المقاعد |
| `event_full` | اكتمل العدد 🎉 | امتلأت مقاعد {name} |

`event_fill_25` and `event_fill_75` are simply never enqueued for sessions under 8 seats.

**This wording is unconfirmed** and should be corrected during review — it was written to match the existing voice, not supplied by the product owner.

## Testing

`supabase/tests/event_fill_notifications_test.sql`, in the style of the existing suite — one transaction, fixtures, `raise exception` on failure, `rollback` at the end:

| Case | Expectation |
|---|---|
| 16-seat session filling one at a time | `event_fill_25`, `_50`, `_75`, `event_full`, each exactly once |
| 4-seat session filling one at a time | `event_fill_50` and `event_full` only |
| Five guests taking a session from 40% to 80% | `event_fill_75` only — not `_50` as well |
| Player withdraws below 50%, another joins back over it | No second `event_fill_50` |
| Owner adds players manually across a milestone | No push, but `fill_notified_pct` advances |
| A later player crosses a milestone the owner already spent | Still silent |
| `max_participants is null` | Nothing enqueued |
| Unpublished or cancelled session | Nothing enqueued |

`copy_test.ts` gains a case per new type, matching the existing `payment_submitted` test.

## Out of scope

- **Telling the workspace at 75%.** `remind_event_members(p_kind => 'register')` already notifies every member without a seat, rate-limited to once an hour. Firing it automatically would duplicate a control the organizer already has.
- **Any in-app UI.** This is push only; the event page already shows the roster count.
- **Milestones on the way down.** Nothing announces a session emptying out.
- **Owner preferences.** No per-event or per-workspace setting for which milestones announce; the capacity-based rule is fixed.

## Known adjacent defect (not fixed here)

`send-push/copy.ts` has duplicate `case` labels for `waitlist_promoted` and `member_declined` — the second pair is unreachable dead code. Worth a separate cleanup; touching it here would mix concerns.
