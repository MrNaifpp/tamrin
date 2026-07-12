# Event Detail (Mock) — Increment 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire a Home-feed card tap to a ported designer event-detail page on mock data, with local (in-memory) register/withdraw and a deferred-payment placeholder.

**Architecture:** Continues Increment 1. `MockHomeFeed` gains a member roster and becomes the single source of truth for the registered count; `EventDetailView` (ported from the designer's `OccurrenceDetailView`, member-only) reads/mutates that store; `DesignerHomeView` presents it via `fullScreenCover` with the designer's zoom-from-card transition.

**Tech Stack:** Swift, SwiftUI, iOS 26 SDK (Liquid Glass), Xcode 26. `Sirr.xcodeproj` uses file-system-synchronized folders — new `.swift` files under `Sirr/` are auto-included.

## Global Constraints

- **Branch:** `feat/designer-ui-home` (already checked out in the worktree). All work and commits happen here.
- **Work tree (`$WT`):** `/Users/naifalialshahrani/Documents/tamrin-designer-ui`. Designer reference source: `/Users/naifalialshahrani/Documents/tamrin.test2/HomeViews.swift` (`OccurrenceDetailView`, lines ~2117–2478).
- **Mock only:** no `EventService`/Supabase calls. Register/withdraw mutate `MockHomeFeed` in memory. Payment is a disabled placeholder.
- **Admin omitted:** no admin payments section, no edit/cancel occurrence menu.
- **Verification model:** pure SwiftUI on mock state, no test target (consistent with Increment 1). Per-task verification = a clean compile of the `Sirr` scheme with a generic simulator destination that never boots a simulator, plus SwiftUI `#Preview` for visual inspection. Final on-device testing by Naif.
- **Compile command (the "test" in every task):**
  ```bash
  cd "$WT" && xcodebuild -project Sirr.xcodeproj -scheme Sirr \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet
  ```
  where `WT=/Users/naifalialshahrani/Documents/tamrin-designer-ui`. Success ends in `** BUILD SUCCEEDED **`. Note: SourceKit may emit spurious "cannot find X in scope" diagnostics for cross-file symbols — trust the `xcodebuild` result and the absence of `error:` lines, not SourceKit.
- **Language/RTL:** Arabic-first; ported view keeps `.environment(\.layoutDirection, .rightToLeft)` and `.colorScheme(.dark)`.

---

### Task 1: Roster model + register/withdraw + card count param

Extend `MockHomeFeed` with a roster and registration API; make the registered count derive from the roster; update `EventPosterCard` and its call site to take the count as a parameter. These land together because removing `FeedOccurrence.registeredCount` breaks the card until it is updated.

**Files:**
- Modify: `$WT/Sirr/features/home/MockHomeFeed.swift` (full rewrite)
- Modify: `$WT/Sirr/features/home/EventPosterCard.swift` (count param + preview)
- Modify: `$WT/Sirr/features/home/DesignerHomeView.swift:38` (pass count to card)

**Interfaces:**
- Produces:
  - `enum FeedRegStatus { case registered, waitlisted }`
  - `struct FeedMember: Identifiable { let id: UUID; let name: String; var status: FeedRegStatus }`
  - `FeedOccurrence` **without** `registeredCount` (all other fields unchanged).
  - `MockHomeFeed`: `var rosters: [UUID: [FeedMember]]`, `let currentUserName`, and methods `roster(for:)`, `registeredCount(for:) -> Int`, `waitlistCount(for:) -> Int`, `myRegistration(for:) -> FeedMember?`, `register(for:)`, `withdraw(from:)`.
  - `EventPosterCard(occurrence: FeedOccurrence, registeredCount: Int, action: () -> Void)`.

- [ ] **Step 1: Rewrite `MockHomeFeed.swift`**

Replace the entire contents of `$WT/Sirr/features/home/MockHomeFeed.swift` with:

```swift
import SwiftUI

/// Value types the reskinned Home feed reads. This whole file is the
/// integration seam: a later increment replaces the mock body of
/// `MockHomeFeed` with EventService/WorkspaceService calls that map records
/// into these types, leaving every view unchanged.
struct FeedTeam {
    let name: String
    let symbol: String
    let avatarData: Data?
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
    var team: FeedTeam
    var profileName: String
    var occurrences: [FeedOccurrence]
    var rosters: [UUID: [FeedMember]]
    let currentUserName = "نايف"

    init() {
        team = FeedTeam(name: "رفاق الملعب", symbol: "figure.run", avatarData: nil)
        profileName = "نايف"

        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        func at(_ days: Int, _ hour: Int) -> Date {
            let base = cal.date(byAdding: .day, value: days, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        }

        let o1 = FeedOccurrence(id: UUID(), title: "كورة الثلاثاء", startAt: at(2, 20),
                                locationName: "ملعب النخيل", capacity: 14,
                                price: 25, isCancelled: false, artIndex: 0)
        let o2 = FeedOccurrence(id: UUID(), title: "تمرين الجري", startAt: at(4, 6),
                                locationName: "كورنيش الرياض", capacity: 20,
                                price: 0, isCancelled: false, artIndex: 1)
        let o3 = FeedOccurrence(id: UUID(), title: "كورة نهاية الأسبوع", startAt: at(6, 18),
                                locationName: "ملعب الروضة", capacity: 12,
                                price: 30, isCancelled: false, artIndex: 2)
        occurrences = [o1, o2, o3]

        func members(_ names: [String], _ status: FeedRegStatus = .registered) -> [FeedMember] {
            names.map { FeedMember(id: UUID(), name: $0, status: status) }
        }
        let pool = ["سلطان", "عبدالله", "فهد", "تركي", "ماجد", "خالد", "نواف",
                    "سعود", "بندر", "ريان", "عمر", "يزيد", "راكان", "مشعل"]

        rosters = [
            o1.id: members(Array(pool.prefix(9))),
            o2.id: members(Array(pool.prefix(12))),
            o3.id: members(Array(pool.prefix(12))) + members(["زياد"], .waitlisted),
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
}
```

- [ ] **Step 2: Update `EventPosterCard` to take the count as a parameter**

In `$WT/Sirr/features/home/EventPosterCard.swift`:

(a) Add the property. Replace:
```swift
struct EventPosterCard: View {
    let occurrence: FeedOccurrence
    let action: () -> Void
```
with:
```swift
struct EventPosterCard: View {
    let occurrence: FeedOccurrence
    let registeredCount: Int
    let action: () -> Void
```

(b) Use it in the meta line. Replace:
```swift
                    Text("\(occurrence.locationName) · \(occurrence.registeredCount)/\(occurrence.capacity) · \(occurrence.price == 0 ? "مجاني" : "\(occurrence.price.cleanAmount) ﷼")")
```
with:
```swift
                    Text("\(occurrence.locationName) · \(registeredCount)/\(occurrence.capacity) · \(occurrence.price == 0 ? "مجاني" : "\(occurrence.price.cleanAmount) ﷼")")
```

(c) Fix the preview. Replace:
```swift
#Preview {
    let occ = FeedOccurrence(id: UUID(), title: "كورة الثلاثاء", startAt: Date(),
                             locationName: "ملعب النخيل", capacity: 14, registeredCount: 9,
                             price: 25, isCancelled: false, artIndex: 0)
    return EventPosterCard(occurrence: occ, action: {})
        .frame(height: 420).padding()
        .environment(\.layoutDirection, .rightToLeft)
}
```
with:
```swift
#Preview {
    let occ = FeedOccurrence(id: UUID(), title: "كورة الثلاثاء", startAt: Date(),
                             locationName: "ملعب النخيل", capacity: 14,
                             price: 25, isCancelled: false, artIndex: 0)
    return EventPosterCard(occurrence: occ, registeredCount: 9, action: {})
        .frame(height: 420).padding()
        .environment(\.layoutDirection, .rightToLeft)
}
```

- [ ] **Step 3: Pass the count from `DesignerHomeView`**

In `$WT/Sirr/features/home/DesignerHomeView.swift`, replace:
```swift
                                EventPosterCard(occurrence: occurrence) {
```
with:
```swift
                                EventPosterCard(occurrence: occurrence, registeredCount: feed.registeredCount(for: occurrence)) {
```

- [ ] **Step 4: Build-check**

Run the Global-Constraints compile command. Expected: `** BUILD SUCCEEDED **`, no `error:` lines.

- [ ] **Step 5: Commit**

```bash
cd /Users/naifalialshahrani/Documents/tamrin-designer-ui
git add Sirr/features/home/MockHomeFeed.swift Sirr/features/home/EventPosterCard.swift Sirr/features/home/DesignerHomeView.swift
git commit -m "feat(home): roster + register/withdraw in MockHomeFeed; card count param"
```

---

### Task 2: EventDetailView

Port the designer's member-facing `OccurrenceDetailView` to `EventDetailView`, bound to `MockHomeFeed`.

**Files:**
- Create: `$WT/Sirr/features/home/EventDetailView.swift`

**Interfaces:**
- Consumes: `MockHomeFeed`, `FeedOccurrence`, `FeedMember`, `FeedRegStatus` (Task 1); `TamrinFont`, `TamrinTheme`, `Date.arabicDay/arabicTime`, `Double.cleanAmount` (Increment 1).
- Produces: `struct EventDetailView: View { @Bindable var feed: MockHomeFeed; let occurrence: FeedOccurrence; var artName: String }`.

- [ ] **Step 1: Create the detail view**

Create `$WT/Sirr/features/home/EventDetailView.swift`:

```swift
import SwiftUI

/// Event detail page — the designer's OccurrenceDetailView (member view) bound
/// to MockHomeFeed. Register/withdraw are local in-memory mutations; payment is
/// a deferred placeholder; the admin section and edit/cancel menu are omitted.
struct EventDetailView: View {
    @Bindable var feed: MockHomeFeed
    let occurrence: FeedOccurrence
    var artName: String = "ExerciseArt1"
    @Environment(\.dismiss) private var dismiss

    private var roster: [FeedMember] { feed.roster(for: occurrence) }
    private var myRegistration: FeedMember? { feed.myRegistration(for: occurrence) }
    private var confirmedCount: Int { feed.registeredCount(for: occurrence) }
    private var waitingCount: Int { feed.waitlistCount(for: occurrence) }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                ZStack {
                    Image(artName)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    Image(artName)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                        .blur(radius: 26, opaque: true)
                        .mask {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.33),
                                .init(color: .black, location: 0.46),
                                .init(color: .black, location: 1)
                            ], startPoint: .top, endPoint: .bottom)
                        }
                }
            }
            .ignoresSafeArea()

            LinearGradient(stops: [
                .init(color: .black.opacity(0.32), location: 0),
                .init(color: .black.opacity(0.06), location: 0.26),
                .init(color: .black.opacity(0.30), location: 0.55),
                .init(color: .black.opacity(0.58), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    heroTitle
                        .padding(.top, 264)
                        .padding(.bottom, 6)

                    if !occurrence.isCancelled { participationCTA }

                    progressPanel

                    Text("القائمة")
                        .font(TamrinFont.font(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.top, 8)
                        .padding(.horizontal, 4)

                    rosterRows
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .accessibilityLabel("إغلاق")
        }
        .environment(\.layoutDirection, .rightToLeft)
        .colorScheme(.dark)
    }

    private var heroTitle: some View {
        VStack(spacing: 7) {
            if occurrence.isCancelled {
                Text("تم إلغاء الموعد")
                    .font(TamrinFont.font(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 6)
                    .background(.red.opacity(0.85), in: .capsule)
            }
            Text(occurrence.title)
                .font(TamrinFont.font(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2).minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
            Text("يوم \(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
                .font(TamrinFont.font(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var participationCTA: some View {
        if let mine = myRegistration {
            Button { feed.withdraw(from: occurrence) } label: {
                HStack(spacing: 10) {
                    Image(systemName: mine.status == .registered ? "checkmark.circle.fill" : "clock.fill")
                        .foregroundStyle(mine.status == .registered ? TamrinTheme.lime : .orange)
                    Text(mine.status == .registered ? "مكانك محفوظ" : "أنت في قائمة الانتظار")
                        .font(TamrinFont.font(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(mine.status == .registered ? "اعتذر" : "انسحب")
                        .font(TamrinFont.font(size: 13, weight: .medium))
                        .foregroundStyle(.red.opacity(0.95))
                }
                .padding(.horizontal, 18).frame(maxWidth: .infinity).frame(height: 52)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityHint("يفتح تأكيد الاعتذار عن التمرين")

            if mine.status == .registered, occurrence.price > 0 {
                Label("الدفع — قريبًا", systemImage: "creditcard")
                    .font(TamrinFont.headline)
                    .foregroundStyle(TamrinTheme.ink.opacity(0.55))
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(.white.opacity(0.5), in: .capsule)
                    .accessibilityLabel("الدفع قريبًا")
            }
        } else {
            let full = confirmedCount >= occurrence.capacity
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                feed.register(for: occurrence)
            } label: {
                Label(full ? "انضم لقائمة الانتظار" : "سجل في التمرين", systemImage: "plus")
                    .font(TamrinFont.font(size: 16, weight: .bold))
                    .foregroundStyle(TamrinTheme.ink)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.white.opacity(0.94)).interactive(), in: .capsule)
        }
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("نسبة إكتمال التمرين")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(confirmedCount.formatted())\\\(occurrence.capacity.formatted())")
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            ProgressView(value: Double(confirmedCount), total: Double(max(occurrence.capacity, 1)))
                .tint(TamrinTheme.lime)
            if waitingCount > 0 {
                Text("\(waitingCount.formatted()) في قائمة الانتظار")
                    .font(TamrinFont.font(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.white.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var rosterRows: some View {
        if roster.isEmpty {
            Text("كن أول المسجلين.")
                .font(TamrinFont.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(.white.opacity(0.1), in: .rect(cornerRadius: 16, style: .continuous))
        } else {
            VStack(spacing: 8) {
                ForEach(roster) { person in
                    HStack(spacing: 12) {
                        MemberAvatar(name: person.name)
                        Text(person.name)
                            .font(TamrinFont.font(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                        if person.status == .waitlisted {
                            Image(systemName: "clock")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.orange)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(TamrinTheme.lime)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(.white.opacity(0.1), in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    }
                }
            }
        }
    }
}

private struct MemberAvatar: View {
    let name: String
    var body: some View {
        Circle()
            .fill(.white.opacity(0.28))
            .frame(width: 34, height: 34)
            .overlay {
                Text(String(name.prefix(1)))
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    let feed = MockHomeFeed()
    return EventDetailView(feed: feed, occurrence: feed.occurrences[0], artName: "ExerciseArt1")
}
```

- [ ] **Step 2: Build-check**

Run the Global-Constraints compile command. Expected: `** BUILD SUCCEEDED **`, no `error:` lines.

- [ ] **Step 3: Commit**

```bash
cd /Users/naifalialshahrani/Documents/tamrin-designer-ui
git add Sirr/features/home/EventDetailView.swift
git commit -m "feat(home): EventDetailView — hero, register/withdraw, roster (mock)"
```

---

### Task 3: Wire card → detail (zoom + fullScreenCover)

Present `EventDetailView` from a card tap with the designer's zoom-from-card transition.

**Files:**
- Modify: `$WT/Sirr/features/home/DesignerHomeView.swift`

**Interfaces:**
- Consumes: `EventDetailView` (Task 2); existing `selected`/`artName(_:)` in `DesignerHomeView`.

- [ ] **Step 1: Add the zoom namespace**

In `$WT/Sirr/features/home/DesignerHomeView.swift`, replace:
```swift
    @State private var selected: FeedOccurrence?
```
with:
```swift
    @State private var selected: FeedOccurrence?
    @Namespace private var cardZoom
```

- [ ] **Step 2: Mark each card as the zoom source**

Replace:
```swift
                                    .containerRelativeFrame(.vertical, alignment: .top) { length, _ in
                                        max(length - 64, 320)
                                    }
                                }
```
with:
```swift
                                    .containerRelativeFrame(.vertical, alignment: .top) { length, _ in
                                        max(length - 64, 320)
                                    }
                                    .matchedTransitionSource(id: occurrence.id, in: cardZoom)
                                }
```

- [ ] **Step 3: Present the detail via fullScreenCover with zoom**

Replace:
```swift
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}
```
with:
```swift
        }
        .environment(\.layoutDirection, .rightToLeft)
        .fullScreenCover(item: $selected) { occ in
            EventDetailView(feed: feed, occurrence: occ, artName: artName(occ.artIndex))
                .navigationTransition(.zoom(sourceID: occ.id, in: cardZoom))
        }
    }
}
```

- [ ] **Step 4: Final build-check**

Run the Global-Constraints compile command. Expected: `** BUILD SUCCEEDED **`, no `error:` lines.

- [ ] **Step 5: Commit**

```bash
cd /Users/naifalialshahrani/Documents/tamrin-designer-ui
git add Sirr/features/home/DesignerHomeView.swift
git commit -m "feat(home): tap card → EventDetailView with zoom transition"
```

- [ ] **Step 6: Hand off to Naif for on-device testing**

Report the increment is built and compiling. Ask Naif to run the `Sirr` scheme on device and verify: tapping a feed card zooms into the detail page; the hero art blur-fades into the title; `سجل في التمرين` adds you (progress bar, count, and roster update live; button flips to `مكانك محفوظ`); the paid event shows the disabled `الدفع — قريبًا` placeholder; registering on the full event (`كورة نهاية الأسبوع`) puts you on the waitlist; `اعتذر`/`انسحب` removes you and promotes a waitlisted member; back returns to the feed with the card's count updated. Do NOT boot a simulator locally.

---

## Notes for later increments (out of scope here)
- Real backend: replace `register`/`withdraw` with `EventService` calls; source the roster from `get_event_participants`.
- Full registration + payment flow (guests, payment method, STC Pay) — port the designer's `RegistrationFlowSheet`.
- Admin: payments-collection section and edit/cancel occurrence menu.
