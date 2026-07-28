# Home Redesign — Design

**Date:** 2026-07-02
**Status:** Approved (brainstormed against 3 reference screenshots supplied by the user)

## Summary

The home screen moves from a horizontal swipeable card pager to a **vertical scrolling feed** with a new header, a dedicated **upcoming-workouts page**, and a **slide-in groups drawer** that replaces the half-sheet workspace switcher. Terminology changes app-wide: workspaces are called **مجموعة/المجموعات** (was مساحة), and event copy on the touched screens becomes **تمرين/تمارين**.

Zero backend changes: no migrations, no RPC or service changes. This is an iOS-only UI restructuring on top of the workspaces feature (see `2026-07-02-workspaces-design.md`).

| Decision | Choice |
|---|---|
| Feed | Vertical scroll; **all big image cards** (existing `NewActivtyCardView`) |
| Section labels | **التمرين الجاي** above the first card; **التمارين القادمة** above the rest |
| Header | Hamburger (leading) · pill **"التمارين القادمة ‹"** (center, → upcoming page) · profile avatar (trailing). No + in header |
| Upcoming page week strip | Informational only: current week, today highlighted, dot on workout days |
| Group switching | Only via the drawer (no group-name pill in the header) |
| Drawer + button | **New workout** in the current group |
| New group | "مجموعة جديدة +" row at the end of the drawer's group list |
| Drawer gear | Combined settings: current group's settings on top + app-level **تسجيل الخروج** at the bottom |
| Naming | مجموعة everywhere (copy sweep) |
| Architecture | Approach A: evolve `EventPageView` in place, decomposing it into focused subviews |

## 1. Home screen

`EventPageView` becomes a slim container keeping: `NavigationStack`, workspace/event loading (`loadEvents`, `.task(id: appState.currentWorkspaceId)`), deep-link handlers (`.task(id: deepLinkEventId)` + error alert), and sheet presentation. UI is delegated to new focused views:

- **`HomeHeaderView`** (new, `Sirr/Components/`):
  - Leading (right in RTL): hamburger circle → opens the drawer.
  - Center: pill "التمارين القادمة ‹" → pushes `UpcomingScheduleView`.
  - Trailing: profile avatar (existing behavior → `EditProfileSheet`).
  - Replaces the current toolbar items; the workspace-avatar toolbar button and the header "+" are removed (creating a workout moves to the drawer).
- **Vertical feed** (replaces the `TabView` pager): `ScrollView` + `LazyVStack` of the same big image cards. Right-aligned section label **التمرين الجاي** above the first card, **التمارين القادمة** above the second card onward (labels appear only when the corresponding cards exist). Card tap → existing `EventHeroDetailView` with the zoom transition, unchanged.
- **Background**: static blurred image of the soonest workout (first card) + the existing dark overlay. (Today it tracks the swiped page; with vertical scroll it no longer changes while scrolling.)
- **Empty states** (copy updated):
  - Zero groups: existing onboarding ("ابدأ مجموعتك الأولى…", "إنشاء مجموعة", invite-link hint). Header shows only the avatar (no drawer/pill without a group — same guard pattern as today's hidden "+").
  - Group with no workouts: "لا توجد تمارين في {اسم المجموعة}" + a "تمرين جديد" button; drawer still reachable.
- `currentPage` state and `UIPageControl` appearance code are removed with the pager.

## 2. Upcoming page — `UpcomingScheduleView` (new, `Sirr/pages/`)

Pushed via the existing `navigationPath`. Light background (matches the reference). Receives the already-loaded `[EventData]` from home — **no new fetching**.

- **Week strip**: the current week أحد ← سبت; each cell = Arabic day name + day number (Arabic-Indic numerals). Today visually highlighted; a small dot under days that have ≥1 workout. Not interactive (no taps, no week paging).
- **التمرين الجاي**: one detailed white card for the soonest workout: name, weekday + date (e.g. "الثلاثاء ٧ يوليو"), time range "من ٦:٣٠ م ← إلى ٨:٣٠ م", and a days-remaining side counter ("٥ أيام"; "اليوم" when it's today). Tap → `EventHeroDetailView`.
- **التمارين القادمة**: compact white rows for the remaining workouts — side block with day number + month, workout name. Tap → detail.
- Empty group → same "لا توجد تمارين" message as home.

## 3. Groups drawer — `GroupsDrawer` (new, `Sirr/Components/`)

Custom overlay replacing `WorkspaceSwitcherSheet` (which is **deleted**; the shared `WorkspaceAvatar` view moves into its own file `Sirr/Components/WorkspaceAvatar.swift`).

- **Presentation**: dark panel (~85% width) sliding in from the leading edge; home dims and shifts slightly aside (as in the reference video frame). Dismiss by tapping the dimmed area or swiping toward the edge.
- **Contents**, top to bottom:
  - Title **"المجموعات"** with a blue **+** button = **تمرين جديد** in the current group (opens `NewEventView` with the current workspace id; hidden if the user has zero groups).
  - Group rows: square icon tile (colored initial — reuse `WorkspaceAvatar`'s stable byte-hash color), group name, "الأعضاء N". Current group highlighted. Tap → switch (`appState.currentWorkspaceId = id`) and close; home reloads via the existing `.task(id:)`.
  - **"مجموعة جديدة +"** row at the end of the list → existing `CreateWorkspaceSheet`.
  - **Gear** pinned at the bottom corner → combined settings (below) for the **current** group.
- State for the drawer (`showDrawer`) lives in the home container.

## 4. Combined settings

`WorkspaceSettingsSheet` (renamed copy, same file) gains an app-level section at the very bottom, after the existing danger section:

- Divider + **"تسجيل الخروج"** row (red) → `authVM.logout()` (moves here from the deleted switcher sheet — it must not be lost; it is currently the app's only logout control).
- Everything else (invite link, members + removal confirm, rename, regenerate, delete/leave) is unchanged apart from مساحة → مجموعة copy.

## 5. Copy sweep

- **مساحة → مجموعة** in: `CreateWorkspaceSheet`, `WorkspaceSettingsSheet`, `JoinWorkspaceView`, `EventPageView` empty states, `SharedEventView` private-event error ("هذا الحدث في مجموعة خاصة…"), `NewEventView`'s no-workspace error.
- **فعالية/مناسبة → تمرين** only on the screens this redesign touches (home labels/empty states, upcoming page). Other screens (event detail, payment sheets) are out of scope.
- DB values (e.g. backfilled workspace names like "مساحتي") are data, not copy — untouched.

## 6. Unchanged

Backend (schema, RPCs, RLS, tests), `WorkspaceService`/`EventService`, deep-link parsing and login-resume, join flow, payment flow, guest rows, waitlist, reminders, push handling (a push tap still switches the current group then opens the event detail).

## 7. Verification

- Build gate per change (`xcodebuild … BUILD SUCCEEDED`; no test target exists).
- Final simulator visual pass: vertical scroll with both labels; pill → upcoming page (strip/today/dots, next card, rows); drawer open/switch/create-workout/create-group; gear → settings + logout; zero-group and zero-workout empty states; deep-link event tap still lands on detail.

## Out of scope (future)

- Interactive week strip (tap-to-scroll, week paging)
- Group images (drawer tiles keep colored initials)
- Renaming event copy on detail/payment screens
- Any backend change
