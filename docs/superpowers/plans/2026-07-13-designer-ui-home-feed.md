# Designer UI — Home Feed Reskin (Increment 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the designer's `DesignSystem.swift` + Thmanyah Sans font into the Sirr app and reskin the logged-in Home feed to the designer's poster-card look, driven entirely by mock data.

**Architecture:** Sirr (`phase_1`) is the base; its Supabase backend stays intact and is NOT called this increment. The design system is imported verbatim; the Home feed's views are re-authored against a `MockHomeFeed` provider (the seam we later swap for `EventService`). The logged-in route points at a new `DesignerHomeView`.

**Tech Stack:** Swift, SwiftUI, iOS 26 SDK (Liquid Glass APIs), Xcode 26. `Sirr.xcodeproj` uses **file-system-synchronized folders** — dropping `.swift`/asset files under `Sirr/` auto-includes them in the target (no pbxproj edits).

## Global Constraints

- **Base branch:** `feat/designer-ui-home`, already cut from `phase_1`. All work and commits happen here.
- **Work tree:** `/private/tmp/claude-501/-Users-naifalialshahrani-Documents-tamrin/80da3f48-b030-47a9-8a18-4d82f6d76d88/scratchpad/phase_1-wt` (referred to below as `$WT`). Designer source to copy from: `/Users/naifalialshahrani/Documents/tamrin/tamrin.test2` (referred to as `$D`).
- **Mock only:** no `EventService`/`WorkspaceService`/Supabase calls anywhere in this increment.
- **Verification model:** this is pure SwiftUI UI on static mock data with no test target (per spec). There is no unit-test TDD cycle. Per-task verification = a **clean compile of the `Sirr` scheme** with `xcodebuild` using a **generic simulator destination that never boots a simulator**, plus a SwiftUI `#Preview` for on-device/Xcode visual inspection. Final on-device testing is done by Naif.
- **Compile command (used as the "test" in every task):**
  ```bash
  cd "$WT" && xcodebuild -project Sirr.xcodeproj -scheme Sirr \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet
  ```
  Expected on success: ends with `** BUILD SUCCEEDED **`.
- **iOS 26 APIs:** the ported views use `GlassEffectContainer`, `.glassEffect(.regular.interactive(), in:)`. These require the iOS 26 SDK (Xcode 26). If the build environment's Xcode is older, these lines will not compile — stop and report rather than downgrading the design.
- **Font names:** file names are `ThmanyahSans-{Light,Regular,Medium,Bold}.ttf`; the PostScript names referenced by the design system are `Thmanyahsans12-{Light,Regular,Medium,Bold}`. `UIAppFonts` registers the **file names**; `TamrinFont` loads by **PostScript name**. Do not "fix" this mismatch — it is correct.
- **Language/RTL:** Arabic-first; ported views keep `.environment(\.layoutDirection, .rightToLeft)` and the designer's Arabic strings.

---

### Task 1: Foundation — design system, fonts, art assets

Import the model-agnostic design layer so later tasks can reference `TamrinFont`, `TamrinTheme`, `SpringCardPressStyle`, and `ExerciseArt*`.

**Files:**
- Create: `$WT/Sirr/DesignSystem/DesignSystem.swift` (copied verbatim from `$D/DesignSystem.swift`)
- Create: `$WT/Sirr/App/ThmanyahSans-Light.ttf`, `-Regular.ttf`, `-Medium.ttf`, `-Bold.ttf` (copied from `$D/Fonts/`, co-located with the existing `TheYearofHandicrafts-*.otf`)
- Create: `$WT/Sirr/App/Assets.xcassets/ExerciseArt1.imageset`, `ExerciseArt2.imageset`, `ExerciseArt3.imageset` (copied from `$D/Assets.xcassets/`)
- Modify: `$WT/Sirr/Info.plist` (append 4 font file names to the existing `UIAppFonts` array)

**Interfaces:**
- Produces: `enum TamrinTheme` (`.page`, `.ink`, `.lime`, `.mint`, `.peach`, `.secondary`, `.glass`, `.hairline`, `.brandGreen`, `.corner`); `enum TamrinFont` with `static func font(size:weight:features:)` and presets (`.headline`, `.body`, `.title3`, etc.); `struct SpringCardPressStyle: ButtonStyle`; `struct PrimaryActionStyle`, `SecondaryActionStyle`; `struct StatusPill`, `IconOrb`, `TeamAvatarView`, `BrandMark`, `FloatingCloseButton`, `AuroraBackdrop`; `extension Date { var arabicDay/arabicDate/arabicTime }`; `extension Double { var cleanAmount }`. Image assets `ExerciseArt1..3`.

> Note: `DesignSystem.swift` references `Team?` in `TeamAvatarView` (a designer SwiftData model that does NOT exist in Sirr). This will break the build. Fix it in Step 4 below by generalizing that one component off the mock-friendly shape. Everything else in the file is self-contained.

- [ ] **Step 1: Copy the design system, fonts, and art assets**

```bash
WT=/private/tmp/claude-501/-Users-naifalialshahrani-Documents-tamrin/80da3f48-b030-47a9-8a18-4d82f6d76d88/scratchpad/phase_1-wt
D=/Users/naifalialshahrani/Documents/tamrin/tamrin.test2
mkdir -p "$WT/Sirr/DesignSystem"
cp "$D/DesignSystem.swift" "$WT/Sirr/DesignSystem/DesignSystem.swift"
cp "$D/Fonts/ThmanyahSans-"*.ttf "$WT/Sirr/App/"
cp -R "$D/Assets.xcassets/ExerciseArt1.imageset" "$D/Assets.xcassets/ExerciseArt2.imageset" "$D/Assets.xcassets/ExerciseArt3.imageset" "$WT/Sirr/App/Assets.xcassets/"
ls "$WT/Sirr/App/ThmanyahSans-"*.ttf && ls -d "$WT/Sirr/App/Assets.xcassets/ExerciseArt"*
```

- [ ] **Step 2: Register the 4 font files in `Info.plist`**

In `$WT/Sirr/Info.plist`, locate the existing `UIAppFonts` array and add the four Thmanyah file names so the block reads:

```xml
	<key>UIAppFonts</key>
	<array>
		<string>TheYearofHandicrafts-Regular.otf</string>
		<string>TheYearofHandicrafts-Medium.otf</string>
		<string>TheYearofHandicrafts-SemiBold.otf</string>
		<string>TheYearofHandicrafts-Bold.otf</string>
		<string>TheYearofHandicrafts-Black.otf</string>
		<string>ThmanyahSans-Light.ttf</string>
		<string>ThmanyahSans-Regular.ttf</string>
		<string>ThmanyahSans-Medium.ttf</string>
		<string>ThmanyahSans-Bold.ttf</string>
	</array>
```

- [ ] **Step 3: Make `TeamAvatarView` model-agnostic (remove the `Team` dependency)**

In `$WT/Sirr/DesignSystem/DesignSystem.swift`, replace the whole `struct TeamAvatarView` (it takes `let team: Team?`, which does not exist in Sirr) with an avatar that takes plain data:

```swift
struct TeamAvatarView: View {
    var avatarData: Data? = nil
    var symbol: String = "figure.run"
    var size: CGFloat = 56
    var cornerRadiusRatio: CGFloat = 0.32
    var fallbackBackground: AnyShapeStyle = AnyShapeStyle(TamrinTheme.secondary)
    var symbolColor: Color = TamrinTheme.ink

    var body: some View {
        Group {
            if let data = avatarData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(fallbackBackground)
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(symbolColor)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * cornerRadiusRatio, style: .continuous))
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 4: Build-check (compile the Sirr scheme)**

Run the Global-Constraints compile command.
Expected: `** BUILD SUCCEEDED **`. If it fails on a `Team` reference, re-check Step 3 caught every `Team` usage in `DesignSystem.swift` (there should be exactly one, in `TeamAvatarView`).

- [ ] **Step 5: Commit**

```bash
cd "$WT"
git add Sirr/DesignSystem/DesignSystem.swift Sirr/App/ThmanyahSans-*.ttf "Sirr/App/Assets.xcassets/ExerciseArt1.imageset" "Sirr/App/Assets.xcassets/ExerciseArt2.imageset" "Sirr/App/Assets.xcassets/ExerciseArt3.imageset" Sirr/Info.plist
git commit -m "feat(ui): import Thmanyah design system, fonts, and exercise art"
```

---

### Task 2: Mock feed data layer

Build the `MockHomeFeed` provider and its value types — the seam a later increment swaps for real services.

**Files:**
- Create: `$WT/Sirr/features/home/MockHomeFeed.swift`

**Interfaces:**
- Consumes: nothing (leaf).
- Produces:
  - `struct FeedTeam { let name: String; let symbol: String; let avatarData: Data? }`
  - `struct FeedOccurrence: Identifiable { let id: UUID; let title: String; let startAt: Date; let locationName: String; let capacity: Int; let registeredCount: Int; let price: Double; let isCancelled: Bool; let artIndex: Int }`
  - `@MainActor @Observable final class MockHomeFeed { var team: FeedTeam; var profileName: String; var occurrences: [FeedOccurrence]; init() }`

- [ ] **Step 1: Create the mock provider**

Create `$WT/Sirr/features/home/MockHomeFeed.swift`:

```swift
import SwiftUI

/// Value types the reskinned Home feed reads. This whole file is the
/// integration seam: a later increment replaces the mock body of
/// `MockHomeFeed` with EventService/WorkspaceService calls that map records
/// into `FeedOccurrence`, leaving every view unchanged.
struct FeedTeam {
    let name: String
    let symbol: String
    let avatarData: Data?
}

struct FeedOccurrence: Identifiable {
    let id: UUID
    let title: String
    let startAt: Date
    let locationName: String
    let capacity: Int
    let registeredCount: Int
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

    init() {
        team = FeedTeam(name: "رفاق الملعب", symbol: "figure.run", avatarData: nil)
        profileName = "نايف"

        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        func at(_ days: Int, _ hour: Int) -> Date {
            let base = cal.date(byAdding: .day, value: days, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        }

        occurrences = [
            FeedOccurrence(id: UUID(), title: "كورة الثلاثاء", startAt: at(2, 20),
                           locationName: "ملعب النخيل", capacity: 14, registeredCount: 9,
                           price: 25, isCancelled: false, artIndex: 0),
            FeedOccurrence(id: UUID(), title: "تمرين الجري", startAt: at(4, 6),
                           locationName: "كورنيش الرياض", capacity: 20, registeredCount: 12,
                           price: 0, isCancelled: false, artIndex: 1),
            FeedOccurrence(id: UUID(), title: "كورة نهاية الأسبوع", startAt: at(6, 18),
                           locationName: "ملعب الروضة", capacity: 12, registeredCount: 12,
                           price: 30, isCancelled: false, artIndex: 2),
        ]
    }
}
```

- [ ] **Step 2: Build-check**

Run the Global-Constraints compile command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd "$WT"
git add Sirr/features/home/MockHomeFeed.swift
git commit -m "feat(home): mock feed provider (backend-swap seam)"
```

---

### Task 3: Poster card + empty state

Port the designer's `ExercisePosterCard` and `EmptyScheduleCard`, retargeted from `Occurrence`/`store` to `FeedOccurrence`.

**Files:**
- Create: `$WT/Sirr/features/home/EventPosterCard.swift`

**Interfaces:**
- Consumes: `FeedOccurrence` (Task 2); `TamrinFont`, `SpringCardPressStyle`, `Date.arabicDay/arabicTime`, `Double.cleanAmount`, `ExerciseArt1..3` (Task 1).
- Produces:
  - `struct EventPosterCard: View { let occurrence: FeedOccurrence; let action: () -> Void }`
  - `struct EmptyScheduleCard: View { }`

- [ ] **Step 1: Create the card and empty state**

Create `$WT/Sirr/features/home/EventPosterCard.swift`:

```swift
import SwiftUI

/// Poster-style event card — the designer's ExercisePosterCard bound to the
/// mock FeedOccurrence. Admin publish/edit/cancel affordances are intentionally
/// omitted this increment (member view only).
struct EventPosterCard: View {
    let occurrence: FeedOccurrence
    let action: () -> Void

    private var artName: String { "ExerciseArt\((occurrence.artIndex % 3) + 1)" }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                Color.clear
                    .overlay {
                        Image(artName)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }

                VStack(spacing: 7) {
                    if occurrence.isCancelled {
                        Text("ملغي")
                            .font(TamrinFont.font(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 13).padding(.vertical, 6)
                            .background(.red.opacity(0.85), in: .capsule)
                    }

                    Text(occurrence.title)
                        .font(TamrinFont.font(size: 27, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.7)

                    Text("\(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
                        .font(TamrinFont.font(size: 15, weight: .medium))
                        .opacity(0.82)

                    Text("\(occurrence.locationName) · \(occurrence.registeredCount)/\(occurrence.capacity) · \(occurrence.price == 0 ? "مجاني" : "\(occurrence.price.cleanAmount) ﷼")")
                        .font(TamrinFont.font(size: 12, weight: .regular))
                        .opacity(0.68).lineLimit(1)
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24).padding(.top, 72).padding(.bottom, 56)
                .frame(maxWidth: .infinity)
                .background {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        LinearGradient(colors: [.black.opacity(0), .black.opacity(0.10)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.55), location: 0.5),
                            .init(color: .black, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                }
                .colorScheme(.dark)
            }
            .clipShape(.rect(cornerRadius: 36, style: .continuous))
            .contentShape(.rect(cornerRadius: 36, style: .continuous))
        }
        .buttonStyle(SpringCardPressStyle())
        .accessibilityLabel("\(occurrence.title)، \(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
        .accessibilityHint("يفتح تفاصيل الموعد")
    }
}

struct EmptyScheduleCard: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("ما فيه مواعيد قادمة")
                .font(TamrinFont.headline)
            Text("راجع قالب التمرين أو أضف موعداً جديداً.")
                .font(TamrinFont.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .background(.white, in: .rect(cornerRadius: 24, style: .continuous))
    }
}

#Preview {
    let occ = FeedOccurrence(id: UUID(), title: "كورة الثلاثاء", startAt: Date(),
                             locationName: "ملعب النخيل", capacity: 14, registeredCount: 9,
                             price: 25, isCancelled: false, artIndex: 0)
    return EventPosterCard(occurrence: occ, action: {})
        .frame(height: 420).padding()
        .environment(\.layoutDirection, .rightToLeft)
}
```

- [ ] **Step 2: Build-check**

Run the Global-Constraints compile command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd "$WT"
git add Sirr/features/home/EventPosterCard.swift
git commit -m "feat(home): poster event card + empty state on mock model"
```

---

### Task 4: Home screen assembly

Port the designer's Home feed body — art backdrop, sticky header, scroll hint, and the vertical poster-card feed — as `DesignerHomeView`, bound to `MockHomeFeed`. The side-menu drawer, plan-detail, and sheets are deferred: the menu / plan / profile buttons are no-op stubs this increment.

**Files:**
- Create: `$WT/Sirr/features/home/DesignerHomeView.swift`

**Interfaces:**
- Consumes: `MockHomeFeed`, `FeedTeam`, `FeedOccurrence` (Task 2); `EventPosterCard`, `EmptyScheduleCard` (Task 3); `TamrinTheme`, `TamrinFont` (Task 1).
- Produces: `struct DesignerHomeView: View { init() }` (owns its own `MockHomeFeed`).

- [ ] **Step 1: Create the Home screen and its private subviews**

Create `$WT/Sirr/features/home/DesignerHomeView.swift`:

```swift
import SwiftUI

/// Reskinned Home feed (designer look) on mock data. Deferred to later
/// increments: real backend wiring, the edge-swipe side menu, plan-template
/// detail, and the create/join/settings/payments/notifications sheets. The
/// menu / plan / profile buttons are inert stubs here.
struct DesignerHomeView: View {
    @State private var feed = MockHomeFeed()
    @State private var scrolledID: UUID?
    @State private var selected: FeedOccurrence?

    private var currentIndex: Int {
        guard let id = scrolledID,
              let idx = feed.occurrences.firstIndex(where: { $0.id == id }) else { return 0 }
        return idx
    }

    private func artName(_ index: Int) -> String { "ExerciseArt\((index % 3) + 1)" }

    var body: some View {
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
                                    EventPosterCard(occurrence: occurrence) {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        selected = occurrence
                                    }
                                    .containerRelativeFrame(.vertical, alignment: .top) { length, _ in
                                        max(length - 64, 320)
                                    }
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
                        team: feed.team,
                        profileName: feed.profileName,
                        sectionTitle: feed.occurrences.isEmpty
                            ? nil
                            : (currentIndex == 0 ? "التمرين الجاي" : "التمارين القادمة"),
                        openMenu: {},
                        openPlan: {},
                        openProfile: {}
                    )
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
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

- [ ] **Step 2: Build-check**

Run the Global-Constraints compile command. Expected: `** BUILD SUCCEEDED **`. If it fails on `GlassEffectContainer`/`glassEffect`, the environment's Xcode predates the iOS 26 SDK — stop and report (see Global Constraints).

- [ ] **Step 3: Commit**

```bash
cd "$WT"
git add Sirr/features/home/DesignerHomeView.swift
git commit -m "feat(home): DesignerHomeView — poster feed, art backdrop, sticky header"
```

---

### Task 5: Route logged-in Home to the reskin + final verification

Point the logged-in branch at `DesignerHomeView` and confirm the whole increment builds. `EventPageView.swift` stays in the project (unused) as reference for the later backend-wiring increment.

**Files:**
- Modify: `$WT/Sirr/ContentView.swift:32`

**Interfaces:**
- Consumes: `DesignerHomeView` (Task 4).

- [ ] **Step 1: Swap the logged-in Home view**

In `$WT/Sirr/ContentView.swift`, replace the logged-in branch (line 32):

```swift
                } else if appState.isLoggedIn {
                    EventPageView(authVM: appState.authVM, appState: appState, deepLinkEventId: $appState.deepLinkEventId)
                } else {
```

with:

```swift
                } else if appState.isLoggedIn {
                    // Increment 1: designer Home feed on mock data. The old
                    // EventPageView (real Supabase) is kept for reference and
                    // will be re-wired in the backend increment.
                    DesignerHomeView()
                } else {
```

- [ ] **Step 2: Final build-check**

Run the Global-Constraints compile command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd "$WT"
git add Sirr/ContentView.swift
git commit -m "feat(home): route logged-in home to DesignerHomeView (mock)"
```

- [ ] **Step 4: Hand off to Naif for on-device testing**

Report that the increment is built and compiling. Ask Naif to run the `Sirr` scheme on device and verify: logged-in Home shows the poster-card feed with Thmanyah Sans type, the blurred art backdrop tracking the visible card, the sticky glass header (menu/plan/profile buttons inert), vertical snap paging, the scroll-hint chevron on the first card, and the RTL layout. Do NOT boot a simulator locally.

---

## Notes for later increments (out of scope here)
- **Backend wiring:** replace `MockHomeFeed`'s mock body with `WorkspaceService`/`EventService` calls mapping `EventRecord` → `FeedOccurrence`; the live registered count (`X`) needs an `EventService` extension (feed RPC currently returns capacity only).
- **Side menu:** port `TeamSideMenu` and wire its buttons to Sirr's `GroupsDrawer`/workspace flows; replace the inert `openMenu`/`openPlan`/`openProfile` stubs.
- **Admin affordances:** re-introduce publish/edit/cancel on the card once Sirr models a publication lifecycle (or map to Sirr's registration-lock).
