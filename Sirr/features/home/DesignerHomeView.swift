import SwiftUI
import Combine

private enum HomeQuickAddDestination {
    case createTeam
    case joinTeam
}

/// Reskinned Home feed (designer look) on mock data, with the ported side-menu
/// drawer (open via the header ☰ button or a right-edge swipe) and live team
/// switching. Deferred to later increments: real backend wiring and any
/// remaining secondary destinations.
struct DesignerHomeView: View {
    private enum EventActionInFlight {
        case publishing
        case skipping
    }

    let appState: AppState
    @State private var feed: HomeStore
    @State private var booted = false
    @State private var scrolledID: UUID?
    @State private var selected: FeedOccurrence?
    @State private var registrationEntryEventID: UUID?
    @Namespace private var cardZoom

    @State private var isMenuOpen = false
    @State private var menuDragProgress: CGFloat = 0
    @State private var isMenuGestureActive = false
    /// A horizontal pan's release must not read as a card tap: the poster card
    /// fills the screen, so a drawer swipe never leaves the button's bounds and
    /// would otherwise still fire it. Tracked here — not on the card — because
    /// a DragGesture attached to scroll content blocks the ScrollView's pan,
    /// while this root-level gesture observes without blocking.
    @State private var sawHorizontalPan = false
    @State private var didMenuHaptic = false
    @State private var showPlanDetails = false
    @State private var showProfile = false
    @State private var showAppSettings = false
    @State private var showCreateTeam = false
    @State private var showQuickAdd = false
    @State private var pendingQuickAddDestination: HomeQuickAddDestination?
    @State private var showJoinTeam = false
    @State private var publishConfirmation: FeedOccurrence?
    @State private var declineOccurrence: FeedOccurrence?
    @State private var skipOccurrence: FeedOccurrence?
    @State private var editingOccurrence: FeedOccurrence?
    @State private var eventActionsInFlight: [UUID: EventActionInFlight] = [:]
    @State private var actionToast: String?
    @State private var actionError: String?
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

    /// The blurred backdrop has to be the artwork of the card in front of it.
    /// `artIndex` is derived from the event's own id, not from its place in the
    /// feed, so feeding the backdrop the scroll position painted it with a
    /// different picture than the card was showing.
    private var currentArtName: String {
        guard feed.occurrences.indices.contains(currentIndex) else { return artName(0) }
        return artName(feed.occurrences[currentIndex].artIndex)
    }

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
            feed.onDeleteAccount = { try await appState.authVM.deleteAccount() }
            await feed.bootstrap(initialWorkspaceID: appState.currentWorkspaceId)
            booted = true
            await openDeepLinkedEventIfNeeded()
            // Ask for notifications once, on first Home load — so it doesn't
            // depend on completing a paid registration to ever be requested.
            await PushManager.shared.requestAuthorizationAndRegister()
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning from background: re-sync so changes made elsewhere
            // (new sessions, registrations) show up without a manual pull.
            if phase == .active, booted {
                Task {
                    await feed.refresh()
                    await openDeepLinkedEventIfNeeded()
                }
            }
        }
        .onReceive(appState.$deepLinkEventId.compactMap { $0 }) { eventID in
            guard booted else { return }
            Task { await openDeepLinkedEventIfNeeded(eventID) }
        }
        .onReceive(appState.$currentWorkspaceId.compactMap { $0 }) { wsID in
            // Joining from an invite link happens outside the store — ContentView's
            // JoinWorkspaceView calls WorkspaceService directly — so the new
            // workspace only reaches the feed through AppState. Reload so it shows
            // up right away instead of on the next foreground.
            guard booted, wsID != feed.selectedTeamID else { return }
            Task { await feed.loadWorkspaces(preferred: wsID) }
        }
        .overlay(alignment: .top) {
            if let actionToast {
                Label(actionToast, systemImage: "checkmark.circle.fill")
                    .font(TamrinFont.font(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(TamrinTheme.floatingChrome.opacity(0.92), in: .capsule)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .alert("تعذر إكمال الإجراء", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("حسنًا", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
                .font(TamrinFont.body)
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
            let revealDistance = HomeDrawerMetrics.width(for: proxy.size.width)
            let progress = menuProgress()
            // A single, non-animated silhouette is used for the whole gesture.
            // `.concentric` (with no fixed minimum) inherits the container's
            // corner radius, which at the root is the device's own display
            // radius — so the drawer silhouette matches an iPhone 17 Pro, an
            // iPhone SE and everything between without hardcoding a number.
            // `isUniform` keeps all four corners identical while the page moves.
            let screenSilhouette = ConcentricRectangle(
                corners: .concentric,
                isUniform: true
            )

            // Keep the drawer mechanics in a physical left-to-right coordinate
            // space. The app content itself stays RTL, but this prevents SwiftUI
            // from mirroring the page translation on Arabic devices.
            ZStack(alignment: .leading) {
                TeamSideMenu(
                    feed: feed,
                    createTeam: {
                        setMenu(open: false)
                        showQuickAdd = true
                    },
                    openSettings: { setMenu(open: false); showProfile = true },
                    openAppSettings: { setMenu(open: false); showAppSettings = true },
                    onSelectTeam: { id in feed.selectTeam(id); setMenu(open: false) }
                )

                mainContent
                    .environment(\.layoutDirection, .rightToLeft)
                    .ignoresSafeArea()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background { TamrinTheme.page.ignoresSafeArea() }
                    .overlay {
                        Color.black
                            .opacity(0.62 * progress)
                            .contentShape(Rectangle())
                            .allowsHitTesting(progress > 0.02)
                            .onTapGesture { setMenu(open: false) }
                    }
                    // Clip from the first drag point with the same concentric
                    // iPhone silhouette used at the final drawer position.
                    .clipShape(screenSilhouette)
                    .shadow(
                        color: .black.opacity(0.25 * progress),
                        radius: 21 * progress,
                        x: 10 * progress,
                        y: 0
                    )
                    // Deliberately avoid scaling after clipping: scaling also
                    // scales the corner radius and caused the square-to-round
                    // transition during an interactive swipe.
                    // Gesture translations use the screen's physical x-axis:
                    // opening starts at the right edge and moves left, so the
                    // page follows the finger with a negative translation.
                    .offset(x: -revealDistance * progress)
            }
            .environment(\.layoutDirection, .leftToRight)
            .background(Color(red: 0.067, green: 0.067, blue: 0.067))
            .ignoresSafeArea()
            .simultaneousGesture(menuGesture(revealDistance: revealDistance))
        }
        .ignoresSafeArea()
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
                    HomeArtBackdrop(artName: currentArtName, hasArt: !feed.occurrences.isEmpty)

                    Group {
                        if feed.occurrences.isEmpty {
                            GeometryReader { contentProxy in
                                EmptyScheduleCard()
                                    .frame(height: max(contentProxy.size.height - 64, 320))
                                    .padding(.horizontal, 20)
                                    .frame(
                                        maxWidth: .infinity,
                                        maxHeight: .infinity,
                                        alignment: .top
                                    )
                            }
                        } else if feed.occurrences.count == 1,
                                  let occurrence = feed.occurrences.first {
                            GeometryReader { contentProxy in
                                EventPosterCard(
                                    occurrence: occurrence,
                                    registeredCount: feed.registeredCount(for: occurrence),
                                    publishTag: publishTag(for: occurrence),
                                    actions: cardActions(for: occurrence)
                                ) {
                                    guard !sawHorizontalPan else { return }
                                    Haptics.impact(.light)
                                    registrationEntryEventID = nil
                                    selected = occurrence
                                }
                                .frame(height: max(contentProxy.size.height - 64, 320))
                                .padding(.horizontal, 20)
                                .frame(
                                    maxWidth: .infinity,
                                    maxHeight: .infinity,
                                    alignment: .top
                                )
                                .matchedTransitionSource(id: occurrence.id, in: cardZoom)
                            }
                        } else {
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(spacing: 110) {
                                    ForEach(feed.occurrences.prefix(6)) { occurrence in
                                        EventPosterCard(
                                            occurrence: occurrence,
                                            registeredCount: feed.registeredCount(for: occurrence),
                                            publishTag: publishTag(for: occurrence),
                                            actions: cardActions(for: occurrence)
                                        ) {
                                            guard !sawHorizontalPan else { return }
                                            Haptics.impact(.light)
                                            registrationEntryEventID = nil
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
                                // Every card is container−64 tall, so the first
                                // one rests with 64 of page showing beneath it.
                                // Without the same 64 at the end, the scroll
                                // runs out exactly that much short of the last
                                // card's snap point: it could never reach the
                                // top, and stopped mid-way with the previous
                                // card still hanging above it.
                                .padding(.bottom, 64)
                            }
                            // .alwaysByOne, not .always: cards are container−64
                            // tall with 110 of spacing, so the next snap point
                            // sits 46pt beyond one container length — the most
                            // .always lets a swipe travel. Under .always every
                            // swipe was clamped short of the next card and
                            // sprang back, locking the stack on the first card.
                            .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
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
                            profileImageData: feed.avatarData,
                            profileImageUrl: feed.avatarUrl,
                            isOnArtwork: !feed.occurrences.isEmpty,
                            sectionTitle: feed.occurrences.isEmpty
                                ? nil
                                : (currentIndex == 0 ? "الموعد الجاي" : "المواعيد القادمة"),
                            openMenu: {
                                Haptics.impact(.light)
                                setMenu(open: true)
                            },
                            openPlan: {
                                Haptics.impact(.light)
                                showPlanDetails = true
                            },
                            openProfile: {
                                Haptics.impact(.light)
                                showProfile = true
                            }
                        )
                    }
                }
                .environment(\.layoutDirection, .rightToLeft)
                .toolbar(.hidden, for: .navigationBar)
                .fullScreenCover(item: $selected) { occ in
                    EventDetailView(
                        feed: feed,
                        occurrence: occ,
                        artName: artName(occ.artIndex),
                        initiallyShowsRegistration: registrationEntryEventID == occ.id
                    )
                        .navigationTransition(.zoom(sourceID: occ.id, in: cardZoom))
                }
                .onChange(of: selected?.id) { _, newValue in
                    if newValue == nil { registrationEntryEventID = nil }
                }
                .sheet(item: $declineOccurrence) { occurrence in
                    MemberDeclineSheet { reasonCode, reasonText in
                        try await requireSuccess(
                            feed.decline(
                                occurrence,
                                reasonCode: reasonCode,
                                reasonText: reasonText
                            )
                        )
                        showActionToast("سُجّل اعتذارك عن الموعد")
                    }
                }
                .sheet(item: $publishConfirmation) { occurrence in
                    AdminPublishEventSheet(
                        eventTitle: occurrence.title,
                        dayText: occurrence.startAt.arabicDay
                    ) {
                        try await performEventAction(.publishing, for: occurrence.id) {
                            await feed.publish(occurrence)
                        }
                        showActionToast("نُشر الموعد ووصل الأعضاء إشعار")
                    }
                }
                .sheet(item: $skipOccurrence) { occurrence in
                    AdminSkipEventSheet { reasonCode, reasonText in
                        try await performEventAction(.skipping, for: occurrence.id) {
                            await feed.skip(
                                occurrence,
                                reasonCode: reasonCode,
                                reasonText: reasonText
                            )
                        }
                        showActionToast("موعد هذا الأسبوع متخطّى، وأُبلغ الأعضاء")
                    }
                }
                .sheet(item: $editingOccurrence) { occurrence in
                    AddSessionSheet(
                        feed: feed,
                        isPresented: Binding(
                            get: { editingOccurrence != nil },
                            set: { if !$0 { editingOccurrence = nil } }
                        ),
                        editingEventID: occurrence.id,
                        editingTemplateID: occurrence.isRecurring ? occurrence.templateId : nil,
                        initialPlan: feed.editDraft(for: occurrence) ?? PlanDraft()
                    )
                }
                .navigationDestination(isPresented: $showPlanDetails) {
                    TeamDetailView(feed: feed)
                }
                .sheet(isPresented: $showProfile) {
                    ProfileSettingsView(feed: feed)
                }
                .sheet(isPresented: $showAppSettings) {
                    AppSettingsView(feed: feed)
                }
                .sheet(
                    isPresented: $showQuickAdd,
                    onDismiss: presentPendingQuickAddDestination
                ) {
                    HomeQuickAddSheet { destination in
                        pendingQuickAddDestination = destination
                        showQuickAdd = false
                    }
                }
                .sheet(isPresented: $showJoinTeam) {
                    JoinTeamView(feed: feed, isPresented: $showJoinTeam)
                }
                .fullScreenCover(isPresented: $showCreateTeam) {
                    CreateTeamFlow(feed: feed, isPresented: $showCreateTeam)
                }
            }
        }
    }

    /// Members only ever receive published events, and a skipped one has its
    /// own badge already — so the publish tag belongs to the organizer's
    /// upcoming cards alone.
    private func publishTag(for occurrence: FeedOccurrence) -> EventPosterPublishTag? {
        guard feed.isCurrentTeamOwner, !occurrence.isCancelled else { return nil }
        return occurrence.isPublished ? .published : .unpublished
    }

    private func cardActions(for occurrence: FeedOccurrence) -> [EventPosterCardAction] {
        if occurrence.isCancelled {
            return [
                EventPosterCardAction(
                    id: "cancelled",
                    title: occurrence.hasCancellationReason ? "معرفة سبب التخطي" : "الموعد متخطّى",
                    systemImage: occurrence.hasCancellationReason ? "info.circle.fill" : "forward.end.fill",
                    kind: occurrence.hasCancellationReason ? .secondary : .status,
                    isEnabled: occurrence.hasCancellationReason
                ) {
                    registrationEntryEventID = nil
                    selected = occurrence
                }
            ]
        }

        if feed.isCurrentTeamOwner {
            let actionInFlight = eventActionsInFlight[occurrence.id]
            let isPublishing = actionInFlight == .publishing
            let actionsEnabled = actionInFlight == nil
            return [
                EventPosterCardAction(
                    id: "send",
                    title: occurrence.isPublished ? "منشور" : "نشر الموعد",
                    systemImage: occurrence.isPublished ? "checkmark.circle.fill" : "paperplane.fill",
                    kind: occurrence.isPublished ? .status : .primary,
                    isEnabled: !occurrence.isPublished && actionsEnabled,
                    isLoading: isPublishing
                ) {
                    publishConfirmation = occurrence
                },
                EventPosterCardAction(
                    id: "edit",
                    title: "تعديل",
                    systemImage: "pencil",
                    kind: .secondary,
                    isEnabled: actionsEnabled
                ) {
                    guard feed.editDraft(for: occurrence) != nil else {
                        actionError = "تعذر تحميل بيانات هذا الموعد للتعديل. حدّث الصفحة وحاول مرة أخرى."
                        return
                    }
                    editingOccurrence = occurrence
                },
                EventPosterCardAction(
                    id: "skip",
                    title: "تخطي",
                    systemImage: "forward.end.fill",
                    kind: .destructive,
                    isEnabled: actionsEnabled
                ) {
                    skipOccurrence = occurrence
                }
            ]
        }

        let state = feed.participationState(for: occurrence)
        let primary: EventPosterCardAction
        switch state {
        case .available, .declined:
            primary = EventPosterCardAction(
                id: "register",
                title: "سجّل حضورك",
                systemImage: "checkmark.circle.fill",
                kind: .primary
            ) {
                registrationEntryEventID = occurrence.id
                selected = occurrence
            }
        case .full:
            primary = EventPosterCardAction(
                id: "full",
                title: "اكتمل العدد",
                systemImage: "person.2.slash",
                kind: .status,
                isEnabled: false,
                action: {}
            )
        case .registered:
            primary = EventPosterCardAction(
                id: "registered",
                title: "مسجّل",
                systemImage: "checkmark.circle.fill",
                kind: .status,
                isEnabled: false,
                action: {}
            )
        case .awaitingPayment:
            // The seat is held; the card's job is to get the share paid.
            primary = EventPosterCardAction(
                id: "pay",
                title: "دفع القطة",
                systemImage: "banknote.fill",
                kind: .primary
            ) {
                registrationEntryEventID = occurrence.id
                selected = occurrence
            }
        case .paymentPending:
            primary = EventPosterCardAction(
                id: "pending",
                title: "بانتظار التأكيد",
                systemImage: "clock.fill",
                kind: .status,
                isEnabled: false,
                action: {}
            )
        case .waitlisted:
            primary = EventPosterCardAction(
                id: "waitlisted",
                title: "قائمة الانتظار",
                systemImage: "hourglass",
                kind: .status,
                isEnabled: false,
                action: {}
            )
        case .cancelled:
            return []
        case .unavailable:
            primary = EventPosterCardAction(
                id: "unavailable",
                title: "تعذر التحقق",
                systemImage: "arrow.clockwise",
                kind: .status,
                isEnabled: false,
                action: {}
            )
        }

        let alreadyDeclined = state == .declined
        let decline = EventPosterCardAction(
            id: "decline",
            title: alreadyDeclined ? "معتذر" : "اعتذار",
            systemImage: alreadyDeclined ? "checkmark" : "xmark.circle.fill",
            kind: alreadyDeclined ? .status : .destructive,
            isEnabled: !alreadyDeclined
        ) {
            declineOccurrence = occurrence
        }
        return [primary, decline]
    }

    @MainActor
    private func performEventAction(
        _ action: EventActionInFlight,
        for eventID: UUID,
        operation: @MainActor () async -> HomeStore.RegistrationOutcome
    ) async throws {
        guard eventActionsInFlight[eventID] == nil else {
            throw NSError(
                domain: "DesignerHomeView.EventAction",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "يوجد إجراء جارٍ لهذا الموعد. انتظر لحظة وحاول مرة أخرى."]
            )
        }
        eventActionsInFlight[eventID] = action
        defer { eventActionsInFlight[eventID] = nil }
        try requireSuccess(await operation())
    }

    @MainActor
    private func requireSuccess(_ outcome: HomeStore.RegistrationOutcome) throws {
        if case .failure(let message) = outcome {
            throw NSError(
                domain: "DesignerHomeView.EventAction",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        Haptics.success()
    }

    private func showActionToast(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            actionToast = message
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard actionToast == message else { return }
            withAnimation(.easeOut(duration: 0.2)) { actionToast = nil }
        }
    }

    private func presentPendingQuickAddDestination() {
        guard let destination = pendingQuickAddDestination else { return }
        pendingQuickAddDestination = nil

        Task { @MainActor in
            await Task.yield()
            switch destination {
            case .createTeam:
                showCreateTeam = true
            case .joinTeam:
                showJoinTeam = true
            }
        }
    }

    private func openDeepLinkedEventIfNeeded(_ eventID: UUID? = nil) async {
        guard let eventID = eventID ?? appState.deepLinkEventId else { return }
        do {
            if let occurrence = try await feed.occurrenceForDeepLink(eventID: eventID) {
                registrationEntryEventID = nil
                selected = occurrence
                if appState.deepLinkEventId == eventID { appState.deepLinkEventId = nil }
            } else {
                actionError = "هذا الموعد غير متاح لك أو لم تعد عضوًا في تمرينه."
                if appState.deepLinkEventId == eventID { appState.deepLinkEventId = nil }
            }
        } catch {
            // Retain the pending ID after a transient network/server failure so
            // a later delivery or app re-entry can retry the same destination.
            actionError = "تعذر فتح الموعد الآن. تحقق من اتصالك وحاول مرة أخرى."
        }
    }

    private func menuProgress() -> CGFloat {
        let base: CGFloat = isMenuOpen ? 1 : 0
        return min(max(base + menuDragProgress, 0), 1)
    }

    private func setMenu(open: Bool) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88)) {
            isMenuOpen = open
            menuDragProgress = 0
        }
        isMenuGestureActive = false
        didMenuHaptic = false
    }

    private func menuGesture(revealDistance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                if !isMenuGestureActive {
                    let isHorizontal = abs(value.translation.width) > abs(value.translation.height) * 1.15
                    guard isHorizontal else { return }
                    // Suppress the card tap for this touch in both directions,
                    // even when the drawer below declines the swipe: a
                    // horizontal pan is never a tap.
                    sawHorizontalPan = true
                    // A horizontal pull anywhere on the page drives the drawer,
                    // not just a narrow edge strip: the card tap is suppressed
                    // via sawHorizontalPan as soon as the finger pans, so the
                    // two no longer compete for the same swipe. Vertical drags
                    // still belong to the card scroll.
                    //
                    // Direction decides intent — the drawer opens on a leftward
                    // pull and closes on the reverse, so a swipe the other way
                    // is left alone rather than armed and then clamped to a
                    // no-op.
                    let opens = value.translation.width < 0
                    guard isMenuOpen != opens else { return }
                    isMenuGestureActive = true
                }
                if isMenuOpen {
                    menuDragProgress = min(max(-value.translation.width / revealDistance, -1), 0)
                } else {
                    menuDragProgress = min(max(-value.translation.width / revealDistance, 0), 1)
                }
                if menuProgress() > 0.78, !didMenuHaptic {
                    Haptics.impact(.rigid, intensity: 0.65)
                    didMenuHaptic = true
                }
            }
            .onEnded { value in
                if sawHorizontalPan {
                    // The card's button action fires synchronously with this
                    // same touch-up; clearing a runloop turn later keeps that
                    // release suppressed without racing it.
                    DispatchQueue.main.async { sawHorizontalPan = false }
                }
                guard isMenuGestureActive else { return }
                isMenuGestureActive = false
                let predicted = isMenuOpen
                    ? 1 + min(max(-value.predictedEndTranslation.width / revealDistance, -1), 0)
                    : min(max(-value.predictedEndTranslation.width / revealDistance, 0), 1)
                setMenu(open: predicted > 0.5)
            }
    }
}

struct HomeArtBackdrop: View {
    let artName: String
    let hasArt: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if hasArt {
                Color(white: 0.145)
            } else {
                colorScheme == .dark
                    ? TamrinTheme.page
                    : Color(uiColor: .systemGroupedBackground)
            }
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
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 1.05).repeatForever(autoreverses: true),
                value: bounce
            )
            .onAppear { if !reduceMotion { bounce = true } }
            .accessibilityHidden(true)
    }
}

private struct StickyHomeHeader: View {
    let team: FeedTeam?
    let profileName: String
    var profileImageData: Data?
    var profileImageUrl: String?
    let isOnArtwork: Bool
    let sectionTitle: String?
    let openMenu: () -> Void
    let openPlan: () -> Void
    let openProfile: () -> Void
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassEffectContainer(spacing: 8) {
                HomeTopBar(team: team, profileName: profileName,
                           profileImageData: profileImageData,
                           profileImageUrl: profileImageUrl,
                           isOnArtwork: isOnArtwork,
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
        .environment(\.colorScheme, isOnArtwork ? .dark : systemColorScheme)
    }
}

private struct HomeTopBar: View {
    let team: FeedTeam?
    let profileName: String
    var profileImageData: Data?
    var profileImageUrl: String?
    let isOnArtwork: Bool
    let openMenu: () -> Void
    let openPlan: () -> Void
    let openProfile: () -> Void

    var body: some View {
        // The groups button and the group pill are one control pair, so they sit
        // close together; the profile button is pushed away by the spacer.
        HStack(spacing: 8) {
            Button(action: openMenu) {
                Label("التمارين", systemImage: "line.3.horizontal")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: TamrinControlMetrics.glassIconContent, height: TamrinControlMetrics.glassIconContent)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .accessibilityLabel("التمارين")

            Button(action: openPlan) {
                HStack(spacing: 9) {
                    Text(team?.name ?? "التمرين")
                        .font(TamrinFont.font(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.74)
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                // The `.glass` style already insets its label; anything beyond
                // a hairline here reads as a hugely over-padded pill.
                .padding(.horizontal, 2)
                .frame(height: TamrinControlMetrics.glassIconContent)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .accessibilityLabel("تفاصيل التمرين")

            Spacer(minLength: 0)

            Button(action: openProfile) {
                Group {
                    if profileImageData != nil || profileImageUrl != nil {
                        MemberAvatar(
                            name: profileName,
                            size: 44,
                            imageData: profileImageData,
                            imageUrl: profileImageUrl
                        )
                    } else {
                        Circle()
                            .fill(
                                isOnArtwork
                                    ? Color.white.opacity(0.92)
                                    : Color(uiColor: .secondarySystemBackground)
                            )
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
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("الملف الشخصي والإعدادات")
        }
    }
}

/// The drawer's `+`: the two ways to end up in another group. Both are offered
/// to everyone — this menu is about groups, not about what you may do inside
/// one, so it does not change with your role. Creating an exercise is an
/// organizer's action and lives on the home header instead.
private struct HomeQuickAddSheet: View {
    let onSelect: (HomeQuickAddDestination) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                optionCard(
                    title: "انضم إلى تمرين",
                    subtitle: "أدخل رمز الدعوة الذي وصلك من المشرف",
                    systemImage: "link",
                    isPrimary: true,
                    destination: .joinTeam
                )

                optionCard(
                    title: "تمرين جديد",
                    subtitle: "ابدأ تمرينًا مستقلًا وادعُ أعضاءه",
                    systemImage: "person.3.fill",
                    isPrimary: false,
                    destination: .createTeam
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
            // Measured before the expanding frame below, so the sheet's
            // detent follows the content rather than the NavigationStack.
            .sheetContentHeight()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("إضافة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء", role: .cancel) { dismiss() }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .fittedSheet(minHeight: 240, includesNavigationBar: true)
    }

    private func optionCard(
        title: String,
        subtitle: String,
        systemImage: String,
        isPrimary: Bool,
        destination: HomeQuickAddDestination
    ) -> some View {
        Button {
            Haptics.selection()
            onSelect(destination)
        } label: {
            HStack(spacing: 14) {
                // The app's accent is the system blue: the leading action is
                // a solid blue tile, the secondary one the same hue tinted back.
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isPrimary ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
                    .frame(width: 50, height: 50)
                    .background(
                        isPrimary ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.accentColor.opacity(0.14)),
                        in: .rect(cornerRadius: 16, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(TamrinFont.font(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(TamrinFont.font(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TamrinTheme.card, in: .rect(cornerRadius: 24, style: .continuous))
            .contentShape(.rect(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(SpringCardPressStyle())
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}

#Preview {
    DesignerHomeView(appState: AppState(), feed: .preview)
}
