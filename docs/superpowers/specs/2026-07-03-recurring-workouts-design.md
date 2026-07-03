# Recurring Workouts (F1) — Design

**Date:** 2026-07-03
**Status:** Draft (roadmap approved; spec awaiting review)
**Source:** `docs/ROADMAP.md` — Phase 2, F1

## Summary

Most groups play the same field, same day, same price, every week — but today the organizer recreates the workout by hand each time. This feature adds **recurrence templates**: creating a workout with "يتكرر" stores a template, and a scheduled job materializes the next occurrence as a normal `events` row a few days ahead, notifying all workspace members that registration is open. Occurrences are ordinary events — everything downstream (join, STC Pay, guests, waitlist, reminders) is untouched.

Confirmed product decisions:

| Decision | Choice |
|---|---|
| Recurrence options | لا يتكرر / أسبوعي / كل أسبوعين (v1) |
| Occurrence shape | A normal `events` row linked by `template_id`; fresh participant list each time |
| Lead time | Next occurrence created **4 days** before start (per-template `lead_days`, no v1 UI to change it) |
| Announcement | One push to every workspace member when an occurrence opens (new outbox type) |
| Series controls | On the event detail page of a template-linked event, creator-only: تخطَّ الأسبوع القادم / إنهاء التكرار |
| Template editing | Not in v1 — to change price/time/field, end the series and create a new recurring workout |
| History | Skipping or ending a series never deletes existing events |

## Data model

**New table `event_templates`:**

| column | type | notes |
|---|---|---|
| `id` | uuid PK | |
| `workspace_id` | uuid NOT NULL → workspaces (cascade) | |
| `creator_id` | uuid NOT NULL → auth.users | series owner; occurrences copy it |
| `name`, `location`, `description`, `image_url` | text | copied to each occurrence |
| `latitude`, `longitude` | double precision NULL | |
| `total_price`, `price_per_person` | as on `events` | |
| `max_participants` | int NULL | |
| `duration_minutes` | int NULL | derived from first event's `end_date - start_date`; NULL if no end date |
| `recurrence` | text NOT NULL check in ('weekly','biweekly') | |
| `next_occurrence_at` | timestamptz NOT NULL | the single source of truth for "when is the next one" |
| `lead_days` | int NOT NULL default 4 | occurrence is created when `now() >= next_occurrence_at - lead_days` |
| `skip_next` | boolean NOT NULL default false | one-shot flag consumed by the generator |
| `ended_at` | timestamptz NULL | set by إنهاء التكرار; generator ignores ended templates |
| `created_at` | timestamptz | |

**`events`:** add `template_id` uuid NULL → event_templates (**on delete set null**), indexed. Deleting a template stops future generation but keeps all generated events (criterion: history preserved).

**RLS:** SELECT for workspace members via the existing `is_workspace_member()` helper; mutations RPC-only, matching the codebase pattern.

## Generation job

`generate_recurring_events()` — SECURITY DEFINER, run by pg_cron **daily at 05:00 UTC** (08:00 Riyadh, same slot as the AM reminder job). For each template where `ended_at IS NULL` and `now() >= next_occurrence_at - (lead_days || ' days')::interval`:

1. If `skip_next` is true → advance `next_occurrence_at` by the recurrence interval, reset `skip_next`, **do not** create an event, continue.
2. Otherwise insert an `events` row copying the template fields (`start_date = next_occurrence_at`, `end_date = start + duration` when known, `template_id` set), and insert the creator as a confirmed participant — same as `create_event` does today.
3. Enqueue one `push_outbox` row of new type **`event_opened`** per workspace member except the creator (copy: "انفتح التسجيل 🎾" / "انفتح التسجيل لتمرين {eventName} — احجز مكانك"). Reuses the existing outbox → pg_net trigger → `send-push` pipeline; only `copy.ts` gains a case.
4. Advance `next_occurrence_at` by the interval — in the **same transaction** as the insert, which is what makes a double cron run idempotent (the second run finds `next_occurrence_at` already past the lead window).

Catch-up rule: if a template is somehow far behind (e.g. cron was down), the loop advances `next_occurrence_at` until it is in the future but creates **at most one** event per run — no burst of stale workouts.

## RPCs

All SECURITY DEFINER, workspace-membership-guarded like the July 2 batch.

| RPC | access | behavior |
|---|---|---|
| `create_event(...)` — extended | member | gains `p_recurrence text default 'none'`. When weekly/biweekly: also insert the template (deriving `next_occurrence_at = p_start_date + interval`, duration from the dates) and stamp the first event's `template_id`. One transaction. |
| `get_event_template(p_template_id)` | member | template row + its recurrence state (drives the series section on event detail) |
| `skip_next_occurrence(p_template_id)` | series creator | set `skip_next = true`; returns the date that will be skipped. If the next occurrence's event **already exists** (we're inside the lead window), returns `already_open` and does nothing — the creator deletes that event instead (existing `delete_event`). |
| `end_recurrence(p_template_id)` | series creator | set `ended_at = now()`; existing events untouched |

`delete_event` is unchanged — deleting one occurrence never touches the template (the `template_id` FK just dangles onto other rows).

## iOS app

- **`NewEventView`**: a segmented control under the date pickers — **لا يتكرر / أسبوعي / كل أسبوعين**. Passed to `create_event`. No other new inputs (lead time stays at the default).
- **`EventHeroDetailView`**: when the event has a `template_id` and the viewer is the series creator, show a **سلسلة متكررة** section: recurrence label + next date, and two actions — "تخطَّ الأسبوع القادم" (confirmation dialog; handles the `already_open` answer by pointing at deletion) and "إنهاء التكرار" (destructive confirmation; ends the series, keeps this event).
- **Feed card** (`EventPageView`): a small "يتكرر أسبوعيًا / كل أسبوعين" badge on template-linked events.
- **Push tap** for `event_opened` deep-links to the new event — the existing `sirr://event/{id}` route, no new client routing.
- **`EventService`**: three new methods mirroring the RPCs; `EventRecord`/`EventData` gain `templateId`.

## Testing

- **SQL tests** (pattern of `tests/workspaces_test.sql`): generator idempotency (run twice → one event, `next_occurrence_at` advanced once); skip consumes the flag and creates nothing; ended templates generate nothing; catch-up creates at most one event; outbox rows created for members only (not the creator, not other workspaces); RLS — non-members cannot select templates; `skip_next_occurrence`/`end_recurrence` reject non-creators; `create_event` with recurrence writes template + stamps `template_id` atomically.
- **Manual device pass** (per testing convention: build-check only, hand over to Naif): create a weekly paid workout → verify template row → run the generator manually (`select generate_recurring_events()`) with a shortened lead → next occurrence appears in feed with badge → members receive the push → skip + end flows.

## Rollout

One migration batch (table + RLS + RPCs + cron job + generator) plus the app changes, on `phase_1`. The cron job is additive; nothing existing changes behavior. `copy.ts` gains the `event_opened` case with a unit test alongside `copy_test.ts`.

## Out of scope (future)

- Editing a template in place (price/time/field changes mid-series)
- Monthly or custom recurrence rules; multiple sessions per week per template
- Per-template lead-time UI
- Auto-carrying last week's confirmed players into the new occurrence
- A "series" management screen listing all templates in a workspace
