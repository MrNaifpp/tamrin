import SwiftUI

/// Reskinned Home feed (designer look) on mock data, with the ported side-menu
/// drawer (open via the header ☰ button or a right-edge swipe) and live team
/// switching. Deferred to later increments: real backend wiring, plan-template
/// detail, and the payments / settings / notifications / create-team screens
/// (their menu entries raise a "قريبًا" placeholder alert).
struct DesignerHomeView: View {
    let appState: AppState
    @State private var feed: HomeStore
    @State private var booted = false
    @State private var scrolledID: UUID?
    @State private var selected: FeedOccurrence?
    @Namespace private var cardZoom

    @State private var isMenuOpen = false
    @State private var menuDragProgress: CGFloat = 0
    @State private var didMenuHaptic = false
    @State private var showPlanDetails = false
    @State private var showProfile = false
    @State private var showCreateTeam = false
    @State private var comingSoon: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init(appState: AppState, feed: HomeStore? = nil) {
        self.appState = appState
        _feed = State(initialValue: feed ?? HomeStore())
    }

    private var currentIndex: Int {
        guard let id = scrolledID,
              let idx = feed.occurrences.firstIndex(where: { $0.id == id }) else { return 0 }
        return idx
    }

    private func artName(_ index: Int) -> String { "ExerciseArt\((index % 3) + 1)" }

    var body: some View {
        Group {
            if !booted {
                loadingView
            } else if feed.teams.isEmpty {
                // No groups (fresh signup, or left/deleted the last) → WelcomeView
                // (create / join by code). Home appears once a workspace loads.
                WelcomeView(feed: feed)
            } else {
                homeShell
            }
        }
        .task {
            guard !booted else { return }
            feed.onSelectWorkspace = { appState.currentWorkspaceId = $0 }
            feed.onLogout = { Task { await appState.authVM.logout() } }
            await feed.bootstrap(initialWorkspaceID: appState.currentWorkspaceId)
            booted = true
            // Ask for notifications once, on first Home load — so it doesn't
            // depend on completing a paid registration to ever be requested.
            await PushManager.shared.requestAuthorizationAndRegister()
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning from background: re-sync so changes made elsewhere
            // (new sessions, registrations) show up without a manual pull.
            if phase == .active, booted {
                Task { await feed.refresh() }
            }
        }
    }

    private var loadingView: some View {
        ZStack {
            TamrinTheme.page.ignoresSafeArea()
            ProgressView().tint(.white)
        }
        .preferredColorScheme(.dark)
    }

    private var homeShell: some View {
        GeometryReader { proxy in
            let revealDistance = min(proxy.size.width * 0.84, 340)
            let progress = menuProgress()
            let pageCorner = 44 * progress

            // In RTL, `leading` is the physical right edge.
            ZStack(alignment: .leading) {
                TeamSideMenu(
                    feed: feed,
                    close: { setMenu(open: false) },
                    createTeam: { setMenu(open: false); showCreateTeam = true },
                    openSettings: { setMenu(open: false); showProfile = true },
                    openPayments: { setMenu(open: false); comingSoon = "الدفعات" },
                    onSelectTeam: { id in feed.selectTeam(id); setMenu(open: false) }
                )

                mainContent
                    .ignoresSafeArea()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background { TamrinTheme.page.ignoresSafeArea() }
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

            // NavigationStack re-establishes a real safe area inside the
            // ignoresSafeArea drawer container (matches the designer's HomeView):
            // the safeAreaInset header clears the status bar, its buttons stay
            // tappable, and the page backdrop fills the system-space strips.
            NavigationStack {
                ZStack(alignment: .topTrailing) {
                    HomeArtBackdrop(artName: artName(currentIndex), hasArt: !feed.occurrences.isEmpty)

                    Group {
                        if feed.occurrences.isEmpty {
                            // Scrollable so pull-to-refresh works while empty —
                            // the state where checking for new sessions matters most.
                            ScrollView(showsIndicators: false) {
                                EmptyScheduleCard()
                                    .padding(.horizontal, 20)
                                    .containerRelativeFrame(.vertical) { length, _ in length }
                            }
                            .refreshable { await feed.refresh() }
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
                            .refreshable { await feed.refresh() }
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
                            openMenu: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                setMenu(open: true)
                            },
                            openPlan: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showPlanDetails = true
                            },
                            openProfile: {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                showProfile = true
                            }
                        )
                    }
                }
                .environment(\.layoutDirection, .rightToLeft)
                .toolbar(.hidden, for: .navigationBar)
                .fullScreenCover(item: $selected) { occ in
                    EventDetailView(feed: feed, occurrence: occ, artName: artName(occ.artIndex))
                        .navigationTransition(.zoom(sourceID: occ.id, in: cardZoom))
                }
                .navigationDestination(isPresented: $showPlanDetails) {
                    TeamDetailView(feed: feed)
                }
                .sheet(isPresented: $showProfile) {
                    ProfileSettingsView(feed: feed)
                }
                .fullScreenCover(isPresented: $showCreateTeam) {
                    CreateTeamFlow(feed: feed, isPresented: $showCreateTeam)
                }
            }
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

struct HomeArtBackdrop: View {
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
    @State private var pulse = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.compact.down")
            .font(.system(size: 25, weight: .semibold))
            .foregroundStyle(.white.opacity(0.62))
            .shadow(color: .black.opacity(0.4), radius: 7, y: 2)
            // Apple-standard in-place SF Symbol hint bounce. The previous
            // hand-rolled offset + repeatForever (toggled in onAppear) animated
            // the arrow's position on first load, which read as the page moving.
            .symbolEffect(.bounce.down, options: .repeating, value: pulse)
            .onAppear { if !reduceMotion { pulse = 1 } }
            .accessibilityHidden(true)
    }
}

private struct StickyHomeHeader: View {
    let team: FeedTeam?
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
    let team: FeedTeam?
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
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("المجموعات")

            Button(action: openPlan) {
                HStack(spacing: 9) {
                    Text(team?.name ?? "المجموعة")
                        .font(TamrinFont.font(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.74)
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18).frame(height: 48)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
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
    DesignerHomeView(appState: AppState(), feed: .preview)
}
