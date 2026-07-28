# Home Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Home becomes a vertical feed with التمرين الجاي/التمارين القادمة sections, a new header (hamburger · upcoming pill · avatar), a pushed upcoming-schedule page, and a slide-in groups drawer replacing the half-sheet switcher; copy renames مساحة → مجموعة.

**Architecture:** iOS-only UI restructuring (zero backend changes). `EventPageView` stays the container (navigation, loading, deep links, sheets) and delegates UI to new focused views: `HomeHeaderView`, `GroupsDrawer`, `UpcomingScheduleView`, plus `WorkspaceAvatar` extracted to its own file. The horizontal `TabView` pager is deleted.

**Tech Stack:** SwiftUI (iOS), existing `WorkspaceService`/`EventService` (untouched). Xcode project uses file-system-synchronized groups — new `.swift` files under `Sirr/` are picked up automatically, no pbxproj edits.

**Spec:** `docs/superpowers/specs/2026-07-02-home-redesign-design.md`

## Global Constraints

- All UI is Arabic, RTL. Sheet/page roots get `.environment(\.layoutDirection, .rightToLeft)` (match existing sheets). Fonts via `.appTitle/.appBody/.appCaption/...` from `Sirr/Extensions/FontExtension.swift` — never raw `.font(.system)` for text (system font sizes for icons are fine).
- No backend, service, model, or deep-link changes. `WorkspaceService`, `EventService`, `AppState`, `ContentView` are NOT modified by this plan (exception: none).
- Verification gate (no XCTest target exists): `xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3` must print `BUILD SUCCEEDED`. Run once per task, before committing — it is slow; don't run per edit.
- Copy terms: group = **مجموعة/المجموعات**, workout = **تمرين/تمارين**. New code written in this plan uses these terms from the start; Task 8 sweeps the remaining old strings.
- Section labels exactly: **التمرين الجاي** (first card), **التمارين القادمة** (rest / header pill / upcoming page).
- Work on branch `phase_1`, commit per task, no new branches.

---

### Task 1: Extract `WorkspaceAvatar` into its own file

**Files:**
- Create: `Sirr/Components/WorkspaceAvatar.swift`
- Modify: `Sirr/Components/WorkspaceSwitcherSheet.swift` (remove the struct; file is deleted entirely in Task 5)

**Interfaces:**
- Consumes: nothing.
- Produces: `WorkspaceAvatar(name: String, id: UUID, size: CGFloat = 34)` — unchanged public shape, now importable after Task 5 deletes its old host file.

- [ ] **Step 1: Create the new file**

Create `Sirr/Components/WorkspaceAvatar.swift` with exactly this content (the struct is MOVED verbatim from `WorkspaceSwitcherSheet.swift` lines 12–37):

```swift
//
//  WorkspaceAvatar.swift
//  Sirr
//
//  Colored-initial square used everywhere a group needs an identity.
//  The hue is derived from the group id so it is stable across launches.
//

import SwiftUI

struct WorkspaceAvatar: View {
    let name: String
    let id: UUID
    var size: CGFloat = 34

    private var color: Color {
        // Stable across launches: hashValue is per-process randomized, so
        // derive the hue from the UUID's raw bytes instead.
        let bytes = withUnsafeBytes(of: id.uuid) { $0.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF } }
        let hue = Double(bytes % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)))
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}
```

- [ ] **Step 2: Remove the struct from `WorkspaceSwitcherSheet.swift`**

Delete lines 12–37 of `Sirr/Components/WorkspaceSwitcherSheet.swift` (the `/// Colored-initial square…` doc comment through the closing brace of `struct WorkspaceAvatar`). Leave the rest of the file untouched.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add Sirr/Components/WorkspaceAvatar.swift Sirr/Components/WorkspaceSwitcherSheet.swift
git commit -m "refactor(ios): extract WorkspaceAvatar into its own file"
```

---

### Task 2: `HomeHeaderView`

**Files:**
- Create: `Sirr/Components/HomeHeaderView.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `HomeHeaderView(avatarUrl: String?, showsGroupControls: Bool, onMenu: @escaping () -> Void, onUpcoming: @escaping () -> Void, onProfile: @escaping () -> Void)`. Task 3 places it in the toolbar area. When `showsGroupControls == false` (zero groups) only the profile avatar renders.

- [ ] **Step 1: Create the file**

```swift
//
//  HomeHeaderView.swift
//  Sirr
//
//  Home header: hamburger (opens the groups drawer) · "التمارين القادمة" pill
//  (pushes the upcoming page) · profile avatar. With zero groups only the
//  avatar shows — there is no drawer or schedule to open yet.
//

import SwiftUI

struct HomeHeaderView: View {
    let avatarUrl: String?
    let showsGroupControls: Bool
    var onMenu: () -> Void
    var onUpcoming: () -> Void
    var onProfile: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if showsGroupControls {
                circleButton(action: onMenu) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }

            Spacer()

            if showsGroupControls {
                Button(action: onUpcoming) {
                    HStack(spacing: 6) {
                        Text("التمارين القادمة")
                            .font(.appCallout)
                            .foregroundStyle(.white)
                        Image(systemName: "chevron.forward") // points left in RTL, matching the mockup
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Capsule().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            circleButton(action: onProfile) {
                profileAvatar
            }
        }
        .padding(.horizontal, 16)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func circleButton<Content: View>(
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 40, height: 40)
                .background(Circle().fill(.ultraThinMaterial))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if let urlString = avatarUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure, .empty:
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.gray.opacity(0.7))
                @unknown default:
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.gray.opacity(0.7))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

#Preview {
    ZStack {
        Color.black
        VStack {
            HomeHeaderView(
                avatarUrl: nil,
                showsGroupControls: true,
                onMenu: {}, onUpcoming: {}, onProfile: {}
            )
            Spacer()
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add Sirr/Components/HomeHeaderView.swift
git commit -m "feat(ios): home header with hamburger, upcoming pill, profile avatar"
```

---

### Task 3: Vertical feed — rewire `EventPageView`

**Files:**
- Modify: `Sirr/pages/EventPageView.swift`

**Interfaces:**
- Consumes: `HomeHeaderView` (Task 2). `WorkspaceSwitcherSheet` still exists and stays temporarily wired to the hamburger (`showSwitcher`) until Task 5 swaps in the drawer.
- Produces: home shows a `ScrollView` feed with the two section labels; `NavigationDestination` gains a `.upcoming` case whose destination is a placeholder `Text` until Task 7. State removed: `currentPage`. Functions removed: `hapticMedium()`, `eventPageProfileAvatar`.

Current file reference: `Sirr/pages/EventPageView.swift` (526 lines). Line numbers below refer to its current state; apply edits top-to-bottom.

- [ ] **Step 1: Extend `NavigationDestination` (line 13)**

```swift
enum NavigationDestination: Hashable {
    case newEvent
    case upcoming
}
```

- [ ] **Step 2: Remove pager state, keep the rest**

Delete the line `@State private var currentPage: Int = 0` (line 22). Leave all other state.

- [ ] **Step 3: Replace the feed branch of the `ZStack` (lines 66–122)**

Replace the entire `} else {` branch (from `// Full-screen background image…` through the closing of the `VStack` with `.ignoresSafeArea(.keyboard, edges: .top)`) with:

```swift
                    } else {
                        // Static blurred backdrop from the next (soonest) workout.
                        nextEventBackground
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                            )
                            .clipped()
                            .ignoresSafeArea(edges: .all)
                            .blur(radius: 8)
                        Color.black.opacity(0.3)
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
                            )
                            .ignoresSafeArea(edges: .all)
                        if eventsLoading && events.isEmpty {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.2)
                        } else if !events.isEmpty {
                            workoutFeed(geometry: geometry)
                        }
                    }
```

- [ ] **Step 4: Add the feed + section label helpers**

In the `// MARK: - Events loading & empty state` private extension, add (after `loadEvents()`):

```swift
    /// Vertical feed: التمرين الجاي (first card) then التمارين القادمة (rest).
    func workoutFeed(geometry: GeometryProxy) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 10) {
                sectionLabel("التمرين الجاي")
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    if index == 1 {
                        sectionLabel("التمارين القادمة")
                            .padding(.top, 18)
                    }
                    NavigationLink(value: event) {
                        NewActivtyCardView(
                            eventName: event.name,
                            eventDate: event.date,
                            imageURL: event.imageUrl,
                            imageName: .card1
                        )
                        .matchedTransitionSource(id: event.id, in: zoomNamespace)
                        .frame(height: min(612, geometry.size.height * 0.68))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.appSubheadline)
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 6)
    }
```

Note: the `NavigationStack` content already has `.environment(\.layoutDirection, .rightToLeft)`, so `alignment: .leading` renders on the right.

- [ ] **Step 5: Replace `eventBackgroundImage(currentPage:)` (lines 380–409)**

Replace the whole function with a static variant driven by the first (soonest) event:

```swift
    @ViewBuilder
    var nextEventBackground: some View {
        if let first = events.first, let resource = EventData.imageResource(for: first.imageUrl) {
            Image(resource)
                .resizable()
                .scaledToFill()
                .aspectRatio(4/3, contentMode: .fill)
        } else if let first = events.first,
                  let urlString = first.imageUrl,
                  urlString.hasPrefix("http"),
                  let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure, .empty:
                    Image(.card1).resizable().scaledToFill()
                @unknown default:
                    Image(.card1).resizable().scaledToFill()
                }
            }
            .aspectRatio(4/3, contentMode: .fill)
        } else {
            Image(.card1)
                .resizable()
                .scaledToFill()
                .aspectRatio(4/3, contentMode: .fill)
        }
    }
```

- [ ] **Step 6: Replace the toolbar (lines 125–154) with the new header**

Replace both `ToolbarItem` blocks (the whole `.toolbar { ... }` modifier) with:

```swift
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top) {
                HomeHeaderView(
                    avatarUrl: authVM?.currentProfile?.avatarUrl,
                    showsGroupControls: currentWorkspace != nil,
                    onMenu: { showSwitcher = true },
                    onUpcoming: { navigationPath.append(NavigationDestination.upcoming) },
                    onProfile: { showEditProfileSheet = true }
                )
            }
```

Important: keep the existing `.toolbarBackground(.hidden, for: .navigationBar)` line OR delete it — with the nav bar hidden it is inert; prefer deleting it. Pushed destinations (`EventHeroDetailView`, `NewEventView`, upcoming page) manage their own bars; `.toolbar(.hidden…)` on the root content applies only to this screen.

- [ ] **Step 7: Remove pager leftovers**

1. In `.onAppear` (lines 157–165): delete the `UIPageControl.appearance()` lines and the `#if canImport(UIKit)` / `#endif` around them (keep `Task { await authVM?.loadCurrentProfile() }`).
2. Delete `hapticMedium()` (lines 414–420) and the now-empty surrounding comment if any.
3. Delete the whole `eventPageProfileAvatar` computed property (lines 422–453) — `HomeHeaderView` owns the avatar now. If the `// MARK: - Haptics & Toolbar helpers` extension becomes empty, delete the extension.
4. In `loadEvents()` (lines 297–301): delete the `currentPage` adjustment block:

```swift
            if currentPage >= events.count && !events.isEmpty {
                currentPage = events.count - 1
            } else if events.isEmpty {
                currentPage = 0
            }
```

5. In the `showSwitcher` sheet's `onSelect` (line 231) and the `settingsWorkspace` sheet's `onLeftOrDeleted` (line 258): delete the `currentPage = 0` lines.

- [ ] **Step 8: Add the `.upcoming` destination (placeholder until Task 7)**

In `.navigationDestination(for: NavigationDestination.self)` (lines 206–216), extend the switch:

```swift
                case .upcoming:
                    // Replaced by UpcomingScheduleView in a later task.
                    Text("التمارين القادمة")
```

- [ ] **Step 9: Build to verify**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 10: Commit**

```bash
git add Sirr/pages/EventPageView.swift
git commit -m "feat(ios): vertical workout feed with section labels and new home header"
```

---

### Task 4: `GroupsDrawer` component

**Files:**
- Create: `Sirr/Components/GroupsDrawer.swift`

**Interfaces:**
- Consumes: `WorkspaceAvatar` (Task 1), `WorkspaceRecord` (existing: `id: UUID`, `name: String`, `memberCount: Int?`).
- Produces: `GroupsDrawer(isPresented: Binding<Bool>, workspaces: [WorkspaceRecord], currentId: UUID?, onSelect: (WorkspaceRecord) -> Void, onNewWorkout: () -> Void, onNewGroup: () -> Void, onOpenSettings: () -> Void)` — a full-screen overlay (dim + side panel). Task 5 embeds it in `EventPageView`'s outer `ZStack`.

- [ ] **Step 1: Create the file**

```swift
//
//  GroupsDrawer.swift
//  Sirr
//
//  Slide-in "المجموعات" panel (replaces the old half-sheet switcher).
//  Dark panel enters from the leading edge over a dimmed home. The blue +
//  creates a workout in the current group; "مجموعة جديدة" creates a group;
//  the gear opens the current group's settings (which also hosts logout).
//

import SwiftUI

struct GroupsDrawer: View {
    @Binding var isPresented: Bool
    let workspaces: [WorkspaceRecord]
    let currentId: UUID?
    var onSelect: (WorkspaceRecord) -> Void
    var onNewWorkout: () -> Void
    var onNewGroup: () -> Void
    var onOpenSettings: () -> Void

    /// Drag offset while the user swipes the panel toward the edge.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = geometry.size.width * 0.82

            ZStack(alignment: .leading) {
                // Dim layer — tap to close.
                if isPresented {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { close() }
                }

                // Panel. In RTL, .leading is the right edge — matching the mockup.
                panel(width: panelWidth, height: geometry.size.height)
                    .offset(x: isPresented ? dragOffset : -panelWidth)
                    .animation(.spring(response: 0.35, dampingFraction: 0.86), value: isPresented)
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // In RTL, dragging toward the leading edge closes.
                        let translation = value.translation.width
                        dragOffset = translation > 0 ? 0 : max(-panelWidth, translation)
                    }
                    .onEnded { value in
                        if value.translation.width < -panelWidth * 0.3 {
                            close()
                        }
                        dragOffset = 0
                    }
            )
        }
        .environment(\.layoutDirection, .rightToLeft)
        .allowsHitTesting(isPresented)
        .opacity(isPresented ? 1 : 0)
    }

    private func close() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            isPresented = false
        }
    }

    private func panel(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title row: "المجموعات" + blue + (new workout in current group).
            HStack {
                Text("المجموعات")
                    .font(.appSubheadline)
                    .foregroundStyle(.white)
                Spacer()
                if currentId != nil {
                    Button {
                        close()
                        onNewWorkout()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.blue))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(workspaces) { ws in
                        groupRow(ws)
                    }
                    newGroupRow
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
            }

            // Gear → combined settings of the current group (+ logout).
            HStack {
                Button {
                    close()
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .frame(width: width, height: height)
        .background(Color(white: 0.07))
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 28, topTrailingRadius: 28,
                style: .continuous
            )
        )
        .ignoresSafeArea(edges: .vertical)
    }

    private func groupRow(_ ws: WorkspaceRecord) -> some View {
        Button {
            close()
            onSelect(ws)
        } label: {
            HStack(spacing: 12) {
                WorkspaceAvatar(name: ws.name, id: ws.id, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ws.name)
                        .font(.appBodyMedium)
                        .foregroundStyle(.white)
                    if let count = ws.memberCount {
                        Text("الأعضاء \(count)")
                            .font(.appCaption)
                            .foregroundStyle(Color(white: 0.6))
                    }
                }
                Spacer()
                if ws.id == currentId {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(ws.id == currentId ? .white.opacity(0.16) : .white.opacity(0.07))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var newGroupRow: some View {
        Button {
            close()
            onNewGroup()
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 46, height: 46)
                    .overlay(Image(systemName: "plus").foregroundStyle(.white))
                Text("مجموعة جديدة")
                    .font(.appBodyMedium)
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white.opacity(0.07))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    struct DrawerPreview: View {
        @State var shown = true
        var body: some View {
            ZStack {
                Color.gray.ignoresSafeArea()
                GroupsDrawer(
                    isPresented: $shown,
                    workspaces: [],
                    currentId: nil,
                    onSelect: { _ in }, onNewWorkout: {}, onNewGroup: {}, onOpenSettings: {}
                )
            }
        }
    }
    return DrawerPreview()
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add Sirr/Components/GroupsDrawer.swift
git commit -m "feat(ios): slide-in groups drawer component"
```

---

### Task 5: Wire the drawer; delete the switcher sheet

**Files:**
- Modify: `Sirr/pages/EventPageView.swift`
- Delete: `Sirr/Components/WorkspaceSwitcherSheet.swift`

**Interfaces:**
- Consumes: `GroupsDrawer` (Task 4).
- Produces: hamburger opens the drawer; `showSwitcher` state renamed `showDrawer`; `WorkspaceSwitcherSheet` no longer exists anywhere. Settings opens for the CURRENT group only (drawer gear), so `settingsWorkspace` is set to `currentWorkspace`.

- [ ] **Step 1: Rename the state**

In `EventPageView.swift`, change `@State private var showSwitcher = false` to:

```swift
    @State private var showDrawer = false
```

and update the header wiring from Task 3: `onMenu: { showSwitcher = true }` becomes:

```swift
                    onMenu: { withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { showDrawer = true } },
```

- [ ] **Step 2: Remove the switcher sheet, add the drawer overlay**

Delete the entire `.sheet(isPresented: $showSwitcher) { WorkspaceSwitcherSheet(...) }` modifier block.

Add the drawer as the LAST child inside the top-level `ZStack` (after the `if/else` content branches, so it overlays everything including the header inset — place it as a sibling: the `ZStack` inside `GeometryReader`):

```swift
                    GroupsDrawer(
                        isPresented: $showDrawer,
                        workspaces: workspaces,
                        currentId: currentWorkspace?.id,
                        onSelect: { ws in
                            appState.currentWorkspaceId = ws.id
                        },
                        onNewWorkout: { navigationPath.append(NavigationDestination.newEvent) },
                        onNewGroup: { showCreateWorkspace = true },
                        onOpenSettings: {
                            if let ws = currentWorkspace { settingsWorkspace = ws }
                        }
                    )
                    .ignoresSafeArea()
```

Note: `onSelect` only sets `appState.currentWorkspaceId` — the existing `.task(id: appState.currentWorkspaceId)` reloads the feed; do NOT add a manual `loadEvents()` call here.

BUT: the drawer must not be trapped inside the `if/else` branches. Verify the final structure is:

```swift
            GeometryReader { geometry in
                ZStack {
                    if workspacesLoaded && workspaces.isEmpty {
                        ...
                    } else if events.isEmpty && !eventsLoading {
                        ...
                    } else {
                        ...
                    }
                    GroupsDrawer(...)   // ← sibling of the if/else, always present
                        .ignoresSafeArea()
                }
            }
```

- [ ] **Step 3: Delete the file**

```bash
git rm Sirr/Components/WorkspaceSwitcherSheet.swift
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`. If the build reports remaining references to `WorkspaceSwitcherSheet`, remove those call sites (there should be none after Step 2).

- [ ] **Step 5: Commit**

```bash
git add Sirr/pages/EventPageView.swift
git commit -m "feat(ios): wire groups drawer, remove half-sheet switcher"
```

---

### Task 6: Logout inside the settings sheet

**Files:**
- Modify: `Sirr/Components/WorkspaceSettingsSheet.swift`
- Modify: `Sirr/pages/EventPageView.swift` (call site)

**Interfaces:**
- Consumes: existing `WorkspaceSettingsSheet(workspace:currentUserId:onChanged:onLeftOrDeleted:)`.
- Produces: new parameter `onLogout: () -> Void`; an app-level section with "تسجيل الخروج" renders at the bottom of the sheet. This restores the logout control removed with the switcher sheet in Task 5 — after this task the app has exactly one logout entry point again.

- [ ] **Step 1: Add the callback and section**

In `Sirr/Components/WorkspaceSettingsSheet.swift`:

1. Add after the `onLeftOrDeleted` property declaration:

```swift
    /// App-level sign-out (this sheet doubles as the app's settings home).
    var onLogout: () -> Void
```

2. In the `ScrollView`'s `VStack(alignment: .leading, spacing: 24)` (the one listing `identitySection`, `inviteSection`, `membersSection`, `dangerSection`), add `appSection` after `dangerSection`:

```swift
                        dangerSection
                        appSection
```

3. Add the section implementation next to `dangerSection`:

```swift
    private var appSection: some View {
        VStack(spacing: 8) {
            Divider().overlay(Color(white: 0.25))
            Button {
                dismiss()
                onLogout()
            } label: {
                HStack {
                    Spacer()
                    Text("تسجيل الخروج")
                        .font(.appBody)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
        }
    }
```

- [ ] **Step 2: Update the call site**

In `Sirr/pages/EventPageView.swift`, the `.sheet(item: $settingsWorkspace)` block — add the new argument:

```swift
                WorkspaceSettingsSheet(
                    workspace: ws,
                    currentUserId: authVM?.currentProfile?.userId,
                    onChanged: { Task { await loadEvents() } },
                    onLeftOrDeleted: {
                        appState.currentWorkspaceId = nil
                        Task { await loadEvents() }
                    },
                    onLogout: {
                        Task { await authVM?.logout() }
                    }
                )
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add Sirr/Components/WorkspaceSettingsSheet.swift Sirr/pages/EventPageView.swift
git commit -m "feat(ios): logout row inside group settings sheet"
```

---

### Task 7: `UpcomingScheduleView`

**Files:**
- Create: `Sirr/pages/UpcomingScheduleView.swift`
- Modify: `Sirr/pages/EventPageView.swift` (replace the placeholder destination)

**Interfaces:**
- Consumes: `EventData` (existing: `id`, `name`, `date: String` display string, `startDate: Date`, `endDate: Date?`); pushed via `NavigationDestination.upcoming` (Task 3); `onSelect` appends the `EventData` to the same `navigationPath` so the existing `.navigationDestination(for: EventData.self)` opens the detail.
- Produces: `UpcomingScheduleView(events: [EventData], onSelect: (EventData) -> Void)`.

- [ ] **Step 1: Create the file**

```swift
//
//  UpcomingScheduleView.swift
//  Sirr
//
//  "التمارين القادمة" page: informational week strip (today highlighted, dot
//  on workout days), a detailed card for the next workout, then compact rows
//  for the rest. Reuses the already-loaded events — no fetching here.
//

import SwiftUI

struct UpcomingScheduleView: View {
    let events: [EventData]   // sorted by startDate ascending (home's order)
    var onSelect: (EventData) -> Void

    private static let arCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 1 // Sunday
        return c
    }()

    /// Day-name labels indexed by Calendar weekday (1=Sunday … 7=Saturday).
    private static let dayNames = ["", "أحد", "اثنين", "ثلاثاء", "أربعاء", "خميس", "جمعة", "سبت"]

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "ar")
        f.dateFormat = "MMMM"
        return f
    }()

    private static let cardDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "ar")
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "ar")
        f.timeStyle = .short
        return f
    }()

    private var nextEvent: EventData? { events.first }
    private var laterEvents: [EventData] { Array(events.dropFirst()) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                weekStrip
                if let next = nextEvent {
                    sectionTitle("التمرين الجاي")
                    nextCard(next)
                    if !laterEvents.isEmpty {
                        sectionTitle("التمارين القادمة")
                            .padding(.top, 8)
                        VStack(spacing: 12) {
                            ForEach(laterEvents) { event in
                                compactRow(event)
                            }
                        }
                    }
                } else {
                    Text("لا توجد تمارين قادمة")
                        .font(.appBody)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Color(white: 0.95).ignoresSafeArea())
        .navigationTitle("التمارين القادمة")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.layoutDirection, .rightToLeft)
    }

    // MARK: - Week strip (informational only)

    private var weekStrip: some View {
        let today = Date()
        let cal = Self.arCalendar
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        let workoutDays = Set(events.map { cal.startOfDay(for: $0.startDate) })

        return HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let isToday = cal.isDateInToday(day)
                let hasWorkout = workoutDays.contains(cal.startOfDay(for: day))
                VStack(spacing: 6) {
                    Text("\(cal.component(.day, from: day))")
                        .font(.appCallout)
                        .foregroundStyle(isToday ? .primary : .secondary)
                    Text(Self.dayNames[cal.component(.weekday, from: day)])
                        .font(.appCaption)
                        .foregroundStyle(isToday ? .primary : .secondary)
                    Circle()
                        .fill(hasWorkout ? Color.blue : Color.clear)
                        .frame(width: 5, height: 5)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isToday ? Color.black.opacity(0.06) : Color.clear)
                )
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Cards

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.appSubheadline)
            .foregroundStyle(.primary)
    }

    private func nextCard(_ event: EventData) -> some View {
        Button { onSelect(event) } label: {
            HStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text(daysRemainingValue(to: event.startDate))
                        .font(.appHeadline)
                        .foregroundStyle(.primary)
                    Text(daysRemainingUnit(to: event.startDate))
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 52)

                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1, height: 56)

                VStack(alignment: .leading, spacing: 6) {
                    Text(event.name)
                        .font(.appBodySemibold)
                        .foregroundStyle(.primary)
                    Text(Self.cardDateFormatter.string(from: event.startDate))
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    if let end = event.endDate {
                        Text("من \(Self.timeFormatter.string(from: event.startDate)) ← إلى \(Self.timeFormatter.string(from: end))")
                            .font(.appCaption)
                            .foregroundStyle(.primary.opacity(0.8))
                    }
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func compactRow(_ event: EventData) -> some View {
        Button { onSelect(event) } label: {
            HStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text("\(Self.arCalendar.component(.day, from: event.startDate))")
                        .font(.appBodySemibold)
                        .foregroundStyle(.primary)
                    Text(Self.monthFormatter.string(from: event.startDate))
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 52)

                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1, height: 36)

                Text(event.name)
                    .font(.appBodyMedium)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Days remaining (Arabic plural forms)

    private func daysBetweenTodayAnd(_ date: Date) -> Int {
        let cal = Self.arCalendar
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
    }

    private func daysRemainingValue(to date: Date) -> String {
        let d = daysBetweenTodayAnd(date)
        switch d {
        case 0: return "اليوم"
        case 1: return "غدًا"
        case 2: return "يومين"
        default: return "\(d)"
        }
    }

    private func daysRemainingUnit(to date: Date) -> String {
        let d = daysBetweenTodayAnd(date)
        switch d {
        case 0, 1, 2: return ""
        case 3...10: return "أيام"
        default: return "يوم"
        }
    }
}

#Preview {
    NavigationStack {
        UpcomingScheduleView(
            events: [
                EventData(id: UUID(), name: "تمرين الأسبوع", date: "", startDate: Date().addingTimeInterval(86400 * 5), endDate: Date().addingTimeInterval(86400 * 5 + 7200)),
                EventData(id: UUID(), name: "تمرين الأسبوع", date: "", startDate: Date().addingTimeInterval(86400 * 12), endDate: nil)
            ],
            onSelect: { _ in }
        )
    }
}
```

- [ ] **Step 2: Replace the placeholder destination**

In `Sirr/pages/EventPageView.swift`, `.navigationDestination(for: NavigationDestination.self)`, replace:

```swift
                case .upcoming:
                    // Replaced by UpcomingScheduleView in a later task.
                    Text("التمارين القادمة")
```

with:

```swift
                case .upcoming:
                    UpcomingScheduleView(events: events) { event in
                        navigationPath.append(event)
                    }
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add Sirr/pages/UpcomingScheduleView.swift Sirr/pages/EventPageView.swift
git commit -m "feat(ios): upcoming schedule page with week strip and workout rows"
```

---

### Task 8: Copy sweep — مساحة → مجموعة, فعالية → تمرين

**Files:**
- Modify: `Sirr/pages/EventPageView.swift`
- Modify: `Sirr/Components/CreateWorkspaceSheet.swift`
- Modify: `Sirr/Components/WorkspaceSettingsSheet.swift`
- Modify: `Sirr/pages/JoinWorkspaceView.swift`
- Modify: `Sirr/pages/SharedEventView.swift`
- Modify: `Sirr/pages/NewEventView.swift`

**Interfaces:** none — user-facing strings only. Do NOT rename types, files, properties, or RPC names (they keep "Workspace"/"workspace"). DB data (existing group names like "مساحتي") is untouched.

- [ ] **Step 1: Apply the replacements**

Exact old → new strings (find each old string verbatim; some may already be partially updated — skip any that no longer exist and note it):

`Sirr/pages/EventPageView.swift`:
| Old | New |
|---|---|
| `لا توجد فعاليات في \(currentWorkspace?.name ?? "المساحة")` | `لا توجد تمارين في \(currentWorkspace?.name ?? "المجموعة")` |
| `أنشئ فعالية أو انضم إلى واحدة` | `أنشئ تمرينًا أو انضم إلى واحد` |
| `إنشاء فعالية` | `إنشاء تمرين` |
| `ابدأ مساحتك الأولى` | `ابدأ مجموعتك الأولى` |
| `المساحة هي مجموعتك — أنشئ واحدة لشلّتك\nأو انضم برابط دعوة من صديق` | `المجموعة لك ولأصحابك — أنشئ واحدة لشلّتك\nأو انضم برابط دعوة من صديق` |
| `إنشاء مساحة` | `إنشاء مجموعة` |
| `هذا الحدث في مساحة خاصة.\nاطلب دعوة من صاحب المساحة للانضمام.` | `هذا التمرين في مجموعة خاصة.\nاطلب دعوة من صاحب المجموعة للانضمام.` |
| `تعذر فتح الحدث` | `تعذر فتح التمرين` |

`Sirr/Components/CreateWorkspaceSheet.swift`:
| Old | New |
|---|---|
| `مساحة جديدة` | `مجموعة جديدة` |
| `اسم المساحة` | `اسم المجموعة` |
| `تعذر إنشاء المساحة. حاول مرة أخرى.` | `تعذر إنشاء المجموعة. حاول مرة أخرى.` |

`Sirr/Components/WorkspaceSettingsSheet.swift` (every occurrence):
| Old | New |
|---|---|
| `إعدادات المساحة` | `إعدادات المجموعة` |
| `إعادة تسمية المساحة` | `إعادة تسمية المجموعة` |
| `حذف المساحة` | `حذف المجموعة` (occurs 2×: dialog title area + button) |
| `مغادرة المساحة` | `مغادرة المجموعة` (occurs 2×) |
| `سيتم حذف المساحة وجميع أحداثها ومشاركيها نهائيًا. لا يمكن التراجع.` | `سيتم حذف المجموعة وجميع تمارينها ومشاركيها نهائيًا. لا يمكن التراجع.` |
| `ستفقد الوصول إلى أحداث هذه المساحة وستُزال من الأحداث القادمة.` | `ستفقد الوصول إلى تمارين هذه المجموعة وستُزال من التمارين القادمة.` |
| `سيفقد \(memberToRemove?.displayName ?? "العضو") الوصول إلى المساحة وسيُزال من الأحداث القادمة.` | `سيفقد \(memberToRemove?.displayName ?? "العضو") الوصول إلى المجموعة وسيُزال من التمارين القادمة.` |

`Sirr/pages/JoinWorkspaceView.swift`:
| Old | New |
|---|---|
| `دعوة إلى مساحة` | `دعوة إلى مجموعة` |
| `أنت عضو في هذه المساحة` | `أنت عضو في هذه المجموعة` |
| `فتح المساحة` | `فتح المجموعة` |
| `رابط الدعوة غير صالح أو تم إبطاله.\nاطلب رابطًا جديدًا من صاحب المساحة.` | `رابط الدعوة غير صالح أو تم إبطاله.\nاطلب رابطًا جديدًا من صاحب المجموعة.` |

`Sirr/pages/SharedEventView.swift`:
| Old | New |
|---|---|
| `هذا الحدث في مساحة خاصة.\nاطلب دعوة من صاحب المساحة للانضمام.` | `هذا التمرين في مجموعة خاصة.\nاطلب دعوة من صاحب المجموعة للانضمام.` |

`Sirr/pages/NewEventView.swift`:
| Old | New |
|---|---|
| `تعذر تحديد المساحة الحالية. أعد فتح التطبيق وحاول مرة أخرى.` | `تعذر تحديد المجموعة الحالية. أعد فتح التطبيق وحاول مرة أخرى.` |

- [ ] **Step 2: Verify nothing was missed**

Run: `grep -rn "مساحة\|مساحتك\|المساحات\|مساحاتك" Sirr --include="*.swift"`
Expected: NO matches in user-facing string literals. Comments mentioning مساحة may remain but prefer updating them too. If a hit appears in a file not listed above, update it with the same terminology and record it in the commit message.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add -A Sirr
git commit -m "feat(ios): rename copy to مجموعة/تمرين across touched screens"
```

---

### Task 9: Final verification

**Files:** none — verification only.

- [ ] **Step 1: Clean build**

Run: `xcodebuild -project Sirr.xcodeproj -scheme Sirr -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 2: Simulator visual pass** (signing in requires the user's Apple account — hand the checklist to the user if sign-in is unavailable to you)

1. Home: vertical scroll; التمرين الجاي above the first card, التمارين القادمة above the second onward; static blurred backdrop; card tap zooms into detail.
2. Header: hamburger opens the drawer; pill pushes the upcoming page; avatar opens the profile sheet. Zero-group account: only the avatar shows.
3. Upcoming page: week strip highlights today, dots on workout days; next-workout card shows date, من/إلى times, days-remaining; compact rows for the rest; row tap opens detail.
4. Drawer: groups listed with member counts, current highlighted; tap switches and feed reloads; blue + opens create-workout; مجموعة جديدة opens create-group; gear opens settings.
5. Settings sheet: all group actions work; تسجيل الخروج at the bottom signs out (critical: this is the app's only logout).
6. Copy: no مساحة anywhere in the UI; touched screens say تمرين/تمارين.
7. Regressions: push-tap/deep-link event still opens detail (switching group if needed); invite join flow unchanged; create-workout from empty group state works.

- [ ] **Step 3: Report results** — any failing step is a bug to fix before the feature is called done.

---

## Self-Review Notes

- Spec coverage: home feed + labels + static background (T3), header (T2+T3), upcoming page incl. week strip/dots/days-remaining (T7), drawer incl. + = workout / مجموعة جديدة row / gear (T4+T5), combined settings + logout (T6), copy sweep (T8), verification (T9). Zero backend changes throughout.
- Deliberate implementation choices: header uses `.toolbar(.hidden)` + `.safeAreaInset(edge: .top)` instead of toolbar items (the mockup's floating pills don't fit `ToolbarItem` sizing); the drawer overlays the dimmed home without shifting it (the spec's "shifts slightly aside" is dropped for simplicity — flag to the user at review if they want the push-aside effect added).
- Logout continuity: Task 5 removes the switcher (old logout home) and Task 6 restores logout in settings — Tasks 5 and 6 must both land before any release build; the plan orders them adjacently on purpose.
