# Designer UI Merge — Increment 1: Foundation + Home Feed (Mock Data)

**Date:** 2026-07-13
**Branch:** `feat/designer-ui-home` (cut from `phase_1`)
**Status:** Design — awaiting approval

## Context

We have two iOS SwiftUI apps in this repo:

- **Sirr** (`phase_1` branch, `Sirr.xcodeproj`) — the production app. Full Supabase
  backend: Apple/OTP/email auth, event/workspace RPCs, STC Pay, push, deep links.
- **tamrin.test2** (`tamrin-test2-current` branch) — a designer's high-fidelity
  redesign. 100% local SwiftData, **no backend, no auth, no networking** — all mock
  data via `TamrinStore`. Its value is the polished UI and a real design system
  (`DesignSystem.swift` + Thmanyah Sans font).

**Goal (overall):** keep the designer's UI, keep Sirr's backend/services. Reskin Sirr
screen-by-screen with the designer's look. This spec covers **Increment 1 only**:
port the design-system foundation and reskin the **Home feed**, driven entirely by
**mock data**. Real backend wiring is deferred to a later increment.

## Decisions (locked with user)

1. **Base project:** Sirr (`phase_1`). Its backend/services stay intact and are **not
   called** in this increment.
2. **Font:** adopt **Thmanyah Sans**. Sirr's existing `TheYearofHandicrafts` font
   remains for not-yet-reskinned screens; the two coexist during migration.
3. **Data:** the Home feed runs on **mock data only**. No `EventService`/Supabase calls.
   The mock provider is the seam we later swap for real services.
4. **Sequencing:** foundation + one proof screen (Home feed) first, then fan out to
   other screens in their own specs.

## Scope

### In scope (Increment 1)
- Import `DesignSystem.swift` (tokens, type scale, button styles, components) verbatim.
- Add the 4 Thmanyah Sans `.ttf` files and register them in `Info.plist` (`UIAppFonts`).
- Import the 3 `ExerciseArt` image assets.
- Build a **mock feed data layer** (`MockHomeFeed` + lightweight model types) with
  hardcoded sample events/team/profile.
- Port the designer's **Home feed** views, retargeted from `TamrinStore`/`Occurrence`
  to the mock model:
  - `HomeArtBackdrop` — blurred art background behind the feed.
  - `StickyHomeHeader` + `HomeTopBar` — team avatar, profile, section title
    ("التمرين الجاي" / "التمارين القادمة"), menu button.
  - `ExercisePosterCard` — the poster-style event card.
  - `EmptyScheduleCard` — empty state.
  - `ScrollHintChevron` — scroll affordance.
- Route the logged-in Home to the new designer feed.
- Build-check that the `Sirr` scheme compiles; hand to Naif for on-device testing.

### Out of scope (later increments, each its own spec)
- Wiring the Home feed to real Supabase data (`EventService`).
- Event detail, create event, auth/onboarding, payment/STC Pay, workspace/team
  management, notifications, plan-template detail.
- The edge-swipe `TeamSideMenu` drawer (deferred to the workspace increment). In this
  increment the menu button is a no-op stub.
- Admin publish/edit/cancel affordances on the card.

## Architecture

### The reusable pattern (validated by this increment)
The designer's screens are tightly coupled to `TamrinStore` + SwiftData. Importing them
verbatim would drag the whole local data layer in. So the port pattern is:

- **Design system is imported verbatim** — it is model-agnostic and carries the look.
- **Screen bodies are re-authored against a Sirr-side model**, using the designer's
  screen as the pixel-exact reference.

For Increment 1 that Sirr-side model is a **mock model** (not `EventData` yet), because
this screen is intentionally backend-free. Later increments will replace the mock
provider with `EventService`, and re-point the same views at real data.

### The seam: `MockHomeFeed`
A single observable object exposes exactly what the Home feed views read:

```
@MainActor @Observable final class MockHomeFeed {
    var team: FeedTeam            // name, symbol, avatar
    var profileName: String
    var occurrences: [FeedOccurrence]   // ordered, upcoming first
    // helpers the card needs:
    func registeredCount(for: FeedOccurrence) -> Int
}

struct FeedOccurrence: Identifiable {
    let id: UUID
    let title: String            // plan/event name
    let startAt: Date
    let locationName: String
    let capacity: Int
    let registeredCount: Int
    let price: Double            // 0 = free
    let isCancelled: Bool
    let artIndex: Int            // cycles ExerciseArt1..3
}

struct FeedTeam { let name: String; let symbol: String; let avatarData: Data? }
```

`MockHomeFeed` is seeded with 3–4 hardcoded sample occurrences (mirroring the
designer's MOVE24 demo) so the multi-card feed, single-card, and empty states are all
demonstrable. This object is the **integration seam**: a later increment replaces its
mock body with calls to `EventService`/`WorkspaceService` and maps records into
`FeedOccurrence`, leaving the views unchanged.

### File plan (all added under `Sirr/`, auto-included via synchronized folders)
| File | Purpose |
|------|---------|
| `Sirr/DesignSystem/DesignSystem.swift` | designer tokens/components, verbatim |
| `Sirr/Fonts/Thmanyahsans12-*.ttf` (×4) | Thmanyah Sans font files |
| `Sirr/features/home/MockHomeFeed.swift` | mock model + provider (the seam) |
| `Sirr/features/home/DesignerHomeView.swift` | ported Home feed screen + subviews |

`Info.plist` — add the 4 font filenames under `UIAppFonts`.
`ContentView.swift` — point the logged-in branch at `DesignerHomeView`. The existing
`EventPageView.swift` stays in the project (unused) as reference for the later
backend-wiring increment.

### Gap handling (all rendered with mock values this increment)
Because the whole screen is mock, the earlier UI↔backend gaps collapse to "populate the
mock with a sensible value":
- **X/Y registered count** — mock provides both numbers; card shows "X/Y".
- **Cancelled / closed badge** — mock `isCancelled` drives the designer's "ملغي" pill.
- **Admin publish states / buttons** — **omitted** this increment (`isAdmin` not modeled
  in the mock; card renders the member view only).
- **Card art** — cycles `ExerciseArt1..3` by `artIndex` (the designer default).

## RTL / Localization
The designer views are Arabic-first and already apply
`.environment(\.layoutDirection, .rightToLeft)`. Sirr is likewise Arabic. The ported
Home feed keeps RTL and the designer's Arabic strings. No new localization system.

## Error handling
Not applicable this increment — no network, no async failure paths. The empty state
(`EmptyScheduleCard`) covers the "no occurrences" case; the mock is seeded non-empty by
default, with a documented toggle to exercise the empty state.

## Testing / Verification
- **Build-check only:** compile the `Sirr` scheme via `xcodebuild` (no simulator boot,
  per project workflow). Resolve font registration and synchronized-folder inclusion.
- **Hand to Naif** for on-device visual verification of the reskinned Home feed.
- No unit tests this increment (pure UI on static mock data).

## Risks
- **iOS version APIs:** designer code uses iOS 26-era APIs (`.glassProminent`,
  `.buttonBorderShape`). Sirr targets the same recent SDK, so this should compile; the
  admin-only glass buttons are omitted here anyway.
- **Font PostScript names:** registration must use the exact PostScript names
  (`Thmanyahsans12-Regular/Medium/Light/Bold`) the design system references. Verified
  against `DesignSystem.swift`.
- **Routing swap:** pointing Home at `DesignerHomeView` changes what a logged-in user
  sees to mock data. Acceptable and intended ("handle backend later"); reversible by
  restoring the `EventPageView` reference.

## Definition of done
- `DesignSystem.swift`, Thmanyah fonts, and `ExerciseArt` assets are in the Sirr project.
- The logged-in Home shows the designer's poster-card feed, sticky header, art backdrop,
  and empty state, all driven by `MockHomeFeed`.
- The `Sirr` scheme compiles cleanly.
- Handed to Naif for device testing.
