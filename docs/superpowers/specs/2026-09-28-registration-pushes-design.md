# Registration Pushes — Design

**Date:** 2026-09-28
**Status:** Awaiting review by Naif
**Source:** Requested directly: "each user register send to the organizer notification, and each quarter notify everyone in group"
**Branch:** `feat/registration-pushes` (off `staging`)
**Builds on:** `2026-08-27-event-fill-notifications-design.md`

## Summary

Today an organizer hears about their session only at fill milestones (25 / 50 / 75 / 100 %), and nobody else in the group hears anything. This spec adds two things:

1. **Every registration notifies the organizer**, by name, once per tap.
2. **Fill milestones reach the whole group**, not only the organizer.

This spec reverses one decision in the 2026-08-27 spec, which kept "telling the whole group" out of scope.

Everything is server-side. The App Store build gets it without a release.

## Confirmed product decisions

| Decision | Choice |
|---|---|
| Registration push audience | The event's owner (`events.creator_id`) |
| Registration push wording | Names the player: «فهد سجّل في تمرين الخميس» |
| Guests | **One push per tap**: self, self + guests, or guests only is a single push |
| Milestone audience | **Everyone in the group** (`workspace_members`), registered or not |
| Tap that crosses a milestone | Organizer gets **one combined push**: «فهد سجّل في … . نص المقاعد انحجزت 🔥» |
| Whoever crossed the milestone | Does not get the milestone push; they just did it |
| Organizer's own actions | No push to the organizer (as today); the group still gets the milestone |
| Waitlist joins | **No push.** A waitlist row takes no seat |
| Seats carried by the weekly roll-over | No registration push, no group milestone; the organizer still gets the milestone alone, as today |
| Milestone thresholds and "once, ever" rule | Unchanged from 2026-08-27 |

## Where it fires

The existing deferred constraint trigger `trg_announce_event_fill` on `event_participants`, via its function `public.announce_event_fill()`. It already runs:

- **after every insert**, whichever of the eight insert paths made it,
- **deferred to commit**, so when it runs the tap's roster is final: `register_event_seat` inserts the member and then the guests in separate statements, and deferral sees both.

No RPC changes. A path added later notifies for free, which is why the 2026-08-27 design chose a trigger.

## Logic

`announce_event_fill()` is rewritten. Within one transaction it can fire once per inserted row, so every part must be safe to repeat.

```
v_uid   := auth.uid()                -- the actor; null for cron / system
v_event := the event, locked for update

if not published or cancelled: mark this event's unannounced seats; return

-- Part 1: what did this tap add? (only when a person acted, and not the owner)
if v_uid is not null and v_uid <> creator:
    v_self   := exists unannounced seat where user_id = v_uid
                      and status in (pending, confirmed)
    v_guests := count unannounced seats where user_id is null and added_by = v_uid
                      and status in (pending, confirmed)
mark every unannounced seat of this event as announced     -- always

-- Part 2: milestone (only with a cap), exactly as today
if max_participants is not null:
    v_milestone := highest threshold passed and not yet announced
    if found: set fill_notified_pct = v_milestone

-- Part 3: organizer (never when the organizer is the actor)
if v_uid is distinct from creator:
    if v_self:
        enqueue member_registered for creator (actor_id, guest_count = v_guests, fill_pct = v_milestone)
    elsif v_guests > 0:
        enqueue member_added_guests for creator (actor_id, guest_count = v_guests, fill_pct = v_milestone)
    elsif v_milestone:
        enqueue event_fill_* / event_full for creator        -- today's behaviour

-- Part 4: group
if v_milestone and v_uid is not null:
    enqueue event_fill_* / event_full for every workspace member
    except v_uid and except creator
```

### How "this tap" is found

Each seat carries `registration_announced`. New seats start `false`, and the first trigger run in a transaction reads them, then marks every unannounced seat of the event `true`.

- **One push per tap:** the later runs in the same transaction find nothing unannounced, so they enqueue nothing.
- **Only this tap's seats:** the event row is locked `for update` and the trigger is deferred to commit. So when it runs, the unannounced seats are exactly the ones this transaction inserted.
- **Seats nobody should be told about are still marked:** that covers the organizer's own seats, the weekly roll-over, and draft events. A member's carried-over seat therefore can't be swept into their next tap later and reported as a fresh registration.

A timestamp such as `created_at = now()` was considered and rejected. It fails whenever two taps share a transaction, which is exactly how the SQL suites run.

### Why the registration push no longer needs a cap

Today the function returns early when `max_participants is null`, because there is no percentage without a cap. A session without a cap still has registrations, so only the milestone part (Part 2) now depends on the cap.

### Edge cases

| Case | Result |
|---|---|
| Joining the waitlist | Goes to `event_waitlist`, not `event_participants`: the trigger never runs |
| Re-registering after a withdrawal | A new insert, so a new push. The milestone does not re-arm |
| `already_joined` | No insert, so the trigger never runs |
| Organizer adds a player by hand | Actor is the owner: no organizer push, the group gets any milestone |
| Waitlist promotion | Inserts the promoted player's seat under the actor who freed it. It's neither the actor's own seat nor their guest, so it's marked with no registration push. The milestone logic is unchanged |
| Draft (unpublished) or skipped event | Nothing, as today |

## Data model

The push queue gains three nullable columns. Existing rows and types are unaffected.

```sql
alter table public.push_outbox
  add column if not exists actor_id uuid references auth.users(id) on delete set null,
  add column if not exists guest_count smallint,
  add column if not exists fill_pct smallint;
```

Seats gain the "already told" flag. Existing seats start `true`, so the first tap after the migration doesn't report seats taken before it. The default then flips to `false` for new seats.

```sql
alter table public.event_participants
  add column if not exists registration_announced boolean not null default true;
alter table public.event_participants
  alter column registration_announced set default false;
```

`actor_id` is `on delete set null`, so deleting the actor's account keeps the organizer's push row.

## Copy (`send-push`)

`index.ts` reads the whole row (`select("*")`) instead of naming columns, so it works before and after the migration adds the new ones. When `actor_id` is set, it reads `public.users.name` for it; a missing name falls back to «لاعب». `copyFor(type, eventName, details?)` gains an optional third argument, so every existing call keeps working.

Two new types, both titled «تسجيل جديد ⚽». There are two because the text depends on whether the player took their own seat:

| Type | guest_count | Body |
|---|---|---|
| `member_registered` | 0 | «فهد سجّل في {event}» |
| `member_registered` | n | «فهد سجّل ومعه {guests} في {event}» |
| `member_added_guests` | n | «فهد سجّل {guests} في {event}» |

Guest count, in Arabic-Indic digits like the existing «٣ أرباع»: 1 → «ضيف», 2 → «ضيفين», 3–10 → «٣ ضيوف», 11 and up → «١١ ضيف».

Milestone suffix, appended when `fill_pct` is set:

| fill_pct | Suffix |
|---|---|
| 25 | «. ربع المقاعد انحجزت» |
| 50 | «. نص المقاعد انحجزت 🔥» |
| 75 | «. باقي ربع المقاعد ⏳» |
| 100 | « واكتمل العدد 🎉» |

The group receives the existing `event_fill_25/50/75` and `event_full` copy unchanged. No em dashes in any of it, per the rule at the top of `copy.ts`.

## Testing

**SQL** (`supabase/tests/registration_pushes_test.sql`), on a workspace with an owner and several members, asserting `push_outbox` rows after each step:

1. A member registers alone: one `member_registered` row to the owner, `guest_count = 0`.
2. A member registers with 2 guests: still exactly one row to the owner, `guest_count = 2`.
3. A member who already holds a seat adds guests only: one `member_added_guests` row. Their earlier seat is already announced, so it doesn't count.
4. A tap crossing 50 %: the owner gets one `member_registered` row with `fill_pct = 50` and no separate `event_fill_50`. Every other member gets `event_fill_50`, the actor doesn't.
5. The owner registers or adds a player by hand: no row to the owner, and the group gets any milestone.
6. A waitlist join on a full event: no rows.
7. An event without a cap: a registration push, no milestone.
8. A system insert (no `auth.uid()`) crossing a milestone: the owner gets `event_fill_*` alone and the group gets nothing. When that member later adds a guest, it reads as `member_added_guests`, because their carried seat was marked.

The existing `event_fill_notifications_test.sql` must keep passing where its expectations still hold. The places that assert "owner only" or no push to the owner get updated to the new rules.

**Deno** (`send-push/copy_test.ts`): each body shape, each guest count bracket (1, 2, 3, 10, 11), each suffix, and the missing-name fallback.

## Rollout

Order matters, on each project: **deploy `send-push` first, then apply the migration.**

- The new function reads `select("*")` and treats the new fields as optional, so it runs fine before the columns exist.
- The reverse order would let `member_registered` rows reach the old function, which has no copy for them and records them as failed.

1. Sandbox: deploy `send-push`, apply the migration, check on device.
2. Prod: the same two steps.

Known side effect: prod users hold 2–4 device tokens each (open push-token issue), so a group-wide push may land more than once on some phones. It isn't fixed here.

## Out of scope

- A push to the organizer for waitlist joins.
- Letting a member mute group milestones.
- Showing these in an in-app notification list.
