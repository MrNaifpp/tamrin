# Tamrin 10x Roadmap — July 2026

**Status:** Proposal (awaiting approval)
**Baseline:** Phase 1 complete — private workspaces, paid workouts with manual STC Pay confirmation, guest rows, waitlist, seat caps, twice-daily reminder pushes, Apple/OTP auth. iOS-only, Arabic-only.

---

## The 10x thesis

Tamrin today solves *one instance* of the organizer's problem: "collect people and money for this workout." The 10x version solves the organizer's *recurring life*: the same group plays every week, the same people flake, the same money gets chased, and nothing accumulates between sessions.

Three compounding loops make the product 10x more valuable:

1. **The recurrence loop** — the workout recreates itself, invites itself, and reminds itself. The organizer's weekly work drops from ~30 minutes to ~0.
2. **The trust loop** — money and attendance become visible and accountable (ledger, receipts, reliability), so groups stop leaking to WhatsApp for disputes.
3. **The identity loop** — stats, streaks, teams, and MVP votes give players a reason to open the app *between* workouts, and shareable artifacts (lineups, match summaries) pull new users in.

Everything below is ordered by leverage: Phase 2 removes the biggest friction, Phase 3 deepens trust, Phase 4 builds retention, Phase 5 expands reach.

---

## Phase 2 — Kill the weekly re-creation loop

### F1. Recurring workouts (templates + auto-generation)

The single highest-leverage feature. Most groups play the same field, same day, same price, weekly.

**Design sketch:** New `event_templates` table (workspace_id, name, weekday, time, duration, location + coords, image, price, max_participants, recurrence = weekly/biweekly). A pg_cron job (reusing the `enqueue_event_reminders` pattern) materializes the next occurrence N days ahead as a normal `events` row and enqueues a `new_event` push to all workspace members. Creator can edit/skip any single occurrence without breaking the series.

**Acceptance criteria:**
- [ ] Creator can toggle "يتكرر أسبوعيًا" when creating a workout; this stores a template and links the first event to it.
- [ ] The next occurrence is auto-created 4 days before its start time (configurable per template), with all fields copied and a fresh participant list.
- [ ] All workspace members receive one push when a new occurrence opens ("انفتح التسجيل لتمرين الأربعاء ⚽").
- [ ] Creator can skip the next occurrence ("ما فيه تمرين هالأسبوع") or end the series; skipping never deletes past events.
- [ ] Editing a single occurrence (e.g. moved field this week) does not mutate the template.
- [ ] Deleting the template stops future generation but preserves history.
- [ ] SQL test covers: generation idempotency (cron runs twice → one event), locked/skipped weeks, RLS (only workspace members see templates).

### F2. RSVP + auto-promotion from waitlist

Today the waitlist is passive and free events have no commitment signal. Organizers need a hard headcount.

**Acceptance criteria:**
- [ ] Free events get the same join/leave commitment flow as paid ones: a member is جاي / معتذر / لم يرد, visible on the event card as "12/16 مؤكدين".
- [ ] When a confirmed participant leaves (or a pending payment is rejected/cancelled), the first waitlisted user gets a push with a **hold window** (e.g. 3 hours) to claim the seat; after expiry the hold passes to the next waiter automatically (pg_cron sweep).
- [ ] Seat-hold logic is serialized with the existing `select … for update` pattern — a concurrent join cannot steal a held seat.
- [ ] The reminder push (existing twice-daily cron) is split: confirmed players get "لا تنسَ"; non-responders get "أكّد حضورك" with the count of remaining seats.
- [ ] Organizer sees three lists on the detail page: مؤكدين / قائمة الانتظار / لم يردوا.

### F3. Event thread (comments + organizer announcements)

The coordination that still lives in WhatsApp: "I'm 10 min late", "bring white shirts", "field changed". Not full chat — a per-event thread.

**Acceptance criteria:**
- [ ] Each event has a thread; any workspace member can post text (≤500 chars). RLS mirrors event visibility.
- [ ] Organizer posts can be marked إعلان — these push-notify all confirmed participants via `push_outbox` (new type `event_announcement`); regular comments do not push.
- [ ] Thread shows below participants on `EventHeroDetailView`, newest last, with author name/avatar.
- [ ] Deleting an event cascades its thread; deleting a comment is author-or-organizer only.
- [ ] Abuse guard: max 20 posts per user per event per hour (rate limit in RPC).

### Quick wins to ship alongside Phase 2 (half-built today)
- [ ] Event `description` is captured in `NewEventView` but never displayed — show it on the detail page.
- [ ] `get_event_participants` returns `avatar_url` as `null::text` — join the `users` table and return real avatars.
- [ ] "Add guest" has backend support (`guest_name`, `added_by`) but the joiner UI for adding guests should be verified end-to-end and surfaced clearly in the paid-join sheet.

---

## Phase 3 — Trust & money

### F4. Payments ledger & organizer dashboard

Manual STC Pay stays (gateway deferred), but the *bookkeeping* becomes automatic. This is the feature that makes paid groups stick.

**Acceptance criteria:**
- [ ] Organizer gets a per-event money view: expected total (price × confirmed), collected (confirmed payments), outstanding (pending), with each row timestamped from the existing `payment_status` transitions (add a `payments_audit` table populated by the confirm/reject/submit RPCs).
- [ ] Workspace-level ledger: per member, sessions attended vs. sessions paid across all events — "فهد دفع 9 من 10".
- [ ] A member sees their own history: "دفعت 240 ريال في 8 تمارين هالشهر".
- [ ] Rejected payments switch from hard-delete to soft-delete (`payment_status = 'rejected'`, the v2 already anticipated in migration `20260617200000`) so the ledger is complete.
- [ ] Export: organizer can share a month summary as text (copyable) — no PDF needed for v1.

### F5. Receipt attachment on payment submit

The #1 dispute in manual flows is "أرسلت لك، تأكد". A screenshot closes it.

**Acceptance criteria:**
- [ ] `submit_payment` accepts an optional receipt image; the client uploads to the existing `tamrin-stg` storage bucket (private path, RLS: joiner + event creator can read).
- [ ] Organizer sees the receipt thumbnail next to the pending row; tapping opens full screen.
- [ ] Confirm/reject flow unchanged; receipt is retained on soft-deleted rejected rows for the ledger.
- [ ] Payments without receipts remain allowed (receipt is optional, not a gate).

### F6. Session pass / prepaid credit (later in Phase 3)

For weekly groups, paying every single week is friction. Let members prepay N sessions to the organizer.

**Acceptance criteria:**
- [ ] Organizer can define a pass ("شهر = 4 تمارين = 200 ريال"); member submits one STC payment, organizer confirms once.
- [ ] Joining a workout with an active pass consumes one credit — no payment sheet, instant confirmation.
- [ ] Credits are visible to both sides; expired/unused credits are flagged, never silently lost.
- [ ] Ledger (F4) treats pass consumption as a payment event.

### F7. Payment gateway integration — **deferred, tracked**
Placeholder for when volume justifies it (Moyasar / Tap / STC Pay API). The F4 ledger and F5 receipts are designed so a gateway later replaces only the "submit" leg; confirm/reject/ledger stay identical. No acceptance criteria yet — separate spec when unblocked.

---

## Phase 4 — Play better together (retention & identity)

### F8. Auto team generation + shareable lineup

The app already stores each user's `position` — unused leverage. Splitting teams fairly is a pre-game ritual in every group.

**Acceptance criteria:**
- [ ] On the event page (organizer, once registration is meaningful), "قسّم الفرق" splits confirmed participants + guests into 2–4 balanced teams by position; result is editable by drag before saving.
- [ ] Teams save to the event and are visible to all participants; a push announces "طلعت التشكيلة 👀".
- [ ] Lineup renders as a share card image (team colors, names, positions) that exports to the iOS share sheet — this is the viral artifact.
- [ ] Re-running the split reshuffles; manual edits are preserved until reshuffle.

### F9. Attendance, MVP vote, and streaks

Closes the loop after the whistle. This is what makes players open the app when there's nothing to pay.

**Acceptance criteria:**
- [ ] After the event's `end_date`, organizer gets a push to record attendance (default: all confirmed = attended; toggle no-shows off).
- [ ] For 24h after the event, attendees can vote one MVP (not themselves); the winner gets a push and a badge on their profile row.
- [ ] Profile shows: sessions attended, current weekly streak, MVP count — scoped per workspace.
- [ ] Reliability signal: confirmed-but-no-show count is visible to the organizer only (not public shaming), and feeds waitlist priority (reliable players get seat-holds first).
- [ ] Group leaderboard tab in the workspace: attendance streaks + MVPs this month.

### F10. Time poll for the next session

When the group *doesn't* have a fixed slot, scheduling is a WhatsApp poll. Bring it in.

**Acceptance criteria:**
- [ ] Organizer creates a poll with 2–4 datetime options; members get one push and vote in-app.
- [ ] Organizer converts the winning option into a workout with one tap (pre-filled `NewEventView`).
- [ ] Poll auto-closes at a deadline; results visible live.

---

## Phase 5 — Reach

### F11. Web guest page (join & pay from a browser)

The share link (`SharedEventView` deep link) currently dead-ends for non-iOS users — in a market full of Android WhatsApp groups, this is lost growth.

**Acceptance criteria:**
- [ ] Opening an event share link in a browser shows event details (name, time, location map, price, seats left) — Arabic RTL, no login.
- [ ] A visitor can join with name + phone (creates a guest-row equivalent via a scoped RPC) and sees the organizer's STC Pay number to send payment.
- [ ] Organizer sees web joiners in the same pending list, same confirm/reject flow.
- [ ] Page footer: "حمّل تمرين" → App Store. Every shared event becomes an acquisition surface.

### F12. English localization
- [ ] Extract hardcoded Arabic strings to `Localizable.strings` (app) and locale-keyed copy in `send-push/copy.ts` (pushes); layout verified in both LTR and RTL. Ship AR-first, EN complete.

### F13. Android — **exploratory, no criteria yet.** Re-evaluate after F11 web page ships; web guest flow may cover most of the demand signal.

---

## Sequencing & dependencies

```
Phase 2: F1 recurring ──► F2 RSVP/promotion ──► F3 threads   (+ quick wins in parallel)
Phase 3: F4 ledger ──► F5 receipts ──► F6 passes             (F7 gateway deferred)
Phase 4: F8 teams ──► F9 attendance/MVP/streaks ──► F10 polls (F9 depends on F2's confirmed lists)
Phase 5: F11 web guest ──► F12 EN ──► F13 Android (maybe)
```

- F1 + F2 + F4 are the 10x core — a weekly group that runs itself with clean books.
- Each feature reuses existing patterns: `push_outbox` for every notification, `SECURITY DEFINER` RPCs with workspace-membership guards, `for update` row locks for seat math, pg_cron for time-driven behavior, SQL test files per migration batch.
- Every feature ships behind the existing per-workspace privacy model; nothing here introduces public content.

## Success metrics per phase
- **Phase 2:** % of workouts created from a template (target >50% within a month); organizer time-to-publish next session < 1 min.
- **Phase 3:** % of paid rows with receipts; disputes reported → ~0; pass adoption in weekly groups.
- **Phase 4:** DAU/WAU between workouts; MVP-vote participation rate; lineup shares per event.
- **Phase 5:** web-page → App Store tap-through; guest→member conversion.
