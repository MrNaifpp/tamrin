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
            let topInset = proxy.safeAreaInsets.top

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

                mainContent(topInset: topInset)
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

    private func mainContent(topInset: CGFloat) -> some View {
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
                        topInset: topInset,
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
    let topInset: CGFloat
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
        .padding(.horizontal, 16).padding(.top, topInset + 8).padding(.bottom, 12)
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
