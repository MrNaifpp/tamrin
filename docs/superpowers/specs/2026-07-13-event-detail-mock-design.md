# Designer UI Merge — Increment 2: Card → Event Detail (Mock Data)

**Date:** 2026-07-13
**Branch:** `feat/designer-ui-home` (continues from Increment 1)
**Status:** Design — awaiting approval

## Context

Increment 1 reskinned the Home feed to the designer's poster-card look on mock data
(`MockHomeFeed`), with card taps setting a selection but opening nothing. This increment
wires the card tap to a ported **event detail page** (the designer's
`OccurrenceDetailView`), still on mock data — registration is a local in-memory
mutation; no backend, no payment sheet.

Same locked decisions carry over: Sirr base, backend not called, Thmanyah Sans, designer
UI re-authored against the mock seam, admin affordances omitted.

## Scope

### In scope
- Extend `MockHomeFeed` with a member roster + registration state and local
  register/withdraw mutations.
- New `EventDetailView` porting the designer detail visuals: hero, participation CTA,
  capacity progress panel, member roster.
- Local interactive registration: register → join list (waitlist when full); withdraw →
  leave list and promote the first waitlisted person.
- A disabled payment-button placeholder (`الدفع — قريبًا`) when the event has a price.
- Present the detail from a card tap via `fullScreenCover` + zoom transition.
- Build-check; hand to Naif for device testing.

### Out of scope (later increments)
- Real backend wiring (register/withdraw → `EventService`/STC Pay).
- The multi-step registration + payment flow (guests, payment method, STC Pay
  confirmation — the designer's `RegistrationFlowSheet`).
- Admin section (payments collection, edit/cancel occurrence).
- The other Home-page actions (side menu, plan-template detail, profile/settings).

## Decisions (locked with user)

1. **Register CTA is interactive but local:** tapping register mutates the mock roster in
   memory (count bumps, your row appears, button flips to `مكانك محفوظ`). Payment is
   deferred — the pay button is a disabled `قريبًا` placeholder.
2. **Roster/count refactor:** the roster and registered count move into `MockHomeFeed` as
   the single source of truth. `FeedOccurrence.registeredCount` is removed;
   `EventPosterCard` takes `registeredCount: Int` as a parameter so the feed card stays
   in sync after registration.
3. **Withdraw promotes** the first waitlisted person to registered (mirrors the designer,
   feels real).
4. **Admin omitted**, as in Increment 1.

## Architecture

### Mock model changes (`Sirr/features/home/MockHomeFeed.swift`)
Add:
```
enum FeedRegStatus { case registered, waitlisted }
struct FeedMember: Identifiable { let id: UUID; let name: String; let status: FeedRegStatus }
```
`FeedOccurrence`: **remove** the `registeredCount` stored property (now derived).

`MockHomeFeed` gains:
- `var rosters: [UUID: [FeedMember]]` — seeded per occurrence.
- `let currentUserName = "نايف"` (equals `profileName`).
- `func roster(for: FeedOccurrence) -> [FeedMember]`
- `func registeredCount(for: FeedOccurrence) -> Int` — count of `.registered` in the roster.
- `func waitlistCount(for: FeedOccurrence) -> Int`
- `func myRegistration(for: FeedOccurrence) -> FeedMember?` — the current user's row, if any.
- `func register(for: FeedOccurrence)` — no-op if already in roster; else append the
  current user as `.registered` when `registeredCount < capacity`, otherwise `.waitlisted`.
- `func withdraw(from: FeedOccurrence)` — remove the current user's row; if they were
  `.registered` and a `.waitlisted` member exists, promote the first waitlisted to
  `.registered`.

Seeding (demonstrates every state):
- Event 1 (`كورة الثلاثاء`, capacity 14): 9 registered mock members; current user absent.
- Event 2 (`تمرين الجري`, capacity 20): 12 registered; current user absent.
- Event 3 (`كورة نهاية الأسبوع`, capacity 12): 12 registered (full) + 1 waitlisted;
  current user absent → registering here lands on the waitlist.

### New view (`Sirr/features/home/EventDetailView.swift`)
`struct EventDetailView: View { @Bindable var feed: MockHomeFeed; let occurrence: FeedOccurrence; var artName: String }`

Ported sections (designer `OccurrenceDetailView`, member-only):
- **Hero:** full-bleed `artName` image with a blur-fade gradient mask; cancelled badge
  (`تم إلغاء الموعد`) when `occurrence.isCancelled`; title + `يوم … الساعة …`.
- **Participation CTA** (hidden when cancelled):
  - Not registered: `سجل في التمرين` (open spots) or `انضم لقائمة الانتظار` (full) →
    `feed.register(for:)`.
  - Registered/waitlisted: a glass row showing `مكانك محفوظ` / `أنت في قائمة الانتظار`
    with a trailing `اعتذر` / `انسحب` → `feed.withdraw(from:)`.
  - When `occurrence.price > 0` and current user is registered: a **disabled**
    `الدفع — قريبًا` placeholder button (payment deferred).
- **Progress panel:** `ProgressView(confirmed / capacity)` tinted lime, `confirmed/capacity`
  label, waitlist count line when non-zero.
- **Roster:** member rows (avatar initial + name + registered/waitlisted icon); empty state
  `كن أول المسجلين.` when the roster is empty.
- Back button (glass circle, `chevron.backward`) → dismiss.

### Wiring (`Sirr/features/home/DesignerHomeView.swift`)
- Add `@Namespace private var cardZoom`.
- On each `EventPosterCard`, add `.matchedTransitionSource(id: occurrence.id, in: cardZoom)`
  and pass `registeredCount: feed.registeredCount(for: occurrence)`.
- Present detail:
  ```
  .fullScreenCover(item: $selected) { occ in
      EventDetailView(feed: feed, occurrence: occ, artName: artName(indexOf(occ)))
          .navigationTransition(.zoom(sourceID: occ.id, in: cardZoom))
  }
  ```
  `indexOf(occ)` resolves the same art index the card used.

## Data flow
Card tap → `selected = occurrence` → `fullScreenCover` presents `EventDetailView` bound to
the shared `MockHomeFeed`. Register/withdraw call methods on `feed`; because `MockHomeFeed`
is `@Observable`, both the detail page and the underlying feed card re-render, so the
count stays consistent when the sheet is dismissed.

## Error handling
Not applicable — no network, no async. Empty roster and full/waitlist states are handled
in the view as described.

## Testing / Verification
- Build-check: compile the `Sirr` scheme via `xcodebuild` with a generic simulator
  destination (never boots a simulator), per project workflow.
- Hand to Naif for on-device verification: open a card → detail zooms in; register/withdraw
  updates the roster, count, and progress bar live; full event routes to waitlist; pay
  placeholder is present and disabled; back returns with the feed card count updated.
- No unit tests (pure UI on mock state, consistent with Increment 1).

## Definition of done
- `MockHomeFeed` exposes the roster + register/withdraw API; count derives from the roster.
- Tapping a feed card zooms into `EventDetailView` on mock data.
- Register/withdraw mutate the roster live; full event → waitlist; withdraw promotes.
- Pay button is a disabled `قريبًا` placeholder; admin omitted.
- `Sirr` scheme compiles; handed to Naif for device testing.
