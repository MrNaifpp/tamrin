# Designer UI Merge — Increment 3: Side Menu (Mock Data)

**Date:** 2026-07-13
**Branch:** `feat/designer-ui-home` (continues from Increment 2)
**Status:** Design — approved, proceeding to plan

## Context

Increments 1–2 delivered the reskinned Home feed and the card→event-detail flow on mock
data. The Home header's ☰ button is still inert. This increment ports the designer's
`TeamSideMenu` drawer and wires the button to it, with live team switching on mock data.
The drawer's other destinations (payments, settings, notifications, create-team) are
stubbed for later increments. All decisions from prior increments carry over (Sirr base,
backend not called, Thmanyah Sans, admin omitted).

## Scope

### In scope
- Multi-team mock model: `MockHomeFeed` gains `teams`, `selectedTeamID`, per-team
  occurrences, and `selectTeam(_:)`; `occurrences`/`currentTeam` become computed.
- New `TeamSideMenu` drawer view (bound to `MockHomeFeed`), minus the admin/member
  experience switcher.
- Drawer reveal mechanics ported into `DesignerHomeView`: slide-out offset/scale/corner/
  shadow/dim transform of the main content, tap-to-close scrim, right-edge-swipe gesture
  with haptic and predicted-end snap.
- Live team switching: tapping a team row switches which team's events the feed shows and
  closes the drawer.
- Stubbed destinations (payments, settings, notifications, create-team) trigger a
  lightweight "قريبًا — تحت التطوير" alert naming the feature.
- Build-check; hand to Naif for device testing.

### Out of scope (later increments)
- Real backend wiring (teams/events from Supabase).
- The destination screens themselves: payments organizer, settings, notifications,
  create/join team.
- The admin/member experience switcher (dropped — demo-only, tied to omitted admin).
- The plan-template detail screen (the header's team-name pill remains inert).

## Decisions (locked with user)

1. **Drawer + team switching now; other destinations stubbed** as a "قريبًا" alert.
2. **Drop the experience (admin/member) switcher.**
3. **Multiple mock teams** so switching is meaningful; seed one empty team to demo the
   empty state on switch.
4. **Notifications:** plain bell, no unread badge (mock has no unread count).

## Architecture

### Mock model changes (`Sirr/features/home/MockHomeFeed.swift`)
`FeedTeam` becomes identifiable with a member count:
```
struct FeedTeam: Identifiable {
    let id: UUID
    let name: String
    let symbol: String
    let avatarData: Data?
    let memberCount: Int
}
```
`MockHomeFeed` replaces the single `team`/`occurrences` with:
- `var teams: [FeedTeam]`
- `var selectedTeamID: UUID`
- `var occurrencesByTeam: [UUID: [FeedOccurrence]]`
- `var rosters: [UUID: [FeedMember]]` (unchanged — keyed by occurrence id across all teams)
- computed `var currentTeam: FeedTeam { teams.first { $0.id == selectedTeamID } ?? teams[0] }`
- computed `var occurrences: [FeedOccurrence] { occurrencesByTeam[selectedTeamID] ?? [] }`
- `func selectTeam(_ id: UUID) { selectedTeamID = id }`

Reading `occurrences`/`currentTeam` in view bodies tracks `selectedTeamID` through the
Observation framework, so switching updates the feed reactively.

Seeding — three teams:
- **رفاق الملعب** (memberCount 12): the three existing occurrences (كورة الثلاثاء / تمرين
  الجري / كورة نهاية الأسبوع) with their seeded rosters.
- **نادي الفجر** (memberCount 8): two occurrences (e.g. `تمرين الصباح`, `مباراة ودية`) with
  small rosters.
- **الصقور** (memberCount 5): no occurrences (demonstrates the empty state).

`register`/`withdraw`/count helpers are unchanged (they operate on `rosters` by occurrence).

Ripple: `DesignerHomeView` passes `feed.currentTeam` (not `feed.team`) to `StickyHomeHeader`.

### New view (`Sirr/features/home/TeamSideMenu.swift`)
`struct TeamSideMenu: View` with:
```
@Bindable var feed: MockHomeFeed
let close: () -> Void
let createTeam: () -> Void
let openSettings: () -> Void
let openPayments: () -> Void
let openNotifications: () -> Void
let onSelectTeam: (UUID) -> Void
```
Layout (ported from designer, dark drawer background `#111111`):
- Header row: `المجموعات` title + a create-team button (`plus`, glass-prominent circle) →
  `createTeam`.
- Scrollable team list: `TeamSideMenuRow` per `feed.teams` (team avatar via `TeamAvatarView`,
  name, `الأعضاء N`, selected highlight when `team.id == feed.selectedTeamID`) → tap calls
  `onSelectTeam(team.id)` with a selection haptic.
- Payments row button (`creditcard.fill`, `دفعاتي` / `تابع القَطّات القادمة`) → `openPayments`.
- Bottom: profile row (initial avatar + `feed.profileName` + `الملف الشخصي`) → `openSettings`;
  a notifications bell button (`bell.fill`, no badge) → `openNotifications`.
- `TeamSideMenuRow` is a private subview in this file.

### Drawer mechanics (`Sirr/features/home/DesignerHomeView.swift`)
Extract the current home content into a private `mainContent` view, then rebuild `body`:
- New state: `@State private var isMenuOpen = false`, `menuDragProgress: CGFloat = 0`,
  `didMenuHaptic = false`, `comingSoon: String?`; `@Environment(\.accessibilityReduceMotion)`.
- Helpers ported from the designer's `HomeView`: `menuProgress()`,
  `setMenu(open:)` (spring animation, resets drag + haptic flag),
  `menuGesture(revealDistance:screenWidth:)` (right-edge start detection, drag→progress,
  haptic tick at 0.78, predicted-end snap at 0.46).
- Body: `GeometryReader` → `revealDistance = min(width * 0.84, 340)`, `progress =
  menuProgress()`, `pageCorner = 44 * progress`. `ZStack(alignment: .leading)` with
  `TeamSideMenu` behind and `mainContent` transformed by `offset(x: revealDistance *
  progress)`, `scaleEffect(1 - 0.045*progress, anchor: .trailing)`,
  `clipShape(corner: pageCorner)`, `shadow(... * progress)`, `opacity(1 - 0.18*progress)`,
  a `progress > 0.02` tap-to-close scrim, and the spring animation on `progress`.
  `.simultaneousGesture(menuGesture(...))` on the ZStack.
- The header's `openMenu` closure calls `setMenu(open: true)`.
- Drawer callbacks: `onSelectTeam` → `feed.selectTeam(id)` + `setMenu(open: false)`;
  each stubbed destination → `setMenu(open: false)` then `comingSoon = "<feature>"`.
- A single `.alert("قريبًا", isPresented: <comingSoon != nil>)` with message
  `"<feature> — تحت التطوير"`.

The existing `fullScreenCover` detail presentation and `.environment(layoutDirection,
.rightToLeft)` stay on `mainContent`.

## Data flow
☰ button or right-edge swipe drives `isMenuOpen`/`menuDragProgress` → `progress` → the
main content transform. Selecting a team calls `feed.selectTeam`, updating
`selectedTeamID`; the observed computed `occurrences`/`currentTeam` refresh the feed and
header. Stub buttons set `comingSoon`, surfacing the alert.

## Error handling
Not applicable — no network, no async. The empty team renders the existing
`EmptyScheduleCard`.

## Testing / Verification
- Build-check: compile the `Sirr` scheme via `xcodebuild` with a generic simulator
  destination (never boots a simulator).
- Hand to Naif: open/close via the ☰ button and via right-edge swipe (with the drawer
  transform + haptic); switch teams and confirm the feed + header update; switch to the
  empty team and see the empty state; each stubbed button shows the "قريبًا" alert.
- No unit tests (pure UI on mock state, consistent with prior increments).

## Definition of done
- `MockHomeFeed` is multi-team with `selectTeam`; `occurrences`/`currentTeam` computed.
- The ☰ button and right-edge swipe open the ported `TeamSideMenu` with the reveal
  transform.
- Tapping a team switches the feed; the empty team shows the empty state.
- Payments/settings/notifications/create-team show the "قريبًا" alert.
- Admin/member switcher absent; notifications bell has no badge.
- `Sirr` scheme compiles; handed to Naif for device testing.
