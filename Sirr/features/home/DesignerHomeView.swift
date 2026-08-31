import SwiftUI
import Combine
import UIKit

private enum HomeQuickAddDestination {
    case createTeam
    case joinTeam
}

/// Home: one stack of every exercise this person is part of — the ones they run
/// and the ones they only play in — nearest date at the top, each card a screen
/// tall so the edge of the next one shows beneath it and says the stack goes on.
///
/// There is no group drawer. A person thinks in exercises, not in the groups
/// that hold them, and having to remember which group Thursday's game lived in
/// before you could see it was a wall in front of the only thing Home is for.
struct DesignerHomeView: View {
    private enum EventActionInFlight {
        case skipping
    }

    let appState: AppState
    @State private var feed: HomeStore
    @State private var booted = false
    /// The rating feature's introduction, shown once — on the first Home load
    /// after the update that brought it, not on the first tap of a rate button.
    /// It announces something new, and an announcement waits for nobody to go
    /// looking for it.
    @State private var showRatingOnboarding = false
    @State private var scrolledID: UUID?
    /// `scrolledID` follows the live scroll target. The heavier group state
    /// (header team and store focus) follows this settled value only after
    /// native deceleration has finished, so it cannot steal frames from the
    /// gesture itself. The visual backdrop deliberately stays live.
    @State private var settledID: UUID?
    @State private var shelfScrollPhase: ScrollPhase = .idle
    /// The archive keeps its own position and backdrop. Reusing the upcoming
    /// card id here made switching tabs forget where both pages had been.
    @State private var activePastMonth: PastEventsArchiveMonth?
    @State private var selected: FeedOccurrence?
    @State private var registrationEntryEventID: UUID?
    @Namespace private var cardZoom

    @State private var showPlanDetails = false
    @State private var showProfile = false
    @State private var showCreateTeam = false
    @State private var showQuickAdd = false
    @State private var pendingQuickAddDestination: HomeQuickAddDestination?
    @State private var showJoinTeam = false
    @State private var declineOccurrence: FeedOccurrence?
    @State private var skipOccurrence: FeedOccurrence?
    @State private var editingOccurrence: FeedOccurrence?
    @State private var eventActionsInFlight: [UUID: EventActionInFlight] = [:]
    @State private var actionToast: String?
    @State private var actionError: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(appState: AppState, feed: HomeStore? = nil) {
        self.appState = appState
        _feed = State(initialValue: feed ?? HomeStore())
    }

    /// Which half of the calendar Home is showing. The title is the control:
    /// it names what is on the shelf and swaps it.
    @State private var showsPast = false

    private var sectionTitle: String { showsPast ? "الماضية" : "القادمة" }

    /// Every exercise this person is part of, whichever group runs it — the
    /// shelf Home scrolls through.
    ///
    /// Upcoming runs nearest-first, so the next thing to turn up to is on top.
    /// Past runs the other way, most recent first, for the same reason: the
    /// end of the list a person wants is the end nearest today, and that is a
    /// different end for each half.
    private var upcomingShelf: [FeedOccurrence] {
        let now = Date.now
        return feed.allOccurrences.filter {
            !$0.isPast(relativeTo: now) || $0.requiresPaymentAction
        }
    }

    private var pastShelf: [FeedOccurrence] {
        feed.allPastOccurrences.filter { !$0.requiresPaymentAction }
    }

    private var upcomingArtworkNames: [String] {
        upcomingShelf.map { art(for: $0) }
    }

    private var shelf: [FeedOccurrence] {
        showsPast ? pastShelf : upcomingShelf
    }

    /// Reload history when the person opens it or when the active workspace
    /// set changes while it is already open (for example after joining a team).
    private var pastLoadKey: String {
        guard showsPast else { return "upcoming" }
        let teamIDs = feed.teams.map(\.id.uuidString).sorted().joined(separator: ",")
        return "past:\(teamIDs)"
    }

    private var currentIndex: Int {
        guard let id = settledID ?? scrolledID,
              let idx = upcomingShelf.firstIndex(where: { $0.id == id }) else { return 0 }
        return idx
    }

    /// Opacity is purely visual and must answer the native snap target as soon
    /// as it changes. Store/team work still uses `currentIndex` and waits for
    /// idle, but waiting for idle here left the newly centred card translucent
    /// throughout long deceleration.
    private var visualCurrentIndex: Int {
        guard let id = scrolledID ?? settledID,
              let idx = upcomingShelf.firstIndex(where: { $0.id == id }) else { return 0 }
        return idx
    }

    /// The card in front of the person. Every group-scoped affordance — the
    /// header's group pill, the actions on the card — reads from this one.
    private var currentOccurrence: FeedOccurrence? {
        if showsPast { return pastBackdropOccurrence }
        return upcomingShelf.indices.contains(currentIndex) ? upcomingShelf[currentIndex] : nil
    }

    private func artName(_ index: Int) -> String { "ExerciseArt\((index % 3) + 1)" }

    /// The photo an exercise wears: one from its sport's folder when that
    /// folder has any, and otherwise the artwork the app ships with. The sport
    /// is the group's, since that is where it is chosen.
    private func art(for occurrence: FeedOccurrence) -> String {
        let sportKey = feed.team(for: occurrence)?.sport
        return SportArtLibrary.photo(for: occurrence.id, sportKey: sportKey)
            ?? artName(occurrence.artIndex)
    }

    /// The gap between one card and the next one down. Must stay under
    /// `posterBottomClearance`: the clearance is all the room there is beneath
    /// a resting card, so a gap at or past it puts the next card's top edge
    /// below the fold and the stack reads as one card on an empty page.
    /// The difference between the two is what actually peeks.
    private static let shelfSpacing: CGFloat = 80
    /// Every poster ends on the same horizontal line, regardless of whether
    /// the one- or two-line section title is above it. The clearance has to
    /// grow with the spacing above, or widening the gap just eats the peek.
    private static let posterBottomClearance: CGFloat = 96
    /// The shelf is fully hidden beneath the status/header chrome, then fades
    /// back in through the bottom of this region. What shows through is the
    /// page's already-blurred copy of the same poster, so the result reads as a
    /// progressive blur without doing live blur work while the person scrolls.
    private static let headerScrimDepth: CGFloat = 176

    /// Keep the expensive group state settled, but let the backdrop follow the
    /// live scroll target. In the reference it starts cross-fading while the
    /// next card is still moving into place rather than after snapping ends.
    private var backdropOccurrence: FeedOccurrence? {
        if showsPast { return pastBackdropOccurrence }
        guard let id = scrolledID ?? settledID else { return upcomingShelf.first }
        return upcomingShelf.first(where: { $0.id == id }) ?? upcomingShelf.first
    }

    /// A month owns one backdrop: the artwork of its newest exercise. The
    /// archive reports that representative only when the new month becomes
    /// substantially visible, so the colour does not flutter between cards.
    private var pastBackdropOccurrence: FeedOccurrence? {
        if let id = activePastMonth?.representativeOccurrenceID,
           let occurrence = pastShelf.first(where: { $0.id == id }) {
            return occurrence
        }
        return pastShelf.first
    }

    /// `artIndex` belongs to the event itself, not its position in the shelf.
    private var currentArtName: String {
        if showsPast {
            if let artName = activePastMonth?.artName { return artName }
            return pastShelf.first.map { art(for: $0) } ?? artName(0)
        }
        guard let occurrence = backdropOccurrence else { return artName(0) }
        return art(for: occurrence)
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
                mainContent
                    .environment(\.layoutDirection, .rightToLeft)
            }
        }
        .preferredColorScheme(.dark)
        // Presented from out here, not from inside the NavigationStack. Three
        // `fullScreenCover`s stacked on the same view is one more than SwiftUI
        // reliably honours — the third simply never opened.
        .fullScreenCover(isPresented: $showRatingOnboarding) {
            RatingOnboardingSheet {
                showRatingOnboarding = false
                // Now, with the page out of the way — the ask it was holding
                // back still has to happen.
                Task { await requestPushAuthorization() }
            }
        }
        .task {
            guard !booted else { return }
            feed.onSelectWorkspace = { appState.currentWorkspaceId = $0 }
            feed.onLogout = { Task { await appState.authVM.logout() } }
            feed.onDeleteAccount = { try await appState.authVM.deleteAccount() }
            await feed.bootstrap(initialWorkspaceID: appState.currentWorkspaceId)
            booted = true
            // After the shelf is up, so it opens over Home rather than over a
            // loading screen — and only where there is a group to rate anyone
            // in, which is not the case on a fresh signup.
            let introducesRating = !RatingOnboarding.hasSeen && !feed.teams.isEmpty
            if introducesRating { showRatingOnboarding = true }
            await openDeepLinkedEventIfNeeded()
            // The system's notification prompt waits for the introduction to
            // finish. Both want the screen at the same moment on the launch
            // after an update, and the prompt is the one that wins — it lands
            // on top of the page the person is still reading, and it is the
            // question they are least prepared to answer there.
            if !introducesRating {
                await requestPushAuthorization()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning from background: re-sync so changes made elsewhere
            // (new sessions, registrations) show up without a manual pull.
            if phase == .active, booted {
                Task {
                    await feed.refresh()
                    if showsPast {
                        await feed.loadPastOccurrencesIfNeeded(force: true)
                    }
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

    private var mainContent: some View {
        ZStack {
            TamrinTheme.page.ignoresSafeArea()

            // NavigationStack re-establishes a real safe area inside the
            // ignoresSafeArea drawer container (matches the designer's HomeView):
            // the safeAreaInset header clears the status bar, its buttons stay
            // tappable, and the page backdrop fills the system-space strips.
            NavigationStack {
                ZStack(alignment: .topTrailing) {
                    HomeArtBackdrop(artName: currentArtName, hasArt: !shelf.isEmpty)

                    Group {
                        if showsPast {
                            pastArchiveContent
                        } else if upcomingShelf.isEmpty {
                            GeometryReader { contentProxy in
                                EmptyScheduleCard(
                                    profileName: feed.profileName,
                                    profileImageData: feed.avatarData,
                                    profileImageUrl: feed.avatarUrl,
                                    showsSupervisorTag: feed.isCurrentTeamOwner
                                )
                                    .frame(height: max(contentProxy.size.height - Self.posterBottomClearance, 320))
                                    .padding(.horizontal, 20)
                                    .frame(
                                        maxWidth: .infinity,
                                        maxHeight: .infinity,
                                        alignment: .top
                                    )
                            }
                        } else {
                            GeometryReader { contentProxy in
                                let activeIndex = visualCurrentIndex
                                let indexedOccurrences = Array(upcomingShelf.enumerated())

                                ScrollView(.vertical, showsIndicators: false) {
                                    LazyVStack(spacing: Self.shelfSpacing) {
                                        ForEach(indexedOccurrences, id: \.element.id) { index, occurrence in
                                            let isBelowActiveCard = index > activeIndex

                                            EventPosterCard(
                                                occurrence: occurrence,
                                                registeredCount: feed.registeredCount(for: occurrence),
                                                showsSupervisorTag: feed.isOwner(of: occurrence),
                                                profileName: feed.profileName,
                                                profileImageData: feed.avatarData,
                                                profileImageUrl: feed.avatarUrl,
                                                attendees: feed.roster(for: occurrence)
                                                    .filter { $0.status != .waitlisted },
                                                currentUserID: feed.currentUserID,
                                                actions: cardActions(for: occurrence),
                                                art: art(for: occurrence)
                                            ) {
                                                Haptics.impact(.light)
                                                registrationEntryEventID = nil
                                                feed.focusTeam(for: occurrence)
                                                selected = occurrence
                                            }
                                            // Shorter than the screen on
                                            // purpose: what is left over below
                                            // is the next card's edge, which is
                                            // the only thing that says the
                                            // stack goes on.
                                            .containerRelativeFrame(.vertical, alignment: .top) { length, _ in
                                                max(length - Self.posterBottomClearance, 320)
                                            }
                                            // Only future cards beneath the
                                            // live snap target are translucent.
                                            // `scrolledID` changes by identity,
                                            // not on every geometry frame, so
                                            // this responds immediately while
                                            // staying on the compositor path.
                                            .opacity(isBelowActiveCard ? 0.5 : 1)
                                            .animation(
                                                reduceMotion ? nil : .easeOut(duration: 0.14),
                                                value: isBelowActiveCard
                                            )
                                            .matchedTransitionSource(id: occurrence.id, in: cardZoom)
                                        }
                                    }
                                    .scrollTargetLayout()
                                    .padding(.horizontal, 20)
                                    // The first card rests with the bottom
                                    // clearance showing beneath it. Without the
                                    // same amount at the end, the scroll runs
                                    // out exactly that much short of the last
                                    // card's snap point and can never reach it.
                                    .padding(.bottom, Self.posterBottomClearance)
                                }
                                .scrollTargetBehavior(
                                    .viewAligned(limitBehavior: .alwaysByOne)
                                )
                                .scrollPosition(id: $scrolledID)
                                .onScrollPhaseChange { _, phase in
                                    shelfScrollPhase = phase
                                    if phase == .idle { settleVisibleOccurrence() }
                                }
                                .onChange(of: scrolledID) { _, _ in
                                    // Depending on the release velocity, the
                                    // final target can publish just before or
                                    // just after the phase becomes idle. This
                                    // covers both orders without a delayed Task.
                                    if shelfScrollPhase == .idle {
                                        settleVisibleOccurrence()
                                    }
                                }
                                .refreshable { await feed.refresh() }
                            }
                        }
                    }
                    // Let the photographic page backdrop show through wherever
                    // a card travels behind the header, then return the sharp
                    // card progressively near the header's lower edge. This is
                    // a fixed alpha mask, not a live full-screen blur.
                    .mask {
                        if shelf.isEmpty {
                            Rectangle().fill(.white)
                        } else {
                            ShelfHeaderRevealMask(depth: Self.headerScrimDepth)
                        }
                    }
                    // Over the shelf but under the header, and after the
                    // header reveal: the hint stays crisp rather than entering
                    // the progressive mask with the posters.
                    .overlay(alignment: .bottom) {
                        if !showsPast, upcomingShelf.count > 1, currentIndex == 0 {
                            ScrollHintChevron()
                                .padding(.bottom, 2)
                                .transition(.opacity)
                        }
                    }
                    // Keyed on which half is showing, so switching replaces
                    // the shelf rather than editing it in place — which is what
                    // lets it cross over as one thing instead of the cards
                    // reshuffling one by one.
                    //
                    // A plain cross-fade, not the blur the title uses: the blur
                    // belongs to the control the person pressed, and running it
                    // across a full-screen photograph as well made the whole
                    // page look like it was struggling rather than answering.
                    .id(showsPast)
                    .transition(.opacity)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        StickyHomeHeader(
                            team: currentOccurrence.flatMap { feed.team(for: $0) },
                            profileName: feed.profileName,
                            profileImageData: feed.avatarData,
                            profileImageUrl: feed.avatarUrl,
                            isOnArtwork: true,
                            sectionTitle: sectionTitle,
                            openAdd: {
                                Haptics.impact(.light)
                                showQuickAdd = true
                            },
                            openPlan: {
                                Haptics.impact(.light)
                                if !showsPast {
                                    // The archive view is rebuilt at its top
                                    // when returning to it, so its backdrop
                                    // must start from the first month as well.
                                    activePastMonth = nil
                                }
                                // Slow on purpose. The whole page changes
                                // underneath, and at a normal duration the
                                // blur reads as a stutter rather than as one
                                // set of cards giving way to another.
                                withAnimation(.smooth(duration: 0.55)) {
                                    showsPast.toggle()
                                }
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
                        artName: art(for: occ),
                        initiallyShowsRegistration: registrationEntryEventID == occ.id
                    )
                        .navigationTransition(.zoom(sourceID: occ.id, in: cardZoom))
                }
                .onChange(of: selected?.id) { _, newValue in
                    if newValue == nil { registrationEntryEventID = nil }
                }
                // Decode the small palette samples immediately, then prepare
                // the display-sized photos away from the main actor. LazyVStack
                // can otherwise encounter a PNG for the first time while the
                // person's finger is moving and synchronously decode it there.
                .task(id: upcomingArtworkNames) {
                    let artwork = upcomingArtworkNames
                    ArtworkPalette.warm(artwork)
                    let worker = Task.detached(priority: .userInitiated) {
                        SportArtLibrary.warmDisplayImages(artwork)
                        SportArtLibrary.warmBackdropImages(artwork)
                    }
                    await withTaskCancellationHandler(
                        operation: { await worker.value },
                        onCancel: { worker.cancel() }
                    )
                }
                // History is deliberately lazy. Opening Home should prepare
                // only the next exercises; the bounded archive request starts
                // when the person actually asks for «الماضية».
                .task(id: pastLoadKey) {
                    guard showsPast else { return }
                    await feed.loadPastOccurrencesIfNeeded()
                }
                .onChange(of: upcomingShelf.map(\.id), initial: true) { _, ids in
                    guard let first = upcomingShelf.first else {
                        scrolledID = nil
                        settledID = nil
                        return
                    }
                    if settledID == nil {
                        scrolledID = first.id
                        settledID = first.id
                        feed.focusTeam(for: first)
                        return
                    }
                    if let settledID, ids.contains(settledID) {
                        if scrolledID.map({ ids.contains($0) }) != true {
                            scrolledID = settledID
                        }
                        return
                    }
                    if let scrolledID, ids.contains(scrolledID) {
                        self.settledID = scrolledID
                        if let occurrence = upcomingShelf.first(where: { $0.id == scrolledID }) {
                            feed.focusTeam(for: occurrence)
                        }
                        return
                    }
                    scrolledID = first.id
                    settledID = first.id
                    feed.focusTeam(for: first)
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

            // This must live outside NavigationStack: an overlay inside it is
            // proposed only the navigation safe region and stops above the
            // home indicator. At the page root the same ramp reaches the
            // physical screen edge with no horizontal seam.
            if !showsPast, !shelf.isEmpty {
                ShelfBottomScrim(depth: Self.posterBottomClearance)
            }
        }
    }

    @ViewBuilder
    private var pastArchiveContent: some View {
        if pastShelf.isEmpty,
           feed.isLoadingPastOccurrences || !feed.hasLoadedPastOccurrences,
           feed.pastOccurrencesError == nil {
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text("نحمّل تمارينك الماضية…")
                    .font(TamrinFont.font(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else if pastShelf.isEmpty, let message = feed.pastOccurrencesError {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                Text(message)
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .multilineTextAlignment(.center)
                Button("إعادة المحاولة") {
                    Task { await feed.loadPastOccurrencesIfNeeded(force: true) }
                }
                .font(TamrinFont.font(size: 14, weight: .bold))
                .buttonStyle(.glassProminent)
                .tint(.accentColor)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PastEventsArchiveView(
                occurrences: pastShelf,
                activeMonth: $activePastMonth,
                artResolver: art(for:),
                transitionNamespace: cardZoom,
                canLoadMore: feed.canLoadMorePastOccurrences,
                isLoadingMore: feed.isLoadingMorePastOccurrences,
                archiveError: feed.pastOccurrencesError,
                loadMoreError: feed.pastLoadMoreError,
                onRetryArchive: {
                    await feed.loadPastOccurrencesIfNeeded(force: true)
                },
                onLoadMore: {
                    await feed.loadMorePastOccurrences()
                },
                onOpen: { occurrence in
                    Haptics.impact(.light)
                    registrationEntryEventID = nil
                    feed.focusTeam(for: occurrence)
                    selected = occurrence
                }
            )
            .refreshable {
                await feed.loadPastOccurrencesIfNeeded(force: true)
            }
        }
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
                    feed.focusTeam(for: occurrence)
                    registrationEntryEventID = occurrence.id
                    selected = occurrence
                }
            ]
        }

        // A finished exercise is otherwise read-only. Its one exception is a
        // contribution this member still owes, and that exception must not
        // reopen decline, withdrawal, guest, or registration actions.
        if occurrence.requiresPaymentAction,
           occurrence.isPast(relativeTo: .now),
           !feed.isOwner(of: occurrence) {
            return [
                EventPosterCardAction(
                    id: "pay-overdue",
                    title: "دفع القطة",
                    systemImage: "banknote.fill",
                    kind: .primary
                ) {
                    feed.focusTeam(for: occurrence)
                    registrationEntryEventID = occurrence.id
                    selected = occurrence
                }
            ]
        }

        if feed.isOwner(of: occurrence) {
            let actionInFlight = eventActionsInFlight[occurrence.id]
            let actionsEnabled = actionInFlight == nil
            return [
                EventPosterCardAction(
                    id: "edit",
                    title: "تعديل",
                    systemImage: "pencil",
                    kind: .secondary,
                    isEnabled: actionsEnabled
                ) {
                    feed.focusTeam(for: occurrence)
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
                    feed.focusTeam(for: occurrence)
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
                feed.focusTeam(for: occurrence)
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
                feed.focusTeam(for: occurrence)
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
            feed.focusTeam(for: occurrence)
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

    /// Asked once, on first Home load — so it does not depend on completing a
    /// paid registration to ever be requested.
    private func requestPushAuthorization() async {
        await PushManager.shared.requestAuthorizationAndRegister()
    }

    private func settleVisibleOccurrence() {
        guard let scrolledID,
              settledID != scrolledID,
              let occurrence = upcomingShelf.first(where: { $0.id == scrolledID }) else { return }
        settledID = scrolledID
        feed.focusTeam(for: occurrence)
    }

}

/// A stationary opacity ramp on the shelf. Its transparent part reveals the
/// exact pre-blurred poster already painted by `HomeArtBackdrop`; blending that
/// with the sharp moving card creates the requested progressive-blur feeling
/// without a Material layer or a blur recomputed every scroll frame.
private struct ShelfHeaderRevealMask: View {
    let depth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.40),
                    .init(color: .black.opacity(0.08), location: 0.58),
                    .init(color: .black.opacity(0.34), location: 0.74),
                    .init(color: .black.opacity(0.76), location: 0.88),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: depth)

            Color.black
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A very light dissolve at the bottom of the upcoming stack. Kept separate
/// from the header so it cannot darken the progressive reveal above.
private struct ShelfBottomScrim: View {
    let depth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: depth)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Anchor the ramp to the physical bottom edge, not the top of the home
        // indicator's safe area. This removes the horizontal seam and carries
        // the shadow continuously beneath the indicator.
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One already-soft bitmap, scaled across the page and swapped only when the
/// card (or active archive month) changes. The expensive blur is prepared once
/// in `SportArtLibrary`, so the transition itself is just two ordinary texture
/// opacities and stays smooth even during a fast scroll.
private struct HomeBackdropArtwork: View {
    /// UIKit images are immutable for our use after construction. The wrapper
    /// makes that explicit at the concurrency boundary without claiming every
    /// UIImage in the app is generally Sendable.
    private struct PreparedArtwork: @unchecked Sendable {
        let image: UIImage
    }

    private struct RenderedArtwork {
        let name: String
        let image: UIImage
    }

    let artName: String

    @State private var rendered: RenderedArtwork?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let rendered {
                    Image(uiImage: rendered.image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .id(rendered.name)
                        .transition(
                            .asymmetric(insertion: .opacity, removal: .identity)
                        )
                }
            }
        }
        .task(id: artName) {
            let requestedName = artName
            let worker = Task.detached(priority: .userInitiated) { () -> PreparedArtwork? in
                guard let image = SportArtLibrary.backdropImage(named: requestedName) else {
                    return nil
                }
                return PreparedArtwork(image: image)
            }
            let prepared = await withTaskCancellationHandler(
                operation: { await worker.value },
                onCancel: { worker.cancel() }
            )
            guard !Task.isCancelled, let prepared else { return }

            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) {
                rendered = RenderedArtwork(name: requestedName, image: prepared.image)
            }
        }
    }
}

struct HomeArtBackdrop: View {
    let artName: String
    let hasArt: Bool

    var body: some View {
        ZStack {
            if hasArt {
                Color(white: 0.145)
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.18, blue: 0.19),
                        Color(red: 0.12, green: 0.14, blue: 0.16),
                        Color(red: 0.27, green: 0.23, blue: 0.15)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            if hasArt {
                HomeBackdropArtwork(artName: artName)

                // Just enough separation for white chrome and card edges. The
                // photograph — not its average colour — remains the background.
                Color.black.opacity(0.42)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The one thing that says the shelf goes on when a card fills the screen.
///
/// Shown only on the first card: after that the person has already scrolled
/// once and knows, and a hint that stays is decoration.
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
    let sectionTitle: String
    let openAdd: () -> Void
    let openPlan: () -> Void
    let openProfile: () -> Void

    var body: some View {
        HomeTopBar(
            team: team,
            profileName: profileName,
            profileImageData: profileImageData,
            profileImageUrl: profileImageUrl,
            isOnArtwork: isOnArtwork,
            sectionTitle: sectionTitle,
            openAdd: openAdd,
            openPlan: openPlan,
            openProfile: openProfile
        )
        // These are semantic edges in the surrounding RTL environment:
        // leading is the physical right, trailing the physical left.
        .padding(.leading, 30)
        .padding(.trailing, 24)
        // Padding, not an offset: an offset moves the header without
        // growing the safe-area inset it reserves, so the 10pt it dropped
        // came straight out of the card's top edge.
        .padding(.top, 18)
        // This is the gap between the buttons and the top of the card: the
        // inset the header reserves ends here and the shelf starts.
        .padding(.bottom, 46)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.colorScheme, .dark)
    }
}

private struct HomeTopBar: View {
    let team: FeedTeam?
    let profileName: String
    var profileImageData: Data?
    var profileImageUrl: String?
    let isOnArtwork: Bool
    let sectionTitle: String
    let openAdd: () -> Void
    let openPlan: () -> Void
    let openProfile: () -> Void

    /// One size for both controls, so they read as a pair.
    private static let controlDiameter: CGFloat = 52

    var body: some View {
        // A physical LTR row keeps the avatar and add control on the left and
        // the Arabic section title on the right, exactly as in the reference.
        // Both controls are `controlDiameter` across.
        HStack(alignment: .center, spacing: 14) {
            Button(action: openProfile) {
                Group {
                    if profileImageData != nil || profileImageUrl != nil {
                        MemberAvatar(
                            name: profileName,
                            size: Self.controlDiameter,
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
                            .frame(width: Self.controlDiameter, height: Self.controlDiameter)
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

            // The system's own glass, not a tinted disc with a hairline drawn
            // round it: it picks up what is behind it, and `interactive` gives
            // it the platform's press response rather than a spring of ours.
            //
            // The material applied to a fixed frame, not `buttonStyle(.glass)`:
            // that style pads its own label, so the control came out 57pt
            // against the avatar's 44 and the two stopped reading as a pair.
            Button(action: openAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: Self.controlDiameter, height: Self.controlDiameter)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("إضافة تمرين")

            Spacer(minLength: 12)

            Button(action: openPlan) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.52))

                    Text(sectionTitle)
                        .font(TamrinFont.font(size: 34, weight: .bold))
                        .foregroundStyle(Color(white: 0.98))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        // Identified by its own text, so the two words are
                        // separate views and one can blur out while the other
                        // blurs in. Without the id SwiftUI edits the string in
                        // place and there is nothing to transition.
                        .id(sectionTitle)
                        .transition(.blurReplace)
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.layoutDirection, .rightToLeft)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sectionTitle)
            .accessibilityHint(
                sectionTitle == "القادمة"
                    ? "يعرض التمارين الماضية"
                    : "يعرض التمارين القادمة"
            )
        }
        .environment(\.layoutDirection, .leftToRight)
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: sectionTitle)
    }
}

/// The header's `+`: the two ways to end up with another exercise on the shelf.
/// Both are offered to everyone — this is about which exercises you are part
/// of, not about what you may do inside one, so it does not change with your
/// role.
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
