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
                                    EventPosterCard(occurrence: occurrence, registeredCount: feed.registeredCount(for: occurrence)) {
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
