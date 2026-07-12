# Side Menu (Mock) — Increment 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the Home header's ☰ button (and a right-edge swipe) to a ported designer side-menu drawer with live team switching on mock data; other destinations are stubbed.

**Architecture:** Continues Increments 1–2. `MockHomeFeed` goes multi-team (teams + selected id + per-team occurrences). A new `TeamSideMenu` drawer binds to it. `DesignerHomeView` wraps its content in the designer's slide-out reveal (offset/scale/corner/dim transform + right-edge-swipe gesture); the menu's payments/settings/notifications/create-team buttons raise a "قريبًا" alert.

**Tech Stack:** Swift, SwiftUI, iOS 26 SDK (Liquid Glass), Xcode 26. `Sirr.xcodeproj` uses file-system-synchronized folders — new `.swift` files under `Sirr/` are auto-included.

## Global Constraints

- **Branch:** `feat/designer-ui-home` (checked out in the worktree). All work and commits happen here.
- **Work tree (`$WT`):** `/Users/naifalialshahrani/Documents/tamrin-designer-ui`. Designer reference: `/Users/naifalialshahrani/Documents/tamrin/tamrin.test2/HomeViews.swift` (`TeamSideMenu` ~476–681; drawer mechanics in `HomeView` ~42–286).
- **Mock only:** no `EventService`/Supabase calls. Team switching mutates `MockHomeFeed` in memory.
- **Admin omitted; experience switcher dropped; notifications bell has no badge.**
- **Verification model:** pure SwiftUI on mock state, no test target (consistent with prior increments). Per-task verification = a clean compile of the `Sirr` scheme with a generic simulator destination that never boots a simulator, plus SwiftUI `#Preview`. Final on-device testing by Naif.
- **Compile command (the "test" in every task):**
  ```bash
  cd "$WT" && xcodebuild -project Sirr.xcodeproj -scheme Sirr \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet
  ```
  where `WT=/Users/naifalialshahrani/Documents/tamrin-designer-ui`. Success ends in `** BUILD SUCCEEDED **`. SourceKit may emit spurious "cannot find X in scope" diagnostics for cross-file symbols — trust the `xcodebuild` result and the absence of `error:` lines.
- **Language/RTL:** Arabic-first; ported views keep `.environment(\.layoutDirection, .rightToLeft)` and `.colorScheme(.dark)`.

---

### Task 1: Multi-team mock model

Make `MockHomeFeed` multi-team so switching is meaningful. `FeedTeam` becomes identifiable; `occurrences`/`currentTeam` become computed off `selectedTeamID`. The one-line `DesignerHomeView` reference to `feed.team` is updated in the same task so it keeps compiling.

**Files:**
- Modify: `$WT/Sirr/features/home/MockHomeFeed.swift` (full rewrite)
- Modify: `$WT/Sirr/features/home/DesignerHomeView.swift:66` (`feed.team` → `feed.currentTeam`)

**Interfaces:**
- Produces:
  - `struct FeedTeam: Identifiable { let id: UUID; let name: String; let symbol: String; let avatarData: Data?; let memberCount: Int }`
  - `MockHomeFeed`: `var teams: [FeedTeam]`, `var selectedTeamID: UUID`, `var occurrencesByTeam: [UUID: [FeedOccurrence]]`, computed `var currentTeam: FeedTeam`, computed `var occurrences: [FeedOccurrence]`, `func selectTeam(_ id: UUID)`. Unchanged: `rosters`, `profileName`, `currentUserName`, `roster/registeredCount/waitlistCount/myRegistration/register/withdraw`.
  - `FeedRegStatus`, `FeedMember`, `FeedOccurrence` unchanged from Increment 2.

- [ ] **Step 1: Rewrite `MockHomeFeed.swift`**

Replace the entire contents of `$WT/Sirr/features/home/MockHomeFeed.swift` with:

```swift
import SwiftUI

/// Value types the reskinned Home feed reads. This whole file is the
/// integration seam: a later increment replaces the mock body of
/// `MockHomeFeed` with EventService/WorkspaceService calls that map records
/// into these types, leaving every view unchanged.
struct FeedTeam: Identifiable {
    let id: UUID
    let name: String
    let symbol: String
    let avatarData: Data?
    let memberCount: Int
}

enum FeedRegStatus {
    case registered
    case waitlisted
}

struct FeedMember: Identifiable {
    let id: UUID
    let name: String
    var status: FeedRegStatus
}

struct FeedOccurrence: Identifiable {
    let id: UUID
    let title: String
    let startAt: Date
    let locationName: String
    let capacity: Int
    let price: Double        // 0 == free
    let isCancelled: Bool
    let artIndex: Int        // cycles ExerciseArt1..3
}

@MainActor
@Observable
final class MockHomeFeed {
    var teams: [FeedTeam]
    var selectedTeamID: UUID
    var occurrencesByTeam: [UUID: [FeedOccurrence]]
    var rosters: [UUID: [FeedMember]]
    var profileName: String
    let currentUserName = "نايف"

    var currentTeam: FeedTeam { teams.first { $0.id == selectedTeamID } ?? teams[0] }
    var occurrences: [FeedOccurrence] { occurrencesByTeam[selectedTeamID] ?? [] }

    init() {
        profileName = "نايف"

        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        func at(_ days: Int, _ hour: Int) -> Date {
            let base = cal.date(byAdding: .day, value: days, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        }

        let teamA = FeedTeam(id: UUID(), name: "رفاق الملعب", symbol: "figure.run", avatarData: nil, memberCount: 12)
        let teamB = FeedTeam(id: UUID(), name: "نادي الفجر", symbol: "figure.cooldown", avatarData: nil, memberCount: 8)
        let teamC = FeedTeam(id: UUID(), name: "الصقور", symbol: "bird", avatarData: nil, memberCount: 5)
        teams = [teamA, teamB, teamC]
        selectedTeamID = teamA.id

        let a1 = FeedOccurrence(id: UUID(), title: "كورة الثلاثاء", startAt: at(2, 20),
                                locationName: "ملعب النخيل", capacity: 14, price: 25, isCancelled: false, artIndex: 0)
        let a2 = FeedOccurrence(id: UUID(), title: "تمرين الجري", startAt: at(4, 6),
                                locationName: "كورنيش الرياض", capacity: 20, price: 0, isCancelled: false, artIndex: 1)
        let a3 = FeedOccurrence(id: UUID(), title: "كورة نهاية الأسبوع", startAt: at(6, 18),
                                locationName: "ملعب الروضة", capacity: 12, price: 30, isCancelled: false, artIndex: 2)
        let b1 = FeedOccurrence(id: UUID(), title: "تمرين الصباح", startAt: at(1, 7),
                                locationName: "منتزه السلام", capacity: 16, price: 0, isCancelled: false, artIndex: 1)
        let b2 = FeedOccurrence(id: UUID(), title: "مباراة ودية", startAt: at(3, 21),
                                locationName: "ملعب الأمير", capacity: 22, price: 20, isCancelled: false, artIndex: 2)

        occurrencesByTeam = [
            teamA.id: [a1, a2, a3],
            teamB.id: [b1, b2],
            teamC.id: [],
        ]

        func members(_ names: [String], _ status: FeedRegStatus = .registered) -> [FeedMember] {
            names.map { FeedMember(id: UUID(), name: $0, status: status) }
        }
        let pool = ["سلطان", "عبدالله", "فهد", "تركي", "ماجد", "خالد", "نواف",
                    "سعود", "بندر", "ريان", "عمر", "يزيد", "راكان", "مشعل"]

        rosters = [
            a1.id: members(Array(pool.prefix(9))),
            a2.id: members(Array(pool.prefix(12))),
            a3.id: members(Array(pool.prefix(12))) + members(["زياد"], .waitlisted),
            b1.id: members(Array(pool.prefix(5))),
            b2.id: members(Array(pool.prefix(7))),
        ]
    }

    func roster(for occurrence: FeedOccurrence) -> [FeedMember] {
        rosters[occurrence.id] ?? []
    }

    func registeredCount(for occurrence: FeedOccurrence) -> Int {
        roster(for: occurrence).filter { $0.status == .registered }.count
    }

    func waitlistCount(for occurrence: FeedOccurrence) -> Int {
        roster(for: occurrence).filter { $0.status == .waitlisted }.count
    }

    func myRegistration(for occurrence: FeedOccurrence) -> FeedMember? {
        roster(for: occurrence).first { $0.name == currentUserName }
    }

    /// Local mock join: no-op if already on the list; registers when there is
    /// room, otherwise waitlists.
    func register(for occurrence: FeedOccurrence) {
        var list = rosters[occurrence.id] ?? []
        guard !list.contains(where: { $0.name == currentUserName }) else { return }
        let registered = list.filter { $0.status == .registered }.count
        let status: FeedRegStatus = registered >= occurrence.capacity ? .waitlisted : .registered
        list.append(FeedMember(id: UUID(), name: currentUserName, status: status))
        rosters[occurrence.id] = list
    }

    /// Local mock leave: removes the current user; if they held a registered
    /// seat, promotes the first waitlisted member.
    func withdraw(from occurrence: FeedOccurrence) {
        var list = rosters[occurrence.id] ?? []
        guard let mine = list.firstIndex(where: { $0.name == currentUserName }) else { return }
        let freedSeat = list[mine].status == .registered
        list.remove(at: mine)
        if freedSeat, let promote = list.firstIndex(where: { $0.status == .waitlisted }) {
            list[promote].status = .registered
        }
        rosters[occurrence.id] = list
    }

    func selectTeam(_ id: UUID) {
        selectedTeamID = id
    }
}
```

- [ ] **Step 2: Update the header team reference in `DesignerHomeView`**

In `$WT/Sirr/features/home/DesignerHomeView.swift`, replace:
```swift
                        team: feed.team,
```
with:
```swift
                        team: feed.currentTeam,
```

- [ ] **Step 3: Build-check**

Run the Global-Constraints compile command. Expected: `** BUILD SUCCEEDED **`, no `error:` lines.

- [ ] **Step 4: Commit**

```bash
cd /Users/naifalialshahrani/Documents/tamrin-designer-ui
git add Sirr/features/home/MockHomeFeed.swift Sirr/features/home/DesignerHomeView.swift
git commit -m "feat(home): multi-team MockHomeFeed with selectTeam"
```

---

### Task 2: TeamSideMenu drawer view

Port the designer's `TeamSideMenu` (member view) to a new file, bound to `MockHomeFeed`, minus the experience switcher.

**Files:**
- Create: `$WT/Sirr/features/home/TeamSideMenu.swift`

**Interfaces:**
- Consumes: `MockHomeFeed`, `FeedTeam` (Task 1); `TamrinFont`, `TamrinTheme`, `TeamAvatarView` (Increment 1).
- Produces: `struct TeamSideMenu: View { @Bindable var feed: MockHomeFeed; let close, createTeam, openSettings, openPayments, openNotifications: () -> Void; let onSelectTeam: (UUID) -> Void }`.

- [ ] **Step 1: Create `TeamSideMenu.swift`**

Create `$WT/Sirr/features/home/TeamSideMenu.swift`:

```swift
import SwiftUI

/// Ported side-menu drawer (designer TeamSideMenu, member view) bound to
/// MockHomeFeed. Team selection is live; create-team / payments / settings /
/// notifications are stubbed by the parent via the callbacks below. The
/// admin/member experience switcher is intentionally dropped.
struct TeamSideMenu: View {
    @Bindable var feed: MockHomeFeed
    let close: () -> Void
    let createTeam: () -> Void
    let openSettings: () -> Void
    let openPayments: () -> Void
    let openNotifications: () -> Void
    let onSelectTeam: (UUID) -> Void

    var body: some View {
        GeometryReader { proxy in
            let menuWidth = min(proxy.size.width - 94, 308)

            ZStack {
                Color(red: 0.067, green: 0.067, blue: 0.067).ignoresSafeArea()

                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center, spacing: 14) {
                        Text("المجموعات")
                            .font(TamrinFont.font(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        Button(action: createTeam) {
                            Label("إنشاء مجموعة", systemImage: "plus").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .tint(.blue)
                        .accessibilityLabel("إنشاء مجموعة")
                    }
                    .frame(width: menuWidth)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 8) {
                            ForEach(feed.teams) { team in
                                Button {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    onSelectTeam(team.id)
                                } label: {
                                    TeamSideMenuRow(team: team, isSelected: team.id == feed.selectedTeamID)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(width: menuWidth)
                    }
                    .frame(maxHeight: proxy.size.height * 0.46)

                    Button(action: openPayments) {
                        HStack(spacing: 12) {
                            Image(systemName: "creditcard.fill")
                                .frame(width: 34, height: 34)
                                .background(.white.opacity(0.1), in: .circle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("دفعاتي")
                                    .font(TamrinFont.font(size: 15, weight: .bold))
                                Text("تابع القَطّات القادمة")
                                    .font(TamrinFont.font(size: 11, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer()
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(width: menuWidth, height: 64)
                        .background(.white.opacity(0.07), in: .rect(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
                .padding(.top, max(proxy.safeAreaInsets.top + 40, 82))
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Button(action: openSettings) {
                            HStack(spacing: 10) {
                                MenuProfileAvatar(name: feed.profileName)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(feed.profileName.isEmpty ? "حسابي" : feed.profileName)
                                        .font(TamrinFont.font(size: 14, weight: .bold))
                                    Text("الملف الشخصي")
                                        .font(TamrinFont.font(size: 10, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .accessibilityLabel("الملف الشخصي")

                        Button(action: openNotifications) {
                            Image(systemName: "bell.fill").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .accessibilityLabel("التنبيهات")
                    }
                    .frame(width: menuWidth)
                }
                .padding(.leading, 16)
                .padding(.bottom, max(proxy.safeAreaInsets.bottom + 24, 40))
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .colorScheme(.dark)
    }
}

private struct TeamSideMenuRow: View {
    let team: FeedTeam
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            TeamAvatarView(
                avatarData: team.avatarData,
                symbol: team.symbol,
                size: 56,
                cornerRadiusRatio: 12 / 56,
                fallbackBackground: AnyShapeStyle(
                    LinearGradient(
                        colors: [
                            isSelected ? Color(red: 0.86, green: 0.92, blue: 0.78) : Color(red: 0.80, green: 0.83, blue: 0.72),
                            Color(red: 0.95, green: 0.95, blue: 0.84)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                ),
                symbolColor: Color(red: 0.10, green: 0.13, blue: 0.10)
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(team.name)
                    .font(TamrinFont.font(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("الأعضاء  \(team.memberCount)")
                    .font(TamrinFont.font(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .frame(height: 20, alignment: .center)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            isSelected ? Color(red: 0.16, green: 0.18, blue: 0.13) : Color(red: 0.10, green: 0.10, blue: 0.10),
            in: .rect(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(TamrinTheme.lime.opacity(0.6), lineWidth: 1.5)
            }
        }
    }
}

private struct MenuProfileAvatar: View {
    let name: String
    var body: some View {
        Circle()
            .fill(.white.opacity(0.18))
            .frame(width: 36, height: 36)
            .overlay {
                Text(String(name.prefix(1)))
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    TeamSideMenu(feed: MockHomeFeed(), close: {}, createTeam: {}, openSettings: {},
                 openPayments: {}, openNotifications: {}, onSelectTeam: { _ in })
}
```

- [ ] **Step 2: Build-check**

Run the Global-Constraints compile command. Expected: `** BUILD SUCCEEDED **`, no `error:` lines.

- [ ] **Step 3: Commit**

```bash
cd /Users/naifalialshahrani/Documents/tamrin-designer-ui
git add Sirr/features/home/TeamSideMenu.swift
git commit -m "feat(home): TeamSideMenu drawer with team list (mock)"
```

---

### Task 3: Drawer mechanics in DesignerHomeView

Wrap the home content in the designer's slide-out reveal, wire the ☰ button and right-edge swipe, present `TeamSideMenu`, switch teams, and stub the other destinations with a "قريبًا" alert.

**Files:**
- Modify: `$WT/Sirr/features/home/DesignerHomeView.swift` (full rewrite of the file)

**Interfaces:**
- Consumes: `TeamSideMenu` (Task 2); `MockHomeFeed.currentTeam/selectTeam` (Task 1); existing `EventPosterCard`, `EventDetailView`, `StickyHomeHeader`, `HomeArtBackdrop`, `ScrollHintChevron` (prior increments).

- [ ] **Step 1: Replace `DesignerHomeView.swift`**

Replace the entire contents of `$WT/Sirr/features/home/DesignerHomeView.swift` with:

```swift
import SwiftUI

/// Reskinned Home feed (designer look) on mock data, with the ported side-menu
/// drawer (open via the header ☰ button or a right-edge swipe) and live team
/// switching. Deferred to later increments: real backend wiring, plan-template
/// detail, and the payments / settings / notifications / create-team screens
/// (their menu entries raise a "قريبًا" placeholder alert).
struct DesignerHomeView: View {
    @State private var feed = MockHomeFeed()
    @State private var scrolledID: UUID?
    @State private var selected: FeedOccurrence?
    @Namespace private var cardZoom

    @State private var isMenuOpen = false
    @State private var menuDragProgress: CGFloat = 0
    @State private var didMenuHaptic = false
    @State private var comingSoon: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentIndex: Int {
        guard let id = scrolledID,
              let idx = feed.occurrences.firstIndex(where: { $0.id == id }) else { return 0 }
        return idx
    }

    private func artName(_ index: Int) -> String { "ExerciseArt\((index % 3) + 1)" }

    var body: some View {
        GeometryReader { proxy in
            let revealDistance = min(proxy.size.width * 0.84, 340)
            let progress = menuProgress()
            let pageCorner = 44 * progress

            ZStack(alignment: .leading) {
                TeamSideMenu(
                    feed: feed,
                    close: { setMenu(open: false) },
                    createTeam: { setMenu(open: false); comingSoon = "إنشاء مجموعة" },
                    openSettings: { setMenu(open: false); comingSoon = "الإعدادات" },
                    openPayments: { setMenu(open: false); comingSoon = "الدفعات" },
                    openNotifications: { setMenu(open: false); comingSoon = "التنبيهات" },
                    onSelectTeam: { id in feed.selectTeam(id); setMenu(open: false) }
                )

                mainContent
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipShape(.rect(cornerRadius: pageCorner, style: .continuous))
                    .shadow(color: .black.opacity(0.34 * progress), radius: 32 * progress, x: 14 * progress, y: 0)
                    .overlay {
                        if progress > 0.02 {
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture { setMenu(open: false) }
                        }
                    }
                    .opacity(Double(1.0 - 0.18 * progress))
                    .scaleEffect(1 - (0.045 * progress), anchor: .trailing)
                    .offset(x: revealDistance * progress)
                    .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86), value: progress)
            }
            .background(Color(red: 0.067, green: 0.067, blue: 0.067))
            .ignoresSafeArea()
            .simultaneousGesture(menuGesture(revealDistance: revealDistance, screenWidth: proxy.size.width))
        }
        .ignoresSafeArea()
        .alert("قريبًا", isPresented: Binding(
            get: { comingSoon != nil },
            set: { if !$0 { comingSoon = nil } }
        )) {
            Button("حسنًا", role: .cancel) { comingSoon = nil }
        } message: {
            Text("\(comingSoon ?? "") — تحت التطوير")
        }
    }

    private var mainContent: some View {
        ZStack {
            TamrinTheme.page.ignoresSafeArea()

            ZStack(alignment: .topTrailing) {
                HomeArtBackdrop(artName: artName(currentIndex), hasArt: !feed.occurrences.isEmpty)

                Group {
                    if feed.occurrences.isEmpty {
                        ScrollView(showsIndicators: false) {
                            EmptyScheduleCard()
                                .padding(.horizontal, 20)
                                .padding(.top, 6)
                        }
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 110) {
                                ForEach(feed.occurrences.prefix(6)) { occurrence in
                                    EventPosterCard(occurrence: occurrence, registeredCount: feed.registeredCount(for: occurrence)) {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        selected = occurrence
                                    }
                                    .containerRelativeFrame(.vertical, alignment: .top) { length, _ in
                                        max(length - 64, 320)
                                    }
                                    .matchedTransitionSource(id: occurrence.id, in: cardZoom)
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.horizontal, 20)
                        }
                        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                        .scrollPosition(id: $scrolledID)
                    }
                }
                .overlay(alignment: .bottom) {
                    if feed.occurrences.count > 1, currentIndex == 0 {
                        ScrollHintChevron()
                            .padding(.bottom, 2)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: currentIndex)
                .safeAreaInset(edge: .top, spacing: 0) {
                    StickyHomeHeader(
                        team: feed.currentTeam,
                        profileName: feed.profileName,
                        sectionTitle: feed.occurrences.isEmpty
                            ? nil
                            : (currentIndex == 0 ? "التمرين الجاي" : "التمارين القادمة"),
                        openMenu: { setMenu(open: true) },
                        openPlan: {},
                        openProfile: {}
                    )
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .fullScreenCover(item: $selected) { occ in
            EventDetailView(feed: feed, occurrence: occ, artName: artName(occ.artIndex))
                .navigationTransition(.zoom(sourceID: occ.id, in: cardZoom))
        }
    }

    private func menuProgress() -> CGFloat {
        let base: CGFloat = isMenuOpen ? 1 : 0
        return min(max(base + menuDragProgress, 0), 1)
    }

    private func setMenu(open: Bool) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            isMenuOpen = open
            menuDragProgress = 0
        }
        didMenuHaptic = false
    }

    private func menuGesture(revealDistance: CGFloat, screenWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                let startsAtRightEdge = value.startLocation.x > screenWidth - 34
                guard isMenuOpen || startsAtRightEdge else { return }
                if isMenuOpen {
                    menuDragProgress = min(max(-value.translation.width / revealDistance, -1), 0)
                } else {
                    menuDragProgress = min(max(-value.translation.width / revealDistance, 0), 1)
                }
                if menuProgress() > 0.78, !didMenuHaptic {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.65)
                    didMenuHaptic = true
                }
            }
            .onEnded { value in
                let predicted = isMenuOpen
                    ? 1 + min(max(-value.predictedEndTranslation.width / revealDistance, -1), 0)
                    : min(max(-value.predictedEndTranslation.width / revealDistance, 0), 1)
                setMenu(open: predicted > 0.46)
            }
    }
}

private struct HomeArtBackdrop: View {
    let artName: String
    let hasArt: Bool

    var body: some View {
        ZStack {
            Color(red: 0.16, green: 0.155, blue: 0.13)
            if hasArt {
                GeometryReader { proxy in
                    Image(artName)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: 58, opaque: true)
                        .scaleEffect(1.22)
                        .clipped()
                        .overlay(Color.black.opacity(0.46))
                }
                .id(artName)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: artName)
        .accessibilityHidden(true)
    }
}

private struct ScrollHintChevron: View {
    @State private var bounce = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.compact.down")
            .font(.system(size: 25, weight: .semibold))
            .foregroundStyle(.white.opacity(0.62))
            .shadow(color: .black.opacity(0.4), radius: 7, y: 2)
            .offset(y: bounce ? 4 : -3)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.05).repeatForever(autoreverses: true), value: bounce)
            .onAppear { bounce = true }
            .accessibilityHidden(true)
    }
}

private struct StickyHomeHeader: View {
    let team: FeedTeam
    let profileName: String
    let sectionTitle: String?
    let openMenu: () -> Void
    let openPlan: () -> Void
    let openProfile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassEffectContainer(spacing: 14) {
                HomeTopBar(team: team, profileName: profileName,
                           openMenu: openMenu, openPlan: openPlan, openProfile: openProfile)
            }
            if let sectionTitle {
                Text(sectionTitle)
                    .font(TamrinFont.font(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 6)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: sectionTitle)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .colorScheme(.dark)
    }
}

private struct HomeTopBar: View {
    let team: FeedTeam
    let profileName: String
    let openMenu: () -> Void
    let openPlan: () -> Void
    let openProfile: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: openMenu) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("المجموعات")

            Button(action: openPlan) {
                HStack(spacing: 9) {
                    Text(team.name)
                        .font(TamrinFont.font(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.74)
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18).frame(height: 48)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityLabel("تفاصيل قالب التمرين")

            Spacer(minLength: 0)

            Button(action: openProfile) {
                Circle()
                    .fill(.white.opacity(0.92))
                    .frame(width: 44, height: 44)
                    .overlay {
                        if profileName.isEmpty {
                            Image(systemName: "person.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(TamrinTheme.ink.opacity(0.7))
                        } else {
                            Text(String(profileName.prefix(1)))
                                .font(TamrinFont.font(size: 18, weight: .bold))
                                .foregroundStyle(TamrinTheme.ink)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("الملف الشخصي والإعدادات")
        }
    }
}

#Preview {
    DesignerHomeView()
}
```

- [ ] **Step 2: Final build-check**

Run the Global-Constraints compile command. Expected: `** BUILD SUCCEEDED **`, no `error:` lines.

- [ ] **Step 3: Commit**

```bash
cd /Users/naifalialshahrani/Documents/tamrin-designer-ui
git add Sirr/features/home/DesignerHomeView.swift
git commit -m "feat(home): side-menu drawer + edge-swipe + team switching"
```

- [ ] **Step 4: Hand off to Naif for on-device testing**

Report the increment is built and compiling. Ask Naif to run the `Sirr` scheme on device and verify: the ☰ button opens the drawer (main content slides/scales, corner rounds, dims); a right-edge swipe drags it open/closed with a haptic near fully-open; tapping a team switches the feed and header and closes the drawer; switching to `الصقور` shows the empty state; the create-team / payments / settings / notifications buttons each show the "قريبًا — تحت التطوير" alert; the card→detail flow still works. Do NOT boot a simulator locally.

---

## Notes for later increments (out of scope here)
- Real backend: source teams from `WorkspaceService`, events from `EventService`; replace `selectTeam` with a workspace switch.
- Wire the stubbed destinations to real screens: payments organizer, settings, notifications, create/join team.
- Plan-template detail (the header team-name pill / `openPlan`).
