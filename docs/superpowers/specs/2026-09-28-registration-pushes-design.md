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

if not published or cancelled: return

-- Part 1: what did this tap add? (only when a person acted, and not the owner)
if v_uid is not null and v_uid <> creator:
    v_self   := exists seat where user_id = v_uid
                      and created_at = now() and status in (pending, confirmed)
    v_guests := count seats where user_id is null and added_by = v_uid
                      and created_at = now() and status in (pending, confirmed)

-- Part 2: milestone (only with a cap), exactly as today
if max_participants is not null:
    v_milestone := highest threshold passed and not yet announced
    if found: set fill_notified_pct = v_milestone

-- Part 3: organizer (never when the organizer is the actor)
if v_uid is distinct from creator:
    if Part 1 ran and (v_self or v_guests > 0)
       and no member_registered row for (creator, event, actor) with created_at = now():
        enqueue member_registered for creator (actor_id, guest_count, fill_pct = v_milestone)
    elsif v_milestone:
        enqueue event_fill_* / event_full for creator        -- today's behaviour

-- Part 4: group
if v_milestone and v_uid is not null:
    enqueue event_fill_* / event_full for every workspace member
    except v_uid and except creator
```

### Why `created_at = now()` means "this tap"

`now()` is the transaction's start time, and both `event_participants.created_at` and `push_outbox.created_at` default to it. So every seat one tap inserts has the same timestamp, and seats from other transactions don't. The same equality dedupes Part 3: the first run enqueues the organizer's push, and later runs in the same transaction find it and skip.

### Why the registration push no longer needs a cap

Today the function returns early when `max_participants is null`, because there is no percentage without a cap. A session without a cap still has registrations, so only the milestone part (Part 2) now depends on the cap.

### Edge cases

| Case | Result |
|---|---|
| Waitlisted insert | Not counted in Part 1 (status `waitlisted`), never counted as a seat |
| Re-registering after a withdrawal | A new insert, so a new push. The milestone does not re-arm |
| `already_joined` | No insert, so the trigger never runs |
| Organizer adds a player by hand | Actor is the owner: no organizer push, the group gets any milestone |
| Waitlist promotion | An update, not an insert, so no trigger. Unchanged |
| Draft (unpublished) or skipped event | Nothing, as today |

## Data model

The push queue gains three nullable columns. Existing rows and types are unaffected.

```sql
alter table public.push_outbox
  add column if not exists actor_id uuid references auth.users(id) on delete set null,
  add column if not exists guest_count smallint,
  add column if not exists fill_pct smallint;
```

`actor_id` is `on delete set null`, so deleting the actor's account keeps the organizer's push row.

## Copy (`send-push`)

`index.ts` reads the whole row (`select("*")`) instead of naming columns, so it works before and after the migration adds the new ones. When `actor_id` is set, it reads `public.users.name` for it; a missing name falls back to «لاعب». `copyFor(type, eventName, details?)` gains an optional third argument, so every existing call keeps working.

New type `member_registered`, title «تسجيل جديد ⚽». The body is built from three parts:

| Part | Wording |
|---|---|
| Self only | «فهد سجّل في {event}» |
| Self + guests | «فهد سجّل ومعه {guests} في {event}» |
| Guests only | «فهد سجّل {guests} في {event}» |

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
3. A member who already holds a seat adds guests only: one row with `guest_count` set. Their earlier seat is from another transaction, so it doesn't count as part of this tap.
4. A tap crossing 50 %: the owner gets one `member_registered` row with `fill_pct = 50` and no separate `event_fill_50`. Every other member gets `event_fill_50`, the actor doesn't.
5. The owner registers or adds a player by hand: no row to the owner, and the group gets any milestone.
6. A waitlist join: no rows.
7. An event without a cap: a registration push, no milestone.
8. A system insert (no `auth.uid()`) crossing a milestone: the owner gets `event_fill_*` alone and the group gets nothing.

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
