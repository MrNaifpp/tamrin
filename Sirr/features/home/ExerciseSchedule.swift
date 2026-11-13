import SwiftUI
import Combine

struct ScheduleArtworkDeck {
    let sport: String
    var assignments: [UUID: String] = [:]
}

extension HomeStore {
    /// Dates belong to a workspace. An overdue contribution remains reachable
    /// inside that workspace even after its date moves into history.
    func scheduleOccurrences(for teamID: UUID, at now: Date = .now) -> [FeedOccurrence] {
        allOccurrences.filter {
            self.teamID(for: $0) == teamID
                && (!$0.isPast(relativeTo: now) || $0.requiresPaymentAction)
        }
    }

    func preferredScheduleOccurrence(for teamID: UUID, at now: Date = .now) -> FeedOccurrence? {
        let dates = scheduleOccurrences(for: teamID, at: now)
        let upcoming = dates.filter { !$0.isPast(relativeTo: now) && !$0.isCancelled }
        let registered = upcoming.first {
            switch participationState(for: $0) {
            case .registered, .awaitingPayment, .paymentPending: true
            default: false
            }
        }
        let available = upcoming.first {
            guard !$0.registrationLocked, $0.isPublished else { return false }
            if case .available = participationState(for: $0) { return true }
            return false
        }
        return registered ?? available ?? upcoming.first ?? dates.first
    }

    /// One representative per workspace, never one Home poster per date.
    func homeScheduleOccurrences(at now: Date = .now) -> [FeedOccurrence] {
        teams.compactMap { preferredScheduleOccurrence(for: $0.id, at: now) }
            .sorted {
                if $0.startAt != $1.startAt { return $0.startAt < $1.startAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    /// Existing dates keep their photo when a new, earlier date is added.
    /// Use each bundled background before cycling through the library again.
    func scheduleArt(for occurrence: FeedOccurrence) -> String {
        #if DEBUG
        if let pinned = HomeDebugMemberFixture.pinnedArt[occurrence.id] { return pinned }
        #endif
        guard let team = team(for: occurrence) else {
            return "ExerciseArt\((occurrence.artIndex % 3) + 1)"
        }
        var deck = scheduleArtworkDecks[team.id] ?? ScheduleArtworkDeck(sport: team.sport)
        if deck.sport != team.sport { deck = ScheduleArtworkDeck(sport: team.sport) }
        if let assigned = deck.assignments[occurrence.id] { return assigned }
        let dates = scheduleOccurrences(for: team.id)
        guard dates.contains(where: { $0.id == occurrence.id }) else {
            return SportArtLibrary.photo(for: occurrence.id, sportKey: team.sport)
                ?? "ExerciseArt\((occurrence.artIndex % 3) + 1)"
        }
        let photos = SportArtLibrary.photos(forSport: team.sport)
            + ["ExerciseArt1", "ExerciseArt2", "ExerciseArt3"]
        var used = Set(dates.compactMap { deck.assignments[$0.id] })
        for (index, date) in dates.enumerated() where deck.assignments[date.id] == nil {
            let photo = photos.first { !used.contains($0) } ?? photos[index % photos.count]
            deck.assignments[date.id] = photo
            used.insert(photo)
        }
        scheduleArtworkDecks[team.id] = deck
        return deck.assignments[occurrence.id] ?? photos[0]
    }
}

/// The detail keeps its own registration, roster and payment state. Only its
/// presentation (card versus expanded page) belongs to the workspace browser.
struct EventSchedulePresentation {
    let isExpanded: Bool
    let allowsContentScrolling: Bool
    let artworkSize: CGSize
    let topInset: CGFloat
    let bottomInset: CGFloat
    let expand: () -> Void
    let collapse: () -> Void
    let back: () -> Void
    let setChromeHidden: (Bool) -> Void
}

struct ExerciseScheduleView: View {
    @Bindable var feed: HomeStore
    let team: FeedTeam
    var initiallyCreatesSession = false
    var initialOccurrence: FeedOccurrence?
    var initiallyShowsRegistration = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedID: UUID?
    @State private var expanded = false
    @State private var showsComposer = false
    @State private var createdID: UUID?
    @State private var clock = Date.now
    @State private var chromeHidden = false
    @State private var isTransitioning = false
    @State private var transitionGeneration = 0

    init(feed: HomeStore, team: FeedTeam, initiallyCreatesSession: Bool = false,
         initialOccurrence: FeedOccurrence? = nil, initiallyShowsRegistration: Bool = false) {
        self.feed = feed
        self.team = team
        self.initiallyCreatesSession = initiallyCreatesSession
        self.initialOccurrence = initialOccurrence
        self.initiallyShowsRegistration = initiallyShowsRegistration
        let dates = feed.scheduleOccurrences(for: team.id)
        _selectedID = State(initialValue: initialOccurrence?.id ?? feed.preferredScheduleOccurrence(for: team.id)?.id)
        _expanded = State(initialValue: initialOccurrence != nil || dates.count == 1)
    }

    private var dates: [FeedOccurrence] { feed.scheduleOccurrences(for: team.id, at: clock) }
    private var isOwner: Bool { feed.isOwner(ofTeamID: team.id) }
    private var selectedDate: FeedOccurrence? { dates.first { $0.id == selectedID } ?? dates.first }
    private var artwork: String {
        selectedDate.map { feed.scheduleArt(for: $0) }
            ?? SportArtLibrary.photo(for: team.id, sportKey: team.sport) ?? "ExerciseArt1"
    }
    /// The selected date's place in the schedule, counted from one.
    private var selectedPosition: Int {
        (dates.firstIndex { $0.id == selectedID } ?? 0) + 1
    }

    private var animation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .smooth(duration: 0.34, extraBounce: 0)
    }

    /// ScrollView owns this value only while browsing. Expanding a card must
    /// never let an intermediate scroll target change which date is enlarged.
    private var browsingPosition: Binding<UUID?> {
        Binding(get: { selectedID }, set: { id in
            guard !expanded, !isTransitioning, let id else { return }
            selectedID = id
        })
    }

    var body: some View {
        // The stack exists for iPhone Duo's vertical bar, where the expanded
        // date's toolbar items live. Everywhere else its bar stays hidden and
        // the dates draw their own floating buttons.
        scheduleCanvas.verticalBarHost()
    }

    private var scheduleCanvas: some View {
        GeometryReader { host in
            GeometryReader { geometry in
                ZStack {
                    HomeArtBackdrop(artName: artwork, hasArt: true)

                    if dates.isEmpty {
                        UnscheduledExerciseView(feed: feed, team: team, artName: artwork) {
                            showsComposer = true
                        }
                        .padding(.top, host.safeAreaInsets.top)
                        .padding(.bottom, host.safeAreaInsets.bottom)
                    } else {
                        schedulePager(in: geometry, safeArea: host.safeAreaInsets)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .task(id: ScheduleArtworkPreparation(
                    names: dates.map { feed.scheduleArt(for: $0) }, size: geometry.size
                )) {
                    let names = dates.map { feed.scheduleArt(for: $0) }
                    let size = geometry.size
                    let worker = Task.detached(priority: .userInitiated) {
                        SportArtLibrary.warmDisplayImages(names)
                        SportArtLibrary.warmDetailFrostImages(names, size: size)
                        SportArtLibrary.warmBackdropImages(names)
                    }
                    await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                }
                .overlay(alignment: .bottom) {
                    if !dates.isEmpty, !chromeHidden {
                        bottomBar.padding(.bottom, host.safeAreaInsets.bottom)
                    }
                }

            }
            .ignoresSafeArea(.container)
        }
        .environment(\.layoutDirection, .tamrin)
        // A vertical pull belongs to the date browser. The Home zoom must not
        // consume it as an interactive dismissal of the entire workspace.
        .interactiveDismissDisabled()
        .task {
            feed.focusTeam(id: team.id)
            if initiallyCreatesSession && isOwner { showsComposer = true }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { clock = $0 }
        .onChange(of: feed.teams.map(\.id)) { _, ids in
            if !ids.contains(team.id) { dismiss() }
        }
        .onChange(of: dates.map(\.id)) { _, ids in
            guard !showsComposer else { return }
            reconcileSelection(ids)
        }
        .fullScreenCover(isPresented: $showsComposer, onDismiss: {
            if let createdID {
                selectedID = createdID
                expanded = true
                self.createdID = nil
            } else {
                reconcileSelection(dates.map(\.id))
            }
        }) {
            AddSessionSheet(feed: feed, isPresented: $showsComposer,
                            workspaceID: team.id,
                            initialPlan: feed.newSessionDraft(for: team.id)) { created in
                createdID = created.id
            }
        }
    }

    private func schedulePager(in geometry: GeometryProxy, safeArea: EdgeInsets) -> some View {
        // The paging grid never changes: same slot width, gap, margins and
        // viewport in both states. Only the selected card draws outside its
        // slot, so native RTL snapping has no new offsets to reconcile.
        let inset: CGFloat = 22
        let slotWidth = geometry.size.width - inset * 2
        let collapsedTop = safeArea.top + 18
        let footerHeight: CGFloat = (isOwner ? 96 : 40) + safeArea.bottom
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(dates) { occurrence in
                    let isSelected = occurrence.id == selectedID
                    let isExpanded = expanded && isSelected
                    EventDetailView(
                        feed: feed, occurrence: occurrence,
                        artName: feed.scheduleArt(for: occurrence),
                        initiallyShowsRegistration: initiallyShowsRegistration && occurrence.id == initialOccurrence?.id,
                        schedulePresentation: EventSchedulePresentation(
                            isExpanded: isExpanded,
                            allowsContentScrolling: isExpanded && !isTransitioning,
                            artworkSize: geometry.size,
                            topInset: isExpanded ? safeArea.top : 12,
                            bottomInset: footerHeight + (isExpanded ? 0 : collapsedTop),
                            expand: { expand(occurrence.id) },
                            collapse: { if isSelected { setExpanded(false) } },
                            back: {
                                if expanded && dates.count > 1 { setExpanded(false) }
                                else if !isTransitioning { dismiss() }
                            },
                            setChromeHidden: { chromeHidden = $0 }
                        )
                    )
                    // scrollDisabled on the horizontal pager is inherited.
                    // Its lock must not disable the vertical detail scroll.
                    .environment(\.isScrollEnabled, true)
                    .frame(width: isExpanded ? geometry.size.width : slotWidth,
                           height: geometry.size.height)
                    // The lower edge is deliberately beyond the screen. These
                    // are pages with rounded shoulders, not floating tiles.
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: isExpanded ? 0 : 30,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: isExpanded ? 0 : 30
                    ))
                    .overlay(alignment: .top) {
                        Capsule().fill(.white.opacity(0.4))
                            .frame(width: 34, height: 4).padding(.top, 8)
                            .opacity(isExpanded ? 0 : 1)
                            .allowsHitTesting(false)
                    }
                    .offset(y: isExpanded ? 0 : collapsedTop)
                    // This outer frame is what the horizontal pager measures.
                    .frame(width: slotWidth, height: geometry.size.height, alignment: .top)
                    .opacity(expanded && !isSelected ? 0 : 1)
                    .zIndex(isExpanded ? 1 : 0)
                    // The old date still owns the finger while selection moves
                    // to its neighbor. Disabling it mid-pan cancels that drag.
                    .allowsHitTesting(!expanded || isSelected)
                    .accessibilityAction(named: "فتح الموعد بكامل الشاشة") { expand(occurrence.id) }
                    .accessibilityHidden(!isSelected)
                    .id(occurrence.id)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, inset, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        .scrollPosition(id: browsingPosition, anchor: .center)
        .scrollDisabled(expanded || isTransitioning || chromeHidden)
        .scrollClipDisabled()
        .frame(height: geometry.size.height)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if dates.count > 1, !expanded {
                HStack(spacing: 6) {
                    ForEach(dates) { date in
                        Button {
                            withAnimation(animation) { selectedID = date.id }
                        } label: {
                            Capsule().fill(.white.opacity(date.id == selectedID ? 1 : 0.3))
                                .frame(width: date.id == selectedID ? 18 : 5, height: 5)
                                .frame(minWidth: 24, minHeight: 24)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(date.startAt.arabicDay)، \(date.startAt.arabicTime)")
                        .accessibilityAddTraits(date.id == selectedID ? [.isSelected] : [])
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("مواعيد التمرين")
                .accessibilityValue("\(selectedPosition) من \(dates.count)")
                .accessibilityAdjustableAction { direction in
                    selectAdjacentDate(direction == .increment ? 1 : -1)
                }
                .accessibilityAction(named: "الموعد التالي") { selectAdjacentDate(1) }
                .accessibilityAction(named: "الموعد السابق") { selectAdjacentDate(-1) }
            }
            if isOwner {
                Button {
                    Haptics.impact(.light)
                    showsComposer = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                        Text("موعد جديد")
                            .font(TamrinFont.font(size: 16, weight: .medium))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: TamrinControlMetrics.actionHeight)
                    .contentShape(.capsule)
                }
                .buttonStyle(ExerciseChromeButtonStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("schedule.newSession")
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.28)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }

    private func selectAdjacentDate(_ offset: Int) {
        guard !expanded, !isTransitioning else { return }
        let index = dates.firstIndex { $0.id == selectedID } ?? 0
        let next = index + offset
        guard dates.indices.contains(next) else { return }
        withAnimation(animation) { selectedID = dates[next].id }
    }

    private func expand(_ id: UUID) {
        guard !expanded, dates.contains(where: { $0.id == id }) else { return }
        // The finger identifies the date even if native snapping has not yet
        // published its final selection into scrollPosition.
        selectedID = id
        Haptics.impact(.light)
        setExpanded(true)
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        isTransitioning = true
        withAnimation(animation, completionCriteria: .removed) {
            expanded = value
        } completion: {
            if transitionGeneration == generation { isTransitioning = false }
        }
    }

    private func reconcileSelection(_ ids: [UUID]) {
        if selectedID.map({ ids.contains($0) }) != true {
            selectedID = feed.preferredScheduleOccurrence(for: team.id, at: clock)?.id
        }
        if ids.count == 1 { expanded = true }
    }
}

private struct ScheduleArtworkPreparation: Equatable {
    let names: [String]
    let size: CGSize
}
