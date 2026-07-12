import SwiftUI
import MapKit
import PhotosUI

private struct PlanRevealSourceFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        guard !next.isEmpty else { return }
        value = next
    }
}

struct HomeView: View {
    @Bindable var store: TamrinStore
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var showSettings = false
    @State private var showNotifications = false
    @State private var showPaymentOrganizer = false
    @State private var showAddChooser = false
    @State private var showCreateExercise = false
    @State private var selectedOccurrence: Occurrence?
    @State private var showPlanDetails = false
    @State private var isSideMenuOpen = ProcessInfo.processInfo.arguments.contains("-TamrinSideMenuOpen")
    @State private var sideMenuDragProgress: CGFloat = 0
    @State private var didTriggerSideMenuHaptic = false
    @State private var scrolledOccurrenceID: UUID?
    @State private var singleCardDrag: CGFloat = 0
    @Namespace private var occurrenceZoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentCardIndex: Int {
        guard let id = scrolledOccurrenceID,
              let index = store.teamOccurrences.firstIndex(where: { $0.id == id }) else { return 0 }
        return index
    }

    static func artName(for index: Int) -> String { "ExerciseArt\((index % 3) + 1)" }

    var body: some View {
        GeometryReader { proxy in
            let revealDistance = min(proxy.size.width * 0.84, 340)
            let progress = sideMenuProgress()
            let pageCorner = 44 * progress

            // In RTL, `leading` is the physical right edge.
            ZStack(alignment: .leading) {
                TeamSideMenu(
                    store: store,
                    close: { setSideMenu(open: false) },
                    createTeam: {
                        setSideMenu(open: false)
                        showAddChooser = true
                    },
                    openSettings: {
                        setSideMenu(open: false)
                        showSettings = true
                    },
                    openPayments: {
                        setSideMenu(open: false)
                        showPaymentOrganizer = true
                    },
                    openNotifications: {
                        setSideMenu(open: false)
                        showNotifications = true
                    }
                )

                ZStack {
                    TamrinTheme.page.ignoresSafeArea()

                    NavigationStack {
                        ZStack(alignment: .topTrailing) {
                            HomeArtBackdrop(
                                artName: Self.artName(for: currentCardIndex),
                                hasArt: !store.teamOccurrences.isEmpty
                            )

                            Group {
                                if store.teamOccurrences.isEmpty {
                                    ScrollView(showsIndicators: false) {
                                        EmptyScheduleCard()
                                            .padding(.horizontal, 20)
                                            .padding(.top, 6)
                                    }
                                } else if store.teamOccurrences.count == 1, let occurrence = store.teamOccurrences.first {
                                    GeometryReader { geo in
                                        ExercisePosterCard(store: store, occurrence: occurrence, artIndex: 0) {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            selectedOccurrence = occurrence
                                        }
                                        .frame(height: max(geo.size.height - 28, 320))
                                        .padding(.horizontal, 20)
                                        .offset(y: singleCardDrag * 0.10)
                                        .scaleEffect(1 - min(abs(singleCardDrag) / 2800, 0.012))
                                        .rotation3DEffect(.degrees(Double(singleCardDrag / 90)), axis: (x: 1, y: 0, z: 0), perspective: 0.35)
                                        .contentShape(Rectangle())
                                        .simultaneousGesture(singleOccurrenceGesture)
                                        .animation(.interactiveSpring(response: 0.38, dampingFraction: 0.78), value: singleCardDrag)
                                    }
                                } else {
                                    ScrollView(.vertical, showsIndicators: false) {
                                        LazyVStack(spacing: 110) {
                                            ForEach(Array(store.teamOccurrences.prefix(6).enumerated()), id: \.element.id) { index, occurrence in
                                                ExercisePosterCard(
                                                    store: store,
                                                    occurrence: occurrence,
                                                    artIndex: index
                                                ) {
                                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                    selectedOccurrence = occurrence
                                                }
                                                .containerRelativeFrame(.vertical, alignment: .top) { length, _ in
                                                    max(length - 64, 320)
                                                }
                                                .matchedTransitionSource(id: occurrence.id, in: occurrenceZoom)
                                            }
                                        }
                                        .scrollTargetLayout()
                                        .padding(.horizontal, 20)
                                    }
                                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                                    .scrollPosition(id: $scrolledOccurrenceID)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if store.teamOccurrences.count > 1, currentCardIndex == 0 {
                                    ScrollHintChevron()
                                        .padding(.bottom, 2)
                                        .transition(.opacity)
                                }
                            }
                            .animation(.easeInOut(duration: 0.3), value: currentCardIndex)
                            .safeAreaInset(edge: .top, spacing: 0) {
                                StickyHomeHeader(
                                    team: store.currentTeam,
                                    profileName: store.profile?.name ?? "",
                                    sectionTitle: store.teamOccurrences.isEmpty
                                        ? nil
                                        : (currentCardIndex == 0 ? "التمرين الجاي" : "التمارين القادمة"),
                                    openMenu: {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        setSideMenu(open: true)
                                    },
                                    openPlan: {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        showPlanDetails = true
                                    },
                                    openProfile: {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        showSettings = true
                                    }
                                )
                            }
                        }
                        .environment(\.layoutDirection, .rightToLeft)
                        .navigationDestination(isPresented: $showPlanDetails) {
                            PlanTemplateDetailView(store: store)
                        }
                        .toolbar(.hidden, for: .navigationBar)
                        .fullScreenCover(isPresented: $showCreate) { CreateTeamFlow(store: store, isPresented: $showCreate) }
                        .sheet(isPresented: $showJoin) { JoinTeamView(store: store, isPresented: $showJoin) }
                        .fullScreenCover(item: $selectedOccurrence) { occurrence in
                            OccurrenceDetailView(
                                store: store,
                                occurrence: occurrence,
                                artName: Self.artName(for: store.teamOccurrences.firstIndex { $0.id == occurrence.id } ?? 0)
                            )
                            .navigationTransition(.zoom(sourceID: occurrence.id, in: occurrenceZoom))
                        }
                        .sheet(isPresented: $showNotifications) { NotificationCenterView(store: store) }
                        .sheet(isPresented: $showSettings) { AppSettingsView(store: store) }
                        .sheet(isPresented: $showPaymentOrganizer) { PaymentOrganizerView(store: store) }
                        .sheet(isPresented: $showAddChooser) {
                            AddChooserSheet(store: store, createExercise: {
                                showAddChooser = false
                                showCreateExercise = true
                            }, createTeam: {
                                showAddChooser = false
                                showCreate = true
                            }, joinTeam: {
                                showAddChooser = false
                                showJoin = true
                            })
                        }
                        .fullScreenCover(isPresented: $showCreateExercise) { CreateExerciseFlow(store: store) }
                    }
                }
                .ignoresSafeArea()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background { TamrinTheme.page.ignoresSafeArea() }
                .clipShape(.rect(cornerRadius: pageCorner, style: .continuous))
                .shadow(color: .black.opacity(0.34 * progress), radius: 32 * progress, x: 14 * progress, y: 0)
                .overlay {
                    if progress > 0.02 {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture { setSideMenu(open: false) }
                    }
                }
                .opacity(Double(1.0 - 0.18 * progress))
                .scaleEffect(1 - (0.045 * progress), anchor: .trailing)
                .offset(x: revealDistance * progress)
                .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86), value: progress)
            }
            .background(Color(red: 0.067, green: 0.067, blue: 0.067))
            .ignoresSafeArea()
            .simultaneousGesture(sideMenuGesture(revealDistance: revealDistance, screenWidth: proxy.size.width))
        }
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .openTamrinOccurrence)) { notification in
            guard let id = notification.object as? UUID else { return }
            selectedOccurrence = store.occurrences.first { $0.id == id }
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-TamrinOpenAddChooser") {
                try? await Task.sleep(for: .milliseconds(700))
                showAddChooser = true
            } else if ProcessInfo.processInfo.arguments.contains("-TamrinOpenProfile") {
                try? await Task.sleep(for: .milliseconds(700))
                showSettings = true
            } else if ProcessInfo.processInfo.arguments.contains("-TamrinOpenFirstOccurrence") {
                try? await Task.sleep(for: .milliseconds(900))
                selectedOccurrence = store.teamOccurrences.first
            } else if ProcessInfo.processInfo.arguments.contains("-TamrinOpenPlanDetails") {
                try? await Task.sleep(for: .milliseconds(900))
                showPlanDetails = true
            }
        }
        #endif
    }

    private func sideMenuProgress() -> CGFloat {
        let base: CGFloat = isSideMenuOpen ? 1 : 0
        return min(max(base + sideMenuDragProgress, 0), 1)
    }

    private func setSideMenu(open: Bool) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            isSideMenuOpen = open
            sideMenuDragProgress = 0
        }
        didTriggerSideMenuHaptic = false
    }

    private func sideMenuGesture(revealDistance: CGFloat, screenWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                let startsAtRightEdge = value.startLocation.x > screenWidth - 34
                guard isSideMenuOpen || startsAtRightEdge else { return }

                if isSideMenuOpen {
                    sideMenuDragProgress = min(max(-value.translation.width / revealDistance, -1), 0)
                } else {
                    sideMenuDragProgress = min(max(-value.translation.width / revealDistance, 0), 1)
                }

                let effectiveProgress = sideMenuProgress()
                if effectiveProgress > 0.78, !didTriggerSideMenuHaptic {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.65)
                    didTriggerSideMenuHaptic = true
                }
            }
            .onEnded { value in
                let predicted = isSideMenuOpen
                    ? 1 + min(max(-value.predictedEndTranslation.width / revealDistance, -1), 0)
                    : min(max(-value.predictedEndTranslation.width / revealDistance, 0), 1)
                setSideMenu(open: predicted > 0.46)
            }
    }

    private var singleOccurrenceGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                singleCardDrag = max(min(value.translation.height, 42), -42)
            }
            .onEnded { _ in
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.35)
                withAnimation(.spring(response: 0.42, dampingFraction: 0.66)) { singleCardDrag = 0 }
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
    let team: Team?
    let profileName: String
    let sectionTitle: String?
    let openMenu: () -> Void
    let openPlan: () -> Void
    let openProfile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassEffectContainer(spacing: 14) {
                HomeTopBar(
                    team: team,
                    profileName: profileName,
                    openMenu: openMenu,
                    openPlan: openPlan,
                    openProfile: openProfile
                )
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
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .colorScheme(.dark)
    }
}

private struct HomeTopBar: View {
    let team: Team?
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
                    Text(team?.name ?? "المجموعة")
                        .font(TamrinFont.font(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)

                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .frame(height: 48)
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

private struct AddChooserSheet: View {
    @Bindable var store: TamrinStore
    let createExercise: () -> Void
    let createTeam: () -> Void
    let joinTeam: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("وش تبغى تضيف؟").font(TamrinFont.font(size: 27, weight: .bold))
            VStack(spacing: 10) {
                if store.isAdmin {
                    action("تمرين جديد", "موعد متكرر أو مرة واحدة", "figure.run.circle.fill", createExercise)
                } else {
                    action("انضم لمجموعة", "استخدم رمز الدعوة", "person.2.badge.plus", joinTeam)
                }
                action("مجموعة جديدة", "ابدأ مجموعة ورتّب تمارينها", "person.3.fill", createTeam)
            }
            Button("إلغاء") { dismiss() }
                .font(TamrinFont.font(size: 15, weight: .medium)).frame(maxWidth: .infinity).frame(height: 48)
        }
        .padding(22).padding(.top, 8)
        .presentationDetents([.height(store.isAdmin ? 350 : 350)])
        .presentationDragIndicator(.visible)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func action(_ title: String, _ subtitle: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                    .frame(width: 46, height: 46).background(TamrinTheme.secondary, in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(TamrinFont.font(size: 16, weight: .bold))
                    Text(subtitle).font(TamrinFont.font(size: 12, weight: .regular)).foregroundStyle(.secondary)
                }
                Spacer(); Image(systemName: "chevron.left").font(.caption.bold()).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary).padding(.horizontal, 15).frame(height: 72)
            .background(TamrinTheme.secondary.opacity(0.7), in: .capsule)
        }.buttonStyle(.plain)
    }
}

private struct TeamSideMenu: View {
    @Bindable var store: TamrinStore
    let close: () -> Void
    let createTeam: () -> Void
    let openSettings: () -> Void
    let openPayments: () -> Void
    let openNotifications: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let menuWidth = min(proxy.size.width - 94, 308)

            ZStack(alignment: .bottomLeading) {
                Color(red: 0.067, green: 0.067, blue: 0.067)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center, spacing: 14) {
                        Text("المجموعات")
                            .font(TamrinFont.font(size: 22, weight: .bold))
                            .foregroundStyle(.white)

                        Spacer()

                        Button(action: createTeam) {
                            Label("إنشاء مجموعة", systemImage: "plus")
                                .labelStyle(.iconOnly)
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
                            ForEach(store.teams, id: \.id) { team in
                                Button {
                                    store.selectedTeamID = team.id
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    close()
                                } label: {
                                    TeamSideMenuRow(
                                        team: team,
                                        plan: store.plans.first { $0.teamID == team.id },
                                        membersCount: store.memberships.filter { $0.teamID == team.id }.count,
                                        isSelected: store.currentTeam?.id == team.id
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(width: menuWidth)
                    }
                    .frame(maxHeight: proxy.size.height * 0.46)

                    Button(action: openPayments) {
                        HStack(spacing: 12) {
                            Image(systemName: store.isAdmin ? "chart.bar.doc.horizontal.fill" : "creditcard.fill")
                                .frame(width: 34, height: 34)
                                .background(.white.opacity(0.1), in: .circle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.isAdmin ? "تنظيم الدفع" : "دفعاتي")
                                    .font(TamrinFont.font(size: 15, weight: .bold))
                                Text(store.isAdmin ? "راجع التحويلات والمتأخرات" : "تابع القَطّات القادمة")
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
                    VStack(alignment: .leading, spacing: 12) {
                        ExperienceModeSwitcher(store: store, width: menuWidth)

                        HStack(spacing: 8) {
                            Button(action: openSettings) {
                                HStack(spacing: 10) {
                                    PlanMemberAvatar(name: store.profile?.name ?? "", size: 36, tint: .white.opacity(0.18))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(store.profile?.name ?? "حسابي").font(TamrinFont.font(size: 14, weight: .bold))
                                        Text(store.profile?.playerPosition.isEmpty == false ? store.profile?.playerPosition ?? "" : "الملف الشخصي")
                                            .font(TamrinFont.font(size: 10, weight: .regular)).foregroundStyle(.white.opacity(0.5))
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 52)
                            }
                            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule)
                            .accessibilityLabel("الملف الشخصي")

                            Button(action: openNotifications) {
                                Image(systemName: store.unreadCount > 0 ? "bell.badge.fill" : "bell.fill")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                            .accessibilityLabel("التنبيهات")
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, max(proxy.safeAreaInsets.bottom + 24, 40))
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

private struct ExperienceModeSwitcher: View {
    @Bindable var store: TamrinStore
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("استعرض التطبيق كـ")
                .font(TamrinFont.font(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))

            HStack(spacing: 6) {
                ForEach(ExperienceMode.allCases) { mode in
                    Button {
                        withAnimation(.snappy(duration: 0.28)) { store.experienceMode = mode }
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: mode.symbol)
                            Text(mode.title)
                        }
                        .font(TamrinFont.font(size: 13, weight: .bold))
                        .foregroundStyle(store.experienceMode == mode ? TamrinTheme.ink : .white.opacity(0.68))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(store.experienceMode == mode ? .white : .clear, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(mode.subtitle)
                }
            }
            .padding(5)
            .background(.white.opacity(0.08), in: .capsule)
        }
        .frame(width: width)
    }
}

private struct TeamSideMenuRow: View {
    let team: Team
    let plan: TrainingPlan?
    let membersCount: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            TeamAvatarView(
                team: team,
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
                Text("الأعضاء  \(membersCount)")
                    .font(TamrinFont.font(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .frame(height: 20, alignment: .center)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color(red: 0.10, green: 0.10, blue: 0.10), in: .rect(cornerRadius: 24, style: .continuous))
    }
}

private enum PlanDetailTab: String, CaseIterable, Identifiable {
    case info, members, payments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: "التمرين"
        case .members: "الأعضاء"
        case .payments: "الدفع"
        }
    }
}

private struct PlanTemplateDetailView: View {
    @Bindable var store: TamrinStore
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedTab: PlanDetailTab = .info
    @State private var selectedPlanID: UUID?
    @State private var isBarPinned = false
    @State private var isTabJumping = false
    @State private var didCopyCode = false

    private var team: Team? { store.currentTeam }
    private var teamPlans: [TrainingPlan] { store.teamPlans }
    private var plan: TrainingPlan? { teamPlans.first { $0.id == selectedPlanID } ?? teamPlans.first }
    private var members: [Membership] {
        guard let id = team?.id else { return [] }
        return store.memberships.filter { $0.teamID == id }.sorted {
            if $0.role != $1.role { return $0.role == .admin }
            return $0.displayName < $1.displayName
        }
    }
    private var dayText: String {
        guard let plan else { return "" }
        return plan.weekdays.compactMap { weekdayName($0) }.joined(separator: "، ")
    }
    private var artName: String {
        let seed = team?.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) } ?? 0
        return HomeView.artName(for: seed)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                HomeArtBackdrop(artName: artName, hasArt: true)

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            heroHeader

                            if teamPlans.count > 1 {
                                planSwitcher
                            }

                            PlanPillTabBar(selection: $selectedTab) { tab in
                                jump(to: tab, proxy: proxy)
                            }
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.frame(in: .global).minY
                            } action: { minY in
                                let pinned = minY <= geo.safeAreaInsets.top + 1
                                if pinned != isBarPinned {
                                    withAnimation(.easeInOut(duration: 0.2)) { isBarPinned = pinned }
                                }
                            }

                            infoSection
                                .id(PlanDetailTab.info)
                                .onScrollVisibilityChange(threshold: 0.4) { visible in
                                    if visible, !isTabJumping { withAnimation(.snappy(duration: 0.25)) { selectedTab = .info } }
                                }

                            membersCard
                                .id(PlanDetailTab.members)
                                .onScrollVisibilityChange(threshold: 0.35) { visible in
                                    if visible, !isTabJumping { withAnimation(.snappy(duration: 0.25)) { selectedTab = .members } }
                                }

                            paymentsSection
                                .id(PlanDetailTab.payments)
                                .onScrollVisibilityChange(threshold: 0.5) { visible in
                                    if visible, !isTabJumping { withAnimation(.snappy(duration: 0.25)) { selectedTab = .payments } }
                                }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .padding(.bottom, 40)
                    }
                    .mask {
                        // يخفي المحتوى المار خلف شريط التنقل وخلف التبويبات المثبتة بتلاشٍ ناعم
                        VStack(spacing: 0) {
                            Color.clear
                                .frame(height: geo.safeAreaInsets.top + (isBarPinned ? 54 : 0))
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: 16)
                            Color.black
                        }
                        .ignoresSafeArea()
                    }
                    .overlay(alignment: .top) {
                        if isBarPinned {
                            PlanPillTabBar(selection: $selectedTab) { tab in
                                jump(to: tab, proxy: proxy)
                            }
                            .padding(.horizontal, 20)
                            .transition(.opacity)
                        }
                    }
                    #if DEBUG
                    .task {
                        if ProcessInfo.processInfo.arguments.contains("-TamrinJumpPayments") {
                            try? await Task.sleep(for: .milliseconds(1200))
                            jump(to: .payments, proxy: proxy)
                        }
                    }
                    #endif
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .colorScheme(.dark)
        .navigationTitle(team?.name ?? "المجموعة")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            if let plan {
                mapPosition = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: plan.latitude, longitude: plan.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.018, longitudeDelta: 0.018)
                ))
            }
        }
    }

    private var planSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(teamPlans, id: \.id) { item in
                    let isSelected = item.id == plan?.id
                    Button {
                        selectedPlanID = item.id
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.easeOut(duration: 0.4)) {
                            mapPosition = .region(MKCoordinateRegion(
                                center: CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude),
                                span: MKCoordinateSpan(latitudeDelta: 0.018, longitudeDelta: 0.018)
                            ))
                        }
                    } label: {
                        Text(item.name)
                            .font(TamrinFont.font(size: 14, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? TamrinTheme.ink : .white)
                            .padding(.horizontal, 15)
                            .frame(height: 38)
                            .background(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.14)), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private func jump(to tab: PlanDetailTab, proxy: ScrollViewProxy) {
        UISelectionFeedbackGenerator().selectionChanged()
        isTabJumping = true
        withAnimation(.snappy(duration: 0.35)) {
            selectedTab = tab
            proxy.scrollTo(tab, anchor: UnitPoint(x: 0.5, y: 0.082))
        }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            isTabJumping = false
        }
    }

    private var heroHeader: some View {
        VStack(spacing: 16) {
            TeamAvatarView(
                team: team,
                size: 84,
                cornerRadiusRatio: 0.5,
                fallbackBackground: AnyShapeStyle(TamrinTheme.lime)
            )
            .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
            .shadow(color: TamrinTheme.lime.opacity(0.35), radius: 26, y: 10)

            VStack(spacing: 5) {
                Text(plan?.name ?? "قالب التمرين")
                    .font(TamrinFont.font(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(heroSubtitle)
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var heroSubtitle: String {
        var parts: [String] = ["\(members.count.formatted()) عضوًا"]
        if !dayText.isEmpty { parts.append("كل \(dayText)") }
        return parts.joined(separator: " · ")
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let plan {
                quickStats(plan)
                scheduleCard(plan)
                locationCard(plan)
            } else {
                PlanGlassSection(title: "قالب التمرين") {
                    Text("لا يوجد قالب تمرين بعد.")
                        .font(TamrinFont.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private func quickStats(_ plan: TrainingPlan) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            PlanGlassStat(
                symbol: "clock.fill",
                value: "\(plan.startTime.arabicTime) – \(plan.endTime.arabicTime)",
                title: "وقت التمرين"
            )
            PlanGlassStat(
                symbol: "person.2.fill",
                value: members.count.formatted(),
                title: "الأعضاء"
            )
            PlanGlassStat(
                symbol: "creditcard.fill",
                value: plan.price == 0 ? "مجاني" : "\(plan.price.cleanAmount) \(plan.currency)",
                title: "القَطّة"
            )
            PlanGlassStat(
                symbol: "figure.run",
                value: plan.capacity.formatted(),
                title: plan.capacityPolicy == .waitlist ? "السعة · قائمة انتظار" : "السعة · إغلاق التسجيل"
            )
        }
    }

    private func scheduleCard(_ plan: TrainingPlan) -> some View {
        PlanGlassSection(title: "الجدول") {
            VStack(spacing: 0) {
                PlanInfoRow(symbol: "calendar", title: "أيام التمرين", value: dayText.isEmpty ? "بدون تكرار" : dayText)
                Divider().overlay(.white.opacity(0.08))
                PlanInfoRow(symbol: "play.circle", title: "تاريخ البداية", value: plan.startDate.arabicDate)
                Divider().overlay(.white.opacity(0.08))
                PlanInfoRow(
                    symbol: "flag.checkered",
                    title: "تاريخ النهاية",
                    value: plan.endDate.map { $0.arabicDate } ?? "مستمرة بدون نهاية"
                )
            }
        }
    }

    private func locationCard(_ plan: TrainingPlan) -> some View {
        PlanGlassSection(title: "الموقع") {
            VStack(alignment: .leading, spacing: 12) {
                Map(position: $mapPosition) {
                    Marker(plan.locationName, coordinate: CLLocationCoordinate2D(latitude: plan.latitude, longitude: plan.longitude))
                        .tint(TamrinTheme.lime)
                }
                .frame(height: 168)
                .clipShape(.rect(cornerRadius: 18, style: .continuous))
                .allowsHitTesting(false)

                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TamrinTheme.lime)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.locationName)
                            .font(TamrinFont.font(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                        if !plan.locationAddress.isEmpty {
                            Text(plan.locationAddress)
                                .font(TamrinFont.font(size: 13, weight: .regular))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
            }
        }
    }

    private var membersCard: some View {
        PlanGlassSection(title: "الأعضاء · \(members.count.formatted())") {
            VStack(spacing: 0) {
                ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                    HStack(spacing: 12) {
                        PlanMemberAvatar(
                            name: member.displayName,
                            size: 40,
                            tint: member.role == .admin ? TamrinTheme.lime : Color.white.opacity(0.22)
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.displayName)
                                .font(TamrinFont.font(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                            Text(member.isPending ? "بانتظار الانضمام" : (member.role == .admin ? "مشرف المجموعة" : "عضو"))
                                .font(TamrinFont.font(size: 12, weight: .regular))
                                .foregroundStyle(.white.opacity(0.5))
                        }

                        Spacer()

                        if member.role == .admin {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(TamrinTheme.lime)
                        } else if member.isPending {
                            Image(systemName: "clock")
                                .font(.system(size: 14))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 10)

                    if index < members.count - 1 {
                        Divider().overlay(.white.opacity(0.08))
                    }
                }

                if members.isEmpty {
                    Text("لا يوجد أعضاء بعد.")
                        .font(TamrinFont.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private var paymentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            paymentsCard
            inviteCard
        }
    }

    private var paymentsCard: some View {
        PlanGlassSection(title: "طرق الدفع") {
            let methods = store.methodsForCurrentTeam()

            VStack(spacing: 0) {
                if methods.isEmpty {
                    Text("لم تُضف طرق دفع بعد.")
                        .font(TamrinFont.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(methods.enumerated()), id: \.element.id) { index, method in
                        HStack(spacing: 12) {
                            Image(systemName: method.kind == .bank ? "building.columns.fill" : "banknote.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(TamrinTheme.lime)
                                .frame(width: 40, height: 40)
                                .background(.white.opacity(0.1), in: .circle)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(method.title)
                                    .font(TamrinFont.font(size: 16, weight: .medium))
                                    .foregroundStyle(.white)
                                Text(method.kind == .bank ? "تحويل بنكي" : "دفع نقدي")
                                    .font(TamrinFont.font(size: 12, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.5))
                            }

                            Spacer()
                        }
                        .padding(.vertical, 10)

                        if index < methods.count - 1 {
                            Divider().overlay(.white.opacity(0.08))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var inviteCard: some View {
        if let team {
            PlanGlassSection(title: "الدعوة") {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Text(team.inviteCode)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .kerning(2)

                        Spacer()

                        Button {
                            UIPasteboard.general.string = team.inviteCode
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            withAnimation(.snappy) { didCopyCode = true }
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                withAnimation(.snappy) { didCopyCode = false }
                            }
                        } label: {
                            Label(didCopyCode ? "نُسخ" : "نسخ", systemImage: didCopyCode ? "checkmark" : "doc.on.doc")
                                .font(TamrinFont.font(size: 13, weight: .medium))
                                .foregroundStyle(didCopyCode ? TamrinTheme.lime : .white)
                                .padding(.horizontal, 13)
                                .frame(height: 34)
                                .background(.white.opacity(0.12), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                    .background(.white.opacity(0.07), in: .rect(cornerRadius: 16, style: .continuous))

                    if let url = URL(string: "tamrin://join/\(team.inviteCode)") {
                        ShareLink(item: url) {
                            Label("مشاركة رابط الانضمام", systemImage: "square.and.arrow.up")
                                .font(TamrinFont.headline)
                                .foregroundStyle(TamrinTheme.ink)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(TamrinTheme.lime, in: .rect(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(SpringCardPressStyle())
                    }
                }
            }
        }
    }

    private func weekdayName(_ value: Int) -> String? {
        [1:"الأحد",2:"الاثنين",3:"الثلاثاء",4:"الأربعاء",5:"الخميس",6:"الجمعة",7:"السبت"][value]
    }
}

private struct PlanPillTabBar: View {
    @Binding var selection: PlanDetailTab
    let onTap: (PlanDetailTab) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(PlanDetailTab.allCases) { tab in
                    Button {
                        onTap(tab)
                    } label: {
                        Text(tab.title)
                            .font(TamrinFont.font(size: 15, weight: selection == tab ? .bold : .medium))
                            .foregroundStyle(selection == tab ? TamrinTheme.ink : .white.opacity(0.85))
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        selection == tab ? .regular.tint(.white).interactive() : .regular.interactive(),
                        in: .capsule
                    )
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
    }
}

private struct PlanInfoRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TamrinTheme.lime)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.1), in: .circle)

            Text(title)
                .font(TamrinFont.font(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))

            Spacer()

            Text(value)
                .font(TamrinFont.font(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 9)
    }
}

private struct PlanGlassSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(TamrinFont.font(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
        }
    }
}

private struct PlanGlassStat: View {
    let symbol: String
    let value: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TamrinTheme.lime)

            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(TamrinFont.font(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(title)
                    .font(TamrinFont.font(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
        }
    }
}

private struct AppSettingsView: View {
    @Bindable var store: TamrinStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var position = ""
    @State private var customPosition = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var showResetConfirm = false
    @State private var isEditing = false
    @State private var selectedDetent: PresentationDetent = .height(410)
    private let positions = ["حارس", "دفاع", "وسط", "هجوم", "مخصص"]

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                Group {
                    if isEditing { editorContent.transition(.move(edge: .leading).combined(with: .opacity)) }
                    else { overviewContent.transition(.move(edge: .trailing).combined(with: .opacity)) }
                }
                .padding(22)
            }
            .navigationTitle(isEditing ? "تعديل الحساب" : "حسابي")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEditing ? "رجوع" : "إغلاق") {
                        if isEditing { withAnimation(.snappy) { isEditing = false; selectedDetent = .height(410) } }
                        else { dismiss() }
                    }
                }
            }
            .task(id: photoItem) { if let data = try? await photoItem?.loadTransferable(type: Data.self) { avatarData = data } }
            .onAppear {
                name = store.profile?.name ?? ""; avatarData = store.profile?.avatarData
                let saved = store.profile?.playerPosition ?? ""
                if positions.contains(saved) { position = saved } else if !saved.isEmpty { position = "مخصص"; customPosition = saved }
            }
            .alert("إعادة بيانات التجربة؟", isPresented: $showResetConfirm) {
                Button("إعادة الضبط", role: .destructive) { store.resetDemoExperience(); dismiss() }
                Button("تراجع", role: .cancel) {}
            } message: { Text("بنرجّع كل السيناريوهات التجريبية لحالتها الأصلية.") }
        }
        .presentationDetents([.height(410), .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private var profileAvatar: some View {
        Group {
            if let avatarData, let image = UIImage(data: avatarData) { Image(uiImage: image).resizable().scaledToFill() }
            else { Circle().fill(TamrinTheme.ink).overlay(Text(String(name.prefix(1))).font(TamrinFont.font(size: 32, weight: .bold)).foregroundStyle(.white)) }
        }
        .frame(width: 92, height: 92).clipShape(.circle)
    }

    private var overviewContent: some View {
        VStack(spacing: 18) {
            profileAvatar
            VStack(spacing: 3) {
                Text(name).font(TamrinFont.font(size: 27, weight: .bold))
                Text(store.profile?.playerPosition.isEmpty == false ? store.profile?.playerPosition ?? "" : "بدون مركز محدد")
                    .font(TamrinFont.font(size: 13, weight: .regular)).foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.snappy) { isEditing = true; selectedDetent = .large }
            } label: {
                Label("تعديل حسابي", systemImage: "pencil")
                    .font(TamrinFont.font(size: 15, weight: .bold)).frame(maxWidth: .infinity).frame(height: 50)
            }
            .buttonStyle(.glass).buttonBorderShape(.capsule)

            #if DEBUG
            Button(role: .destructive) { showResetConfirm = true } label: {
                Label("إعادة بيانات التجربة", systemImage: "arrow.counterclockwise")
                    .font(TamrinFont.font(size: 14, weight: .medium)).frame(maxWidth: .infinity).frame(height: 48)
            }.buttonStyle(.bordered).buttonBorderShape(.capsule)
            #endif
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                profileAvatar.overlay(alignment: .bottomLeading) {
                    Image(systemName: "camera.fill").frame(width: 34, height: 34).background(.regularMaterial, in: .circle)
                }
            }.frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Text("اسمك").font(TamrinFont.font(size: 13, weight: .medium)).foregroundStyle(.secondary)
                TextField("الاسم", text: $name).font(TamrinFont.font(size: 22, weight: .bold))
                    .padding(.horizontal, 20).frame(height: 60).background(TamrinTheme.secondary, in: .capsule)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("مركزك في الملعب").font(TamrinFont.font(size: 13, weight: .medium)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92))], spacing: 8) {
                    ForEach(positions, id: \.self) { value in
                        Button { position = value; UISelectionFeedbackGenerator().selectionChanged() } label: {
                            Text(value).font(TamrinFont.font(size: 14, weight: .bold)).frame(maxWidth: .infinity).frame(height: 44)
                                .foregroundStyle(position == value ? .white : .primary)
                                .background(position == value ? TamrinTheme.ink : TamrinTheme.secondary, in: .capsule)
                        }.buttonStyle(.plain)
                    }
                }
                if position == "مخصص" {
                    TextField("اكتب مركزك", text: $customPosition).padding(.horizontal, 18).frame(height: 54).background(TamrinTheme.secondary, in: .capsule)
                }
            }
            Button("حفظ التغييرات") {
                store.saveProfile(name: name, avatarData: avatarData, playerPosition: position == "مخصص" ? customPosition : position)
                UINotificationFeedbackGenerator().notificationOccurred(.success); dismiss()
            }.buttonStyle(PrimaryActionStyle()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

struct PlanNavigationTitle: View {
    let team: Team?
    let plan: TrainingPlan?

    var body: some View {
        ZStack(alignment: .top) {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .fill(Color(uiColor: .systemBackground).opacity(0.58))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color(uiColor: .separator).opacity(0.13), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.10), radius: 12, y: 5)
                .frame(width: 194, height: 42)
                .offset(y: 48)

            HStack(spacing: 7) {
                Text(plan?.name ?? "تمرين")
                    .font(TamrinFont.font(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Image(systemName: "chevron.compact.left")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            .frame(width: 162, height: 42)
            .offset(y: 54)

            PlanTitleBubbleAvatar(symbol: team?.symbol ?? "figure.run")
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: PlanRevealSourceFramePreferenceKey.self,
                            value: proxy.frame(in: .global)
                        )
                    }
                }
        }
        .frame(width: 214, height: 94)
        .contentShape(.rect)
    }
}

private struct PlanTitleBubbleAvatar: View {
    let symbol: String

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            TamrinTheme.lime.opacity(0.95),
                            Color(uiColor: .systemBackground)
                        ],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                )
            Circle()
                .fill(.ultraThinMaterial)
                .opacity(0.20)
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(TamrinTheme.ink)
        }
        .frame(width: 58, height: 58)
        .overlay {
            Circle()
                .stroke(.white.opacity(0.86), lineWidth: 2.4)
        }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}

private enum PlanOverlayTab: String, CaseIterable, Identifiable {
    case members, location, info
    var id: String { rawValue }
    var title: String {
        switch self {
        case .members: "الأعضاء"
        case .location: "الموقع"
        case .info: "المعلومات"
        }
    }
}

struct PlanDetailsOverlay: View {
    @Bindable var store: TamrinStore
    let sourceFrame: CGRect
    let close: () -> Void
    @State private var selectedTab: PlanOverlayTab = .members
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var dragOffset: CGFloat = 0
    @State private var revealProgress: CGFloat = 0
    @State private var isClosing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var team: Team? { store.currentTeam }
    private var plan: TrainingPlan? { store.currentPlan }
    private var debugSlowMotion: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-TamrinSlowPlanOverlay")
        #else
        false
        #endif
    }
    private var debugAutoClose: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-TamrinAutoClosePlanOverlay")
        #else
        false
        #endif
    }
    private var openRevealAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return debugSlowMotion
            ? .timingCurve(0.18, 0.92, 0.22, 1.0, duration: 1.12)
            : .timingCurve(0.18, 0.92, 0.22, 1.0, duration: 0.32)
    }
    private var closeRevealAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return debugSlowMotion
            ? .timingCurve(0.20, 0.90, 0.24, 1.0, duration: 0.92)
            : .timingCurve(0.20, 0.90, 0.24, 1.0, duration: 0.26)
    }
    private var closeRevealDelay: Duration {
        .milliseconds(reduceMotion ? 0 : (debugSlowMotion ? 940 : 270))
    }
    private var members: [Membership] {
        guard let id = team?.id else { return [] }
        return store.memberships.filter { $0.teamID == id }.sorted {
            if $0.role != $1.role { return $0.role == .admin }
            return $0.displayName < $1.displayName
        }
    }
    private var confirmedNext: Int {
        guard let next = store.teamOccurrences.first else { return 0 }
        return store.registrations(for: next).filter { $0.status == .registered }.count
    }
    private var dayText: String {
        guard let plan else { return "بدون تكرار" }
        let names = [1:"الأحد",2:"الاثنين",3:"الثلاثاء",4:"الأربعاء",5:"الخميس",6:"الجمعة",7:"السبت"]
        return plan.weekdays.compactMap { names[$0] }.joined(separator: "، ")
    }
    private var contentProgress: CGFloat {
        guard !reduceMotion else { return 1 }
        let lowerBound: CGFloat = 0.34
        let upperBound: CGFloat = 0.72
        return min(max((revealProgress - lowerBound) / (upperBound - lowerBound), 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let revealFrame = revealFrame(in: proxy)
            let revealShape = RoundedRectangle(
                cornerRadius: interpolated(from: revealStartCornerRadius(in: proxy), to: 0),
                style: .continuous
            )

            ZStack(alignment: .top) {
                revealSurface(shape: revealShape)
                    .frame(width: revealFrame.width, height: revealFrame.height)
                    .position(x: revealFrame.midX, y: revealFrame.midY)
                    .shadow(color: .black.opacity(0.10 * revealProgress), radius: 28 * revealProgress, y: 10 * revealProgress)
                    .allowsHitTesting(false)

                overlayContent(proxy: proxy)
                    .opacity(contentProgress)
                    .scaleEffect(0.985 + (0.015 * contentProgress), anchor: .top)
                    .clipShape(revealShape)
                    .frame(width: revealFrame.width, height: revealFrame.height)
                    .position(x: revealFrame.midX, y: revealFrame.midY)
                    .allowsHitTesting(contentProgress > 0.98 && !isClosing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .offset(y: max(dragOffset, 0))
        .ignoresSafeArea()
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard value.translation.height > 0 else { return }
                    dragOffset = reduceMotion ? 0 : min(value.translation.height, 140)
                }
                .onEnded { value in
                    if value.translation.height > 86 || value.predictedEndTranslation.height > 160 {
                        dismissOverlay()
                    } else {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .onAppear {
            if let plan {
                mapPosition = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: plan.latitude, longitude: plan.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.018, longitudeDelta: 0.018)
                ))
            }
            Task {
                withAnimation(openRevealAnimation) {
                    revealProgress = 1
                }
                if debugAutoClose {
                    try? await Task.sleep(for: .milliseconds(debugSlowMotion ? 1900 : 950))
                    await MainActor.run {
                        dismissOverlay()
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88), value: selectedTab)
    }

    private func dismissOverlay() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.9)) {
            dragOffset = 0
        }
        Task {
            await MainActor.run {
                withAnimation(closeRevealAnimation) {
                    revealProgress = 0
                }
            }
            try? await Task.sleep(for: closeRevealDelay)
            await MainActor.run { close() }
        }
    }

    private func overlayContent(proxy: GeometryProxy) -> some View {
        ZStack(alignment: .top) {
            List {
                Section {
                    overlayHeader
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 0))
                        .listRowBackground(Color.clear)

                    Picker("تفاصيل التمرين", selection: $selectedTab) {
                        ForEach(PlanOverlayTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                planActionRows
                planDetailRows
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, nativeTopInset(in: proxy) + 52, for: .scrollContent)
            .contentMargins(.bottom, max(proxy.safeAreaInsets.bottom, 18), for: .scrollContent)

            HStack {
                NativeCloseButton(action: dismissOverlay)
                    .frame(width: 34, height: 34)
                .accessibilityLabel("إغلاق تفاصيل التمرين")
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, nativeTopInset(in: proxy) + 8)
        }
    }

    @ViewBuilder
    private var planDetailRows: some View {
        switch selectedTab {
        case .members:
            Section("الأعضاء") {
                LabeledContent("عدد الأعضاء", value: "\(members.count)")
                ForEach(members, id: \.id) { member in
                    HStack(spacing: 12) {
                        PlanMemberAvatar(name: member.displayName, size: 38, tint: member.role == .admin ? TamrinTheme.lime : Color(uiColor: .secondarySystemFill))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.displayName)
                                .font(.body.weight(.semibold))
                            Text(member.isPending ? "بانتظار الانضمام" : (member.role == .admin ? "مشرف الفريق" : "عضو"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if member.role == .admin {
                            Image(systemName: "crown.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(TamrinTheme.lime)
                        } else if member.isPending {
                            Image(systemName: "clock")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }

        case .location:
            if let plan {
                Section("الموقع") {
                    Map(position: $mapPosition) {
                        Marker(plan.locationName, coordinate: CLLocationCoordinate2D(latitude: plan.latitude, longitude: plan.longitude))
                    }
                    .frame(height: 230)
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))

                    Label(plan.locationName, systemImage: "mappin.and.ellipse")
                        .font(.body.weight(.semibold))

                    if !plan.locationAddress.isEmpty {
                        Text(plan.locationAddress)
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .info:
            if let plan {
                Section("المعلومات") {
                    PlanNativeInfoRow(symbol: "calendar", title: "التكرار", value: dayText)
                    PlanNativeInfoRow(symbol: "clock", title: "الوقت", value: "\(plan.startTime.arabicTime) – \(plan.endTime.arabicTime)")
                    PlanNativeInfoRow(symbol: "person.crop.circle.badge.clock", title: "سياسة الامتلاء", value: plan.capacityPolicy == .waitlist ? "قائمة انتظار" : "إغلاق التسجيل")
                    PlanNativeInfoRow(symbol: "creditcard", title: "القَطّة", value: plan.price == 0 ? "مجاني" : "\(plan.price.cleanAmount) \(plan.currency)")
                    PlanNativeInfoRow(symbol: "person.2", title: "السعة", value: "\(plan.capacity)")
                    PlanNativeInfoRow(symbol: "checkmark", title: "مسجلين للموعد القادم", value: "\(confirmedNext)")
                }

                Section("طرق الدفع") {
                    let methods = store.methodsForCurrentTeam()
                    if methods.isEmpty {
                        Text("لم تُضف طرق دفع بعد.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(methods, id: \.id) { method in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(method.title)
                                    Text(method.kind == .bank ? "تحويل بنكي" : "دفع نقدي")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: method.kind == .bank ? "building.columns.fill" : "banknote.fill")
                                    .symbolRenderingMode(.hierarchical)
                            }
                        }
                    }
                }
            }
        }
    }

    private func revealSurface(shape: RoundedRectangle) -> some View {
        shape
            .fill(.regularMaterial)
            .overlay {
                shape
                    .fill(Color(uiColor: .systemGroupedBackground).opacity(0.76 * revealProgress))
            }
            .overlay {
                shape
                    .fill(.white.opacity(0.03 * revealProgress))
            }
    }

    private func revealFrame(in proxy: GeometryProxy) -> CGRect {
        let start = revealStartFrame(in: proxy)
        let end = CGRect(x: 0, y: 0, width: proxy.size.width, height: proxy.size.height)
        return CGRect(
            x: interpolated(from: start.minX, to: end.minX),
            y: interpolated(from: start.minY, to: end.minY),
            width: interpolated(from: start.width, to: end.width),
            height: interpolated(from: start.height, to: end.height)
        )
    }

    private func revealStartFrame(in proxy: GeometryProxy) -> CGRect {
        let fallbackSize: CGFloat = 58
        let fallbackStart = CGRect(
            x: (proxy.size.width - fallbackSize) / 2,
            y: nativeTopInset(in: proxy) + 8,
            width: fallbackSize,
            height: fallbackSize
        )
        let rawStart = sourceFrame.isEmpty ? fallbackStart : sourceFrame
        return rawStart.insetBy(dx: -12, dy: -12)
    }

    private func revealStartCornerRadius(in proxy: GeometryProxy) -> CGFloat {
        let start = revealStartFrame(in: proxy)
        return min(start.width, start.height) / 2
    }

    private func interpolated(from start: CGFloat, to end: CGFloat) -> CGFloat {
        start + (end - start) * revealProgress
    }

    private func nativeTopInset(in proxy: GeometryProxy) -> CGFloat {
        max(proxy.safeAreaInsets.top, 44)
    }

    private var overlayHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                ForEach(Array(members.prefix(3).enumerated()), id: \.offset) { index, member in
                    PlanMemberAvatar(name: member.displayName, size: 62, tint: index == 0 ? TamrinTheme.lime : TamrinTheme.glass)
                        .offset(x: CGFloat(index - 1) * 38, y: index == 1 ? -6 : 5)
                        .zIndex(Double(3 - index))
                }
                if members.isEmpty {
                    PlanSymbolAvatar(symbol: team?.symbol ?? "figure.run", size: 82)
                } else {
                    PlanSymbolAvatar(symbol: team?.symbol ?? "figure.run", size: 56)
                        .offset(y: 38)
                }
            }
            .frame(height: 116)
            .padding(.top, 6)

            VStack(spacing: 3) {
                Text(plan?.name ?? "تمرين")
                    .font(TamrinFont.font(size: 31, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
                Text(team?.name ?? "الفريق")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(members.count) أعضاء · \(dayText)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 48)
    }

    @ViewBuilder
    private var planActionRows: some View {
        if let team, let url = URL(string: "tamrin://join/\(team.inviteCode)") {
            Section("إجراءات") {
                ShareLink(item: url) {
                    Label("مشاركة رابط الانضمام", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

}

private struct NativeCloseButton: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .close)
        button.addTarget(context.coordinator, action: #selector(Coordinator.close), for: .touchUpInside)
        button.accessibilityTraits.insert(.button)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func close() {
            action()
        }
    }
}

private struct PlanSymbolAvatar: View {
    let symbol: String
    let size: CGFloat
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(TamrinTheme.ink)
            .frame(width: size, height: size)
            .background(TamrinTheme.lime, in: .circle)
            .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 3))
            .shadow(color: TamrinTheme.lime.opacity(0.35), radius: 22, y: 10)
    }
}

struct PlanMemberAvatar: View {
    let name: String
    let size: CGFloat
    var tint: Color
    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: size, height: size)
            .overlay(Text(String(name.prefix(1))).font(TamrinFont.font(size: size * 0.38, weight: .bold)).foregroundStyle(TamrinTheme.ink))
            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 3))
            .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
    }
}

private struct PlanNativeInfoRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

struct PlanQuickPanel: View {
    @Bindable var store: TamrinStore
    let plan: TrainingPlan
    @State private var showMembers = false

    private var dayText: String {
        let names = [1:"الأحد",2:"الاثنين",3:"الثلاثاء",4:"الأربعاء",5:"الخميس",6:"الجمعة",7:"السبت"]
        return plan.weekdays.compactMap { names[$0] }.joined(separator: "، ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) { Text(plan.name).font(TamrinFont.title2); Text(dayText).font(.subheadline).foregroundStyle(.secondary) }
                Spacer(); StatusPill(text: store.isAdmin ? "مشرف" : "عضو", symbol: store.isAdmin ? "crown.fill" : "person.fill")
            }
            Divider().overlay(.white.opacity(0.16))
            HStack(spacing: 8) {
                PlanMetric(symbol: "clock", title: plan.startTime.arabicTime)
                PlanMetric(symbol: "mappin", title: plan.locationName)
                PlanMetric(symbol: "person.2", title: "\(plan.capacity)")
            }
            HStack(spacing: 10) {
                Button { showMembers = true } label: { Label("الفريق", systemImage: "person.3") }.buttonStyle(.bordered)
                if let team = store.currentTeam {
                    ShareLink(item: URL(string: "tamrin://join/\(team.inviteCode)")!) { Label("دعوة", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(LinearGradient(colors: [TamrinTheme.ink, Color(red: 0.16, green: 0.20, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.14), radius: 26, y: 12)
        .sheet(isPresented: $showMembers) { MembersView(store: store) }
    }
}

struct PlanMetric: View {
    let symbol: String; let title: String
    var body: some View { Label(title, systemImage: symbol).font(.caption.weight(.medium)).lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 11).background(.white.opacity(0.1), in: .rect(cornerRadius: 12)) }
}

struct ExercisePosterCard: View {
    @Bindable var store: TamrinStore
    let occurrence: Occurrence
    let artIndex: Int
    let action: () -> Void
    @State private var showEdit = false
    @State private var showCancel = false

    private var title: String { store.plan(for: occurrence)?.name ?? "التمرين الأسبوعي" }
    private var artName: String { HomeView.artName(for: artIndex) }

    var body: some View {
        VStack(spacing: 10) {
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
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .background(.red.opacity(0.85), in: .capsule)
                    } else if store.isAdmin {
                        Text(publicationLabel)
                            .font(TamrinFont.font(size: 12, weight: .bold))
                            .foregroundStyle(occurrence.publicationStatus == .ready ? TamrinTheme.ink : .white)
                            .padding(.horizontal, 13).padding(.vertical, 6)
                            .background(occurrence.publicationStatus == .ready ? TamrinTheme.lime : .black.opacity(0.45), in: .capsule)
                    }

                    Text(title)
                        .font(TamrinFont.font(size: 27, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text("\(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
                        .font(TamrinFont.font(size: 15, weight: .medium))
                        .opacity(0.82)

                    Text("\(occurrence.locationName) · \(store.registrations(for: occurrence).count)/\(occurrence.capacity) · \(occurrence.price == 0 ? "مجاني" : "\(occurrence.price.cleanAmount) ﷼")")
                        .font(TamrinFont.font(size: 12, weight: .regular))
                        .opacity(0.68).lineLimit(1)
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 72)
                .padding(.bottom, 56)
                .frame(maxWidth: .infinity)
                .background {
                    // مطابق لطبقة التصميم في فيقما: تمويه تدريجي 0→28 مع تدرج أسود بشفافية كلية 10٪
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        LinearGradient(
                            colors: [.black.opacity(0), .black.opacity(0.10)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.55), location: 0.5),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
                .colorScheme(.dark)
            }
            .clipShape(.rect(cornerRadius: 36, style: .continuous))
            .contentShape(.rect(cornerRadius: 36, style: .continuous))
        }
            .buttonStyle(SpringCardPressStyle())
            .accessibilityLabel("\(title)، \(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
            .accessibilityHint("يفتح تفاصيل الموعد")

            if store.isAdmin {
                AdminOccurrenceActions(store: store, occurrence: occurrence, edit: { showEdit = true }, cancel: { showCancel = true })
            }
        }
        .sheet(isPresented: $showEdit) { EditOccurrenceView(store: store, occurrence: occurrence) }
        .sheet(isPresented: $showCancel) { CancelOccurrenceSheet(store: store, occurrence: occurrence) }
    }

    private var publicationLabel: String {
        switch occurrence.publicationStatus {
        case .draft: "مجدول للتجهيز"
        case .ready: "جاهز للإرسال"
        case .published: "تم إرساله"
        case .cancelled: "ملغي"
        }
    }
}

private struct AdminOccurrenceActions: View {
    @Bindable var store: TamrinStore
    let occurrence: Occurrence
    let edit: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if occurrence.publicationStatus == .cancelled {
                Button {
                    store.undoCancellation(occurrence)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label("تراجع عن الإلغاء", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity).frame(height: 48)
                }.buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(.orange)
            } else if occurrence.publicationStatus != .published {
                Button {
                    store.publish(occurrence)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label("أرسل التمرين", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity).frame(height: 48)
                }
                .buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(.blue)
            }

            if occurrence.publicationStatus != .cancelled {
                Button(action: edit) {
                    Image(systemName: "pencil").frame(width: 48, height: 48)
                }.buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("تعديل هذا الموعد")

                Button(action: cancel) {
                    Image(systemName: "calendar.badge.minus").frame(width: 48, height: 48)
                }.buttonStyle(.glass).buttonBorderShape(.circle).tint(.red).accessibilityLabel("إلغاء هذا الأسبوع")
            }
        }
        .colorScheme(.dark)
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

struct OccurrenceDetailView: View {
    @Bindable var store: TamrinStore
    let occurrence: Occurrence
    var artName: String = "ExerciseArt1"
    @Environment(\.dismiss) private var dismiss
    @State private var showRegisterFlow = false
    @State private var showPayment = false
    @State private var showEdit = false
    @State private var showCancelAlert = false
    @State private var showCancelSheet = false
    @State private var showWithdrawConfirm = false

    private var roster: [Registration] { store.registrations(for: occurrence) }
    private var myRegistration: Registration? { store.myRegistration(for: occurrence) }
    private var confirmed: [Registration] { roster.filter { $0.status == .registered } }
    private var waiting: [Registration] { roster.filter { $0.status == .waitlisted } }
    private var title: String { store.plan(for: occurrence)?.name ?? "التمرين الأسبوعي" }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                ZStack {
                    Image(artName)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()

                    // ضبابية على الخلفية كاملة تتلاشى عند عنوان التمرين
                    Image(artName)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: 26, opaque: true)
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .clear, location: 0.33),
                                    .init(color: .black, location: 0.46),
                                    .init(color: .black, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                }
            }
            .ignoresSafeArea()

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.32), location: 0),
                    .init(color: .black.opacity(0.06), location: 0.26),
                    .init(color: .black.opacity(0.30), location: 0.55),
                    .init(color: .black.opacity(0.58), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    heroTitle
                        .padding(.top, 264)
                        .padding(.bottom, 6)

                    if !occurrence.isCancelled {
                        participationCTA
                    }

                    progressPanel

                    Text("القائمة")
                        .font(TamrinFont.font(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.top, 8)
                        .padding(.horizontal, 4)

                    rosterRows

                    if store.isAdmin { adminPayments }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
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
        .overlay(alignment: .topTrailing) {
            if store.isAdmin {
                Menu {
                    Button("تعديل الموعد", systemImage: "pencil") { showEdit = true }
                    Button("إلغاء هذا الأسبوع", systemImage: "xmark.circle", role: .destructive) { showCancelSheet = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .accessibilityLabel("خيارات الموعد")
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .colorScheme(.dark)
        .sheet(isPresented: $showRegisterFlow) {
            RegistrationFlowSheet(store: store, occurrence: occurrence, artName: artName)
        }
        .sheet(isPresented: $showPayment) {
            RegistrationFlowSheet(store: store, occurrence: occurrence, artName: artName, startStep: .methodPicker)
        }
        .sheet(isPresented: $showEdit) { EditOccurrenceView(store: store, occurrence: occurrence) }
        .sheet(isPresented: $showCancelSheet) { CancelOccurrenceSheet(store: store, occurrence: occurrence) }
        .sheet(isPresented: $showWithdrawConfirm) { RegistrationCancellationSheet(store: store, occurrence: occurrence) }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-TamrinOpenRegisterSheet") {
                try? await Task.sleep(for: .milliseconds(1600))
                showRegisterFlow = true
            } else if ProcessInfo.processInfo.arguments.contains("-TamrinOpenPaySheet") {
                try? await Task.sleep(for: .milliseconds(1600))
                showPayment = true
            } else if ProcessInfo.processInfo.arguments.contains("-TamrinOpenWithdrawSheet") {
                try? await Task.sleep(for: .milliseconds(1600))
                showWithdrawConfirm = true
            }
        }
        #endif
        .alert("إلغاء الموعد؟", isPresented: $showCancelAlert) {
            Button("إلغاء الموعد", role: .destructive) { store.cancel(occurrence) }
            Button("تراجع", role: .cancel) {}
        } message: {
            Text("سيبقى الموعد ظاهراً للأعضاء بحالة ملغي.")
        }
    }

    private var heroTitle: some View {
        VStack(spacing: 7) {
            if occurrence.isCancelled {
                Text("تم إلغاء الموعد")
                    .font(TamrinFont.font(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.85), in: .capsule)
            } else if occurrence.isOverride {
                Text("معدّل لهذا الأسبوع")
                    .font(TamrinFont.font(size: 13, weight: .bold))
                    .foregroundStyle(TamrinTheme.ink)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.9), in: .capsule)
            }

            Text(title)
                .font(TamrinFont.font(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
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
        if let registration = myRegistration {
            Button { showWithdrawConfirm = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: registration.status == .registered ? "checkmark.circle.fill" : "clock.fill")
                        .foregroundStyle(registration.status == .registered ? TamrinTheme.lime : .orange)
                    Text(registration.status == .registered ? "مكانك محفوظ" : "أنت في قائمة الانتظار")
                        .font(TamrinFont.font(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(registration.status == .registered ? "اعتذر" : "انسحب")
                        .font(TamrinFont.font(size: 13, weight: .medium))
                        .foregroundStyle(.red.opacity(0.95))
                }
                .padding(.horizontal, 18).frame(maxWidth: .infinity).frame(height: 52)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityHint("يفتح تأكيد الاعتذار عن التمرين")

            if registration.status == .registered, occurrence.price > 0,
               let payment = store.payment(for: occurrence), payment.status != .confirmed {
                Button {
                    showPayment = true
                } label: {
                    Label(
                        payment.status == .declared ? "بانتظار تأكيد المشرف" : "دفع \(occurrence.price.cleanAmount) ر.س",
                        systemImage: payment.status == .declared ? "clock" : "creditcard"
                    )
                    .font(TamrinFont.headline)
                    .foregroundStyle(TamrinTheme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(TamrinTheme.lime).interactive(), in: .capsule)
                .disabled(payment.status == .declared)
                .opacity(payment.status == .declared ? 0.6 : 1)
            }
        } else {
            let full = confirmed.count >= occurrence.capacity
            let closed = full && occurrence.capacityPolicy == .closed

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showRegisterFlow = true
            } label: {
                Label(
                    closed ? "التسجيل مكتمل" : (full ? "انضم لقائمة الانتظار" : "سجل في التمرين"),
                    systemImage: closed ? "lock" : "plus"
                )
                .font(TamrinFont.font(size: 16, weight: .bold))
                .foregroundStyle(closed ? .white.opacity(0.55) : TamrinTheme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(
                closed ? .regular.interactive() : .regular.tint(.white.opacity(0.94)).interactive(),
                in: .capsule
            )
            .disabled(closed)
        }
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("نسبة إكتمال التمرين")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white)

                Spacer()

                Text("\(confirmed.count.formatted())\\\(occurrence.capacity.formatted())")
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }

            ProgressView(value: Double(confirmed.count), total: Double(max(occurrence.capacity, 1)))
                .tint(TamrinTheme.lime)

            if !waiting.isEmpty {
                Text("\(waiting.count.formatted()) في قائمة الانتظار")
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
                ForEach(roster, id: \.id) { person in
                    HStack(spacing: 12) {
                        PlanMemberAvatar(name: person.displayName, size: 34, tint: .white.opacity(0.28))

                        Text(person.displayName)
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(.white.opacity(0.1), in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var adminPayments: some View {
        let records = store.paymentRecords.filter { $0.occurrenceID == occurrence.id }

        VStack(alignment: .leading, spacing: 12) {
            Text("تحصيل القَطّة")
                .font(TamrinFont.font(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 4)

            if records.isEmpty {
                Text("لا توجد دفعات لهذا الموعد.")
                    .font(TamrinFont.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.white.opacity(0.1), in: .rect(cornerRadius: 16, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(records, id: \.id) { record in
                        let name = roster.first { $0.userID == record.userID }?.displayName ?? "لاعب"
                        PaymentAdminRow(store: store, record: record, name: name)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.1), in: .rect(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}

struct MembersView: View {
    @Bindable var store: TamrinStore
    @Environment(\.dismiss) private var dismiss
    var body: some View { NavigationStack { List { if let team = store.currentTeam { Section("رمز الدعوة") { HStack { Text(team.inviteCode).font(.headline.monospaced()); Spacer(); ShareLink(item: URL(string: "tamrin://join/\(team.inviteCode)")!) { Image(systemName: "square.and.arrow.up") } } }; Section("الأعضاء") { ForEach(store.memberships.filter { $0.teamID == team.id }, id: \.id) { member in HStack { Text(member.displayName); Spacer(); Text(member.isPending ? "بانتظار الانضمام" : (member.role == .admin ? "مشرف" : "عضو")).font(.caption).foregroundStyle(.secondary) } } } } }.navigationTitle("الأعضاء").toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } } } }
}

struct NotificationCenterView: View {
    @Bindable var store: TamrinStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedOccurrence: Occurrence?
    private var items: [AppNotification] { guard let id = store.profile?.id else { return [] }; return store.notifications.filter { $0.userID == id } }
    var body: some View {
        NavigationStack {
            ScrollView {
                if items.isEmpty { ContentUnavailableView("لا توجد تنبيهات", systemImage: "bell", description: Text("بنحط هنا مواعيد الإرسال وأي تغيير مهم.")) .padding(.top, 90) }
                else {
                    LazyVStack(spacing: 10) {
                        ForEach(items, id: \.id) { item in
                            Button {
                                if let id = item.occurrenceID { selectedOccurrence = store.occurrences.first { $0.id == id } }
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: item.occurrenceID == nil ? "bell.fill" : "calendar.badge.clock").frame(width: 40, height: 40).background(TamrinTheme.secondary, in: .circle)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title).font(TamrinFont.font(size: 16, weight: .bold))
                                        Text(item.message).font(TamrinFont.font(size: 13, weight: .regular)).foregroundStyle(.secondary)
                                        Text(item.createdAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    if item.occurrenceID != nil { Image(systemName: "chevron.left").font(.caption.bold()).foregroundStyle(.tertiary) }
                                }
                                .foregroundStyle(.primary).padding(15).background(TamrinTheme.secondary.opacity(0.7), in: .rect(cornerRadius: 22, style: .continuous))
                            }.buttonStyle(.plain)
                        }
                    }.padding(20)
                }
            }
            .navigationTitle("التنبيهات")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { store.markNotificationsRead(); dismiss() } } }
            .onAppear { store.markNotificationsRead() }
            .fullScreenCover(item: $selectedOccurrence) { OccurrenceDetailView(store: store, occurrence: $0) }
        }
        .environment(\.layoutDirection, .rightToLeft).presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}

struct EditOccurrenceView: View {
    @Bindable var store: TamrinStore
    let occurrence: Occurrence
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date; @State private var end: Date; @State private var location: String; @State private var capacity: Int; @State private var price: Double; @State private var capacityPolicy: CapacityPolicy
    init(store: TamrinStore, occurrence: Occurrence) { self.store = store; self.occurrence = occurrence; _start = State(initialValue: occurrence.startAt); _end = State(initialValue: occurrence.endAt); _location = State(initialValue: occurrence.locationName); _capacity = State(initialValue: occurrence.capacity); _price = State(initialValue: occurrence.price); _capacityPolicy = State(initialValue: occurrence.capacityPolicy) }
    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(intensity: 0.65)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("هذا الموعد فقط").font(TamrinFont.font(size: 36, weight: .bold))
                            Text("التغييرات هنا لن تؤثر على بقية الخطة.").foregroundStyle(.secondary)
                        }
                        VStack(spacing: 0) {
                            DatePicker("البداية", selection: $start).padding(16)
                            Divider().padding(.leading, 16)
                            DatePicker("النهاية", selection: $end).padding(16)
                        }.background(TamrinTheme.glass, in: .rect(cornerRadius: 24))
                        VStack(spacing: 0) {
                            HStack { Image(systemName: "mappin.and.ellipse"); TextField("اسم الملعب", text: $location) }.padding(16)
                            Divider().padding(.leading, 16)
                            Stepper("الحد الأقصى: \(capacity)", value: $capacity, in: 2...50).padding(16)
                            Divider().padding(.leading, 16)
                            Picker("بعد اكتمال العدد", selection: $capacityPolicy) {
                                Text("قائمة انتظار").tag(CapacityPolicy.waitlist)
                                Text("إغلاق التسجيل").tag(CapacityPolicy.closed)
                            }.pickerStyle(.segmented).padding(12)
                            Divider().padding(.leading, 16)
                            HStack { Text("القَطّة"); Spacer(); TextField("0", value: $price, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90); Text("ر.س").foregroundStyle(.secondary) }.padding(16)
                        }.background(TamrinTheme.glass, in: .rect(cornerRadius: 24))
                        Button("حفظ التعديل") { store.update(occurrence, startAt: start, endAt: end, location: location, capacity: capacity, price: price, capacityPolicy: capacityPolicy); dismiss() }
                            .buttonStyle(PrimaryActionStyle())
                    }.padding(22)
                }
            }
            .navigationTitle("تعديل الموعد").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

struct CancelOccurrenceSheet: View {
    @Bindable var store: TamrinStore
    let occurrence: Occurrence
    @Environment(\.dismiss) private var dismiss
    @State private var selection = ""
    @State private var customReason = ""
    @State private var confirm = false
    private let reasons = ["الجو ما يساعد", "الملعب غير متاح", "العدد ما اكتمل", "ظرف طارئ", "سبب ثاني"]

    private var finalReason: String { selection == "سبب ثاني" ? customReason.trimmingCharacters(in: .whitespacesAndNewlines) : selection }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("ليش بنلغي هالأسبوع؟").font(TamrinFont.font(size: 28, weight: .bold))
                Text("بنرسل السبب للأعضاء إذا كان التمرين مرسل.").font(.subheadline).foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    ForEach(reasons, id: \.self) { reason in
                        Button { selection = reason; UISelectionFeedbackGenerator().selectionChanged() } label: {
                            HStack { Text(reason); Spacer(); Image(systemName: selection == reason ? "checkmark.circle.fill" : "circle") }
                                .font(TamrinFont.font(size: 15, weight: .medium)).foregroundStyle(.primary)
                                .padding(.horizontal, 18).frame(height: 54)
                                .background(selection == reason ? TamrinTheme.lime.opacity(0.3) : TamrinTheme.secondary, in: .capsule)
                        }.buttonStyle(.plain)
                    }
                }
                if selection == "سبب ثاني" {
                    TextField("اكتب السبب باختصار", text: $customReason)
                        .padding(.horizontal, 18).frame(height: 56)
                        .background(TamrinTheme.secondary, in: .capsule)
                }
                Spacer()
                Button("إلغاء تمرين هالأسبوع", role: .destructive) { confirm = true }
                    .buttonStyle(PrimaryActionStyle()).disabled(finalReason.isEmpty)
            }
            .padding(22)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("رجوع") { dismiss() } } }
            .alert("متأكد من الإلغاء؟", isPresented: $confirm) {
                Button("إلغاء التمرين", role: .destructive) { store.cancel(occurrence, reason: finalReason); dismiss() }
                Button("تراجع", role: .cancel) {}
            } message: { Text(finalReason) }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}

private struct RegistrationCancellationSheet: View {
    @Bindable var store: TamrinStore
    let occurrence: Occurrence
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("متأكد إنك بتعتذر؟")
                .font(TamrinFont.font(size: 26, weight: .bold))
            Text("بنحرر مكانك لواحد من الربع. ما راح يتغير شيء إلا بعد ما تسحب للتأكيد.")
                .font(TamrinFont.font(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            SlideToConfirmButton(title: "اسحب لتأكيد الاعتذار") {
                store.cancelRegistration(for: occurrence)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            }

            Button("خلاص، بكمل") { dismiss() }
                .font(TamrinFont.font(size: 15, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 44)
        }
        .padding(22)
        .presentationDetents([.height(310)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

private struct SlideToConfirmButton: View {
    let title: String
    let confirm: () -> Void
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let knob: CGFloat = 54
            let travel = max(proxy.size.width - knob - 8, 1)

            // `leading` is the physical right edge in the app's RTL environment.
            ZStack(alignment: .leading) {
                Capsule().fill(Color.red.opacity(0.16))
                Text(title)
                    .font(TamrinFont.font(size: 14, weight: .bold))
                    .foregroundStyle(.red.opacity(0.92 - Double(progress) * 0.65))
                    .frame(maxWidth: .infinity)

                Circle()
                    .fill(.red)
                    .frame(width: knob, height: knob)
                    .overlay(Image(systemName: progress > 0.78 ? "checkmark" : "chevron.left.2").font(.system(size: 16, weight: .bold)).foregroundStyle(.white))
                    .padding(4)
                    .offset(x: travel * progress)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in progress = min(max(-value.translation.width / travel, 0), 1) }
                            .onEnded { _ in
                                if progress > 0.82 { confirm() }
                                else { withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { progress = 0 } }
                            }
                    )
            }
            .contentShape(.capsule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityHint("اسحب من اليمين إلى اليسار")
            .accessibilityAction { confirm() }
        }
        .frame(height: 62)
    }
}
