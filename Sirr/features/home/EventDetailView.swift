import SwiftUI

/// Event detail page — the designer's OccurrenceDetailView (member view) bound
/// to HomeStore, including the manual-payment registration and review flow.
struct EventDetailView: View {
    @Bindable var feed: HomeStore
    /// Keep the navigation payload only as a recovery snapshot. Editing the
    /// exercise template replaces the event and workspace values in HomeStore
    /// while this full-screen detail remains presented, so rendering this copy
    /// directly would leave the old title, terms and sport photograph onscreen
    /// until the person closed and reopened the page.
    private let initialOccurrence: FeedOccurrence
    private let initialArtName: String
    var initiallyShowsRegistration = false
    #if DEBUG
    /// Opens the post-registration guest flow for deterministic simulator QA.
    var initiallyShowsGuestRegistration = false
    /// Opens the guest-without-self flow for deterministic simulator QA.
    var initiallyShowsGuestOnlyRegistration = false
    #endif
    @Environment(\.dismiss) private var dismiss
    @State private var showWithdrawConfirm = false
    @State private var showRegisterFlow = false
    @State private var guestRegistrationMode: RegistrationFlowSheet.Mode?
    /// Adding one companion to a free exercise asks a single question, so it
    /// gets the one-field sheet rather than the whole registration flow. A
    /// paid one still has to walk the payment steps.
    @State private var showCompanionSheet = false
    @State private var showPaymentReview = false
    @State private var paymentActionInFlight: UUID?
    @State private var memberAwaitingRejection: FeedMember?
    @State private var actionErrorMessage: String?
    @State private var handledInitialRegistration = false
    @State private var showManualAdd = false
    @State private var showMemberReminder = false
    @State private var reminderToast: String?
    @State private var memberAwaitingRemoval: FeedMember?
    @State private var memberInDetails: FeedMember?
    @State private var removalInFlight: UUID?
    @State private var showDeclinedResponses = false
    /// Captures the group behind this occurrence while its translucent details
    /// page is open. The optional itself drives the horizontal transition.
    @State private var exerciseDetailsTeamID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The saved split, held here so the section under the progress bar
    /// redraws the moment the lineup page closes.
    @State private var lineupPlan: LineupPlan?
    /// A stable copy keeps the card that launched the transition available
    /// until it has flown home, even if the editor replaces or deletes the
    /// saved plan while the detail page is still presented.
    @State private var lineupTransitionTeams: LineupTeams?
    /// The card the lineup page grows out of. A card stays in this view tree so
    /// it can travel to the top of the detail page as one continuous surface,
    /// like Wallet, instead of zooming an entire cover from the card's frame.
    @Namespace private var lineupZoom
    /// Only the empty-state entry still needs a cover: it opens the editor and
    /// has no team card to carry into a read-only detail page.
    @State private var lineupCoverPresentation: LineupZoomSource?
    /// The selected team is overlaid in this same hierarchy for the Wallet
    /// transition. Details arrive on a second beat, after the card has lifted.
    @State private var lineupCardPresentation: LineupSide?
    @State private var lineupCardExpanded = false
    @State private var lineupBackdropVisible = false
    @State private var lineupDetailsVisible = false
    @State private var lineupCardSettled = false
    @State private var lineupCardIsClosing = false
    @State private var lineupTransitionTask: Task<Void, Never>?
    /// Set when a lineup is saved and this person has not said what they think
    /// of the feature yet. The question waits for the lineup page to close —
    /// a sheet raised while a cover is dismissing has nothing to sit on.
    @State private var pendingFeedback: TamrinFeature?
    @State private var feedbackInFlight: TamrinFeature?
    /// Live top edge of the content panel, in screen coordinates. The blurred
    /// artwork is revealed from here down, so the frost follows the panel
    /// through every scroll and every added row.
    @State private var panelTop: CGFloat = .greatestFiniteMagnitude

    #if DEBUG
    init(
        feed: HomeStore,
        occurrence: FeedOccurrence,
        artName: String = "ExerciseArt1",
        initiallyShowsRegistration: Bool = false,
        initiallyShowsGuestRegistration: Bool = false,
        initiallyShowsGuestOnlyRegistration: Bool = false
    ) {
        self.feed = feed
        self.initialOccurrence = occurrence
        self.initialArtName = artName
        self.initiallyShowsRegistration = initiallyShowsRegistration
        self.initiallyShowsGuestRegistration = initiallyShowsGuestRegistration
        self.initiallyShowsGuestOnlyRegistration = initiallyShowsGuestOnlyRegistration
    }
    #else
    init(
        feed: HomeStore,
        occurrence: FeedOccurrence,
        artName: String = "ExerciseArt1",
        initiallyShowsRegistration: Bool = false
    ) {
        self.feed = feed
        self.initialOccurrence = occurrence
        self.initialArtName = artName
        self.initiallyShowsRegistration = initiallyShowsRegistration
    }
    #endif

    /// The event id is stable across template edits. Prefer the refreshed store
    /// value and fall back to the navigation snapshot only while a reload is in
    /// flight or after the event leaves the active caches.
    private var occurrence: FeedOccurrence {
        feed.allOccurrences.first { $0.id == initialOccurrence.id }
            ?? initialOccurrence
    }

    /// Sport artwork belongs to the live workspace identity, not to the poster
    /// snapshot that launched this page. A sport with no bundled photograph
    /// falls back to the event's deterministic generic artwork; a missing team
    /// keeps the caller-provided image so loading never flashes another asset.
    private var artName: String {
        guard let team = feed.team(for: occurrence),
              let sportKey = Sport.named(team.symbol)?.key else {
            return initialArtName
        }
        return SportArtLibrary.photo(for: occurrence.id, sportKey: sportKey)
            ?? "ExerciseArt\((occurrence.artIndex % 3) + 1)"
    }

    private var roster: [FeedMember] { feed.roster(for: occurrence) }
    private var myRegistration: FeedMember? { feed.myRegistration(for: occurrence) }
    private var confirmedCount: Int { feed.registeredCount(for: occurrence) }
    private var waitingCount: Int { feed.waitlistCount(for: occurrence) }
    private var declinedResponses: [EventMemberResponseRecord] {
        feed.declinedResponses(for: occurrence)
    }
    /// Workspace sport is the source of truth for both the court drawing and
    /// football-only features such as ratings and positions.
    private var lineupSportStyle: LineupSportStyle {
        LineupSportStyle(sport: feed.team(for: occurrence)?.sport)
    }

    /// My own photo can still be only in memory — the upload lags the pick,
    /// and the roster's copy of it arrives a refresh later — so my row reads
    /// it straight from the profile rather than waiting for a URL.
    private func avatarData(for member: FeedMember) -> Data? {
        member.userId == feed.currentUserID ? feed.avatarData : nil
    }

    /// Where this player sits in the order people registered — the roster
    /// already arrives sorted by `joined_at`.
    private func seatNumber(of member: FeedMember) -> Int? {
        roster.firstIndex { $0.id == member.id }.map { $0 + 1 }
    }

    /// Nil only for a guest. A player can open their own sheet and read the
    /// anonymous group average; self-rating is prevented by the submitter.
    private func ratingLoader(for member: FeedMember) -> (@MainActor () async throws -> PlayerRatingSummary)? {
        guard lineupSportStyle.usesFootballFeatures, member.userId != nil else { return nil }
        return { try await feed.playerRating(for: member) }
    }

    private func ratingSubmitter(
        for member: FeedMember
    ) -> (@MainActor (PlayerRatingScores) async throws -> SubmitRatingResult)? {
        guard lineupSportStyle.usesFootballFeatures, feed.canRate(member) else { return nil }
        return { try await feed.submitPlayerRating($0, for: member) }
    }

    /// Guests carry the account id that registered them. Resolve it through
    /// the exercise membership list so every viewer sees a human name without
    /// exposing an opaque UUID in the roster.
    private func registeredByName(for member: FeedMember) -> String? {
        guard member.isGuest, !member.isManual, let addedBy = member.addedBy else {
            return nil
        }
        if let registrar = feed.teamMembers.first(where: { $0.id == addedBy }) {
            return registrar.displayName
        }
        guard addedBy == feed.currentUserID else { return nil }
        let ownName = feed.profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ownName.isEmpty ? nil : ownName
    }

    private func rosterSubtitle(for member: FeedMember) -> String? {
        if member.isManual { return "سجّله المشرف" }
        return registeredByName(for: member).map { "سجّله \($0)" }
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    Image(exerciseArt: artName)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()

                    // The same artwork, blurred, revealed only where the panel
                    // is. Because both layers are the one photograph, the panel
                    // edge dissolves as a change in focus rather than a veil
                    // laid over the picture — and the mask is measured from the
                    // panel's live position, so the frost travels with it.
                    Image(exerciseArt: artName)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                        .blur(radius: 26, opaque: true)
                        .mask(alignment: .top) { panelMask }

                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.32), location: 0),
                        .init(color: .black.opacity(0.06), location: 0.26),
                        .init(color: .black.opacity(0.30), location: 0.55),
                        .init(color: .black.opacity(0.58), location: 1)
                    ], startPoint: .top, endPoint: .bottom)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            // The window onto the untouched artwork. Everything
                            // after it travels with the panel.
                            Color.clear
                                .frame(height: Self.artworkWindow)

                            contentPanel
                                .frame(
                                    minHeight: proxy.size.height - Self.artworkWindow,
                                    alignment: .top
                                )
                                .onGeometryChange(for: CGFloat.self) {
                                    $0.frame(in: .global).minY
                                } action: { panelTop = $0 }
                        }
                    }
                }
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Label("إغلاق", systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: TamrinControlMetrics.glassIconContent, height: TamrinControlMetrics.glassIconContent)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .accessibilityLabel("إغلاق")
        }
        .overlay(alignment: .topTrailing) {
            Button {
                guard let teamID = feed.teamID(for: occurrence) else {
                    Haptics.error()
                    return
                }
                feed.focusTeam(for: occurrence)
                Haptics.impact(.light)
                withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .smooth(duration: 0.36)) {
                    exerciseDetailsTeamID = teamID
                }
            } label: {
                // A page of listed details, which is literally what opens:
                // the day and time, the pitch, the money, who is in it.
                //
                // Not «i», which in system language means "here is a note
                // about this screen" rather than "here is a page of its
                // particulars". And not a clipboard: in software that glyph
                // belongs to copy and paste before it belongs to anything a
                // coach carries.
                Label("تفاصيل التمرين", systemImage: "list.bullet.rectangle.portrait")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(
                        width: TamrinControlMetrics.glassIconContent,
                        height: TamrinControlMetrics.glassIconContent
                    )
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .accessibilityLabel("تفاصيل التمرين")
            .accessibilityHint("يفتح قالب التمرين وأعضاءه وطرق الدفع")
            .disabled(feed.teamID(for: occurrence) == nil)
        }
        .overlay(alignment: .top) {
            if let reminderToast {
                Label(reminderToast, systemImage: "checkmark.circle.fill")
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
        // Wallet leaves the selected card crisp while the stack behind it
        // falls away. Blurring this whole tree also blurs SwiftUI's matched
        // source snapshot during the flight, so the destination page supplies
        // the soft backdrop while this tree only fades and darkens.
        .opacity(!lineupBackdropVisible || reduceMotion ? 1 : 0)
        .brightness(!lineupBackdropVisible || reduceMotion ? 0 : -0.08)
        .allowsHitTesting(lineupCardPresentation == nil && exerciseDetailsTeamID == nil)
        .overlay {
            if let side = lineupCardPresentation {
                LineupTeamPage(
                    feed: feed,
                    occurrence: occurrence,
                    artName: artName,
                    side: side,
                    initialTeams: displayedLineup,
                    transitionSource: reduceMotion ? nil : side,
                    transitionNamespace: reduceMotion ? nil : lineupZoom,
                    heroExpanded: lineupCardExpanded,
                    backdropVisible: lineupBackdropVisible,
                    detailsVisible: lineupDetailsVisible,
                    interactionEnabled: lineupCardSettled,
                    onTransitionReady: { startLineupCardTransition(for: side) },
                    onRequestClose: closeLineupCard
                ) { plan in
                    finishLineup(with: plan)
                }
                .opacity(reduceMotion ? (lineupDetailsVisible ? 1 : 0) : 1)
                .zIndex(100)
            }
        }
        .overlay {
            // This outer reader keeps the host's safe-area frame. The moving
            // page inside expands to the physical display, but can still use
            // the outer frame's global top edge to place its header correctly.
            GeometryReader { hostProxy in
                GeometryReader { proxy in
                    // The page moves on the screen's physical x-axis. Keeping this
                    // wrapper LTR prevents SwiftUI from mirroring the offset under
                    // the app's Arabic layout; the page restores RTL for its own
                    // content below.
                    ZStack(alignment: .leading) {
                        if let teamID = exerciseDetailsTeamID {
                            ZStack {
                                Rectangle()
                                    .fill(.ultraThinMaterial)
                                    .ignoresSafeArea()

                                Color.black.opacity(0.3)
                                    .ignoresSafeArea()

                                ExerciseDetailsOverlayPage(
                                    feed: feed,
                                    occurrence: occurrence,
                                    teamID: teamID,
                                    screenTopInset: max(hostProxy.frame(in: .global).minY, 0)
                                ) {
                                    withAnimation(reduceMotion
                                                  ? .easeOut(duration: 0.18)
                                                  : .smooth(duration: 0.36)) {
                                        exerciseDetailsTeamID = nil
                                    }
                                }
                            }
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            // Clip before the transition so every moving frame
                            // already carries the iPhone's own rounded silhouette.
                            .clipShape(
                                ConcentricRectangle(
                                    corners: .concentric,
                                    isUniform: true
                                )
                            )
                            .environment(\.colorScheme, .dark)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .offset(x: -max(proxy.size.width, 1), y: 0)
                            )
                            .zIndex(200)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .environment(\.layoutDirection, .leftToRight)
                }
                // The host detail view is laid out inside the safe area. Expand
                // this presented page to the physical screen before clipping it,
                // so its rounded moving silhouette follows the device itself
                // instead of looking like a sheet cropped below the status bar.
                .ignoresSafeArea(.container)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .colorScheme(.dark)
        .sheet(isPresented: $showWithdrawConfirm) {
            MemberDeclineSheet { reasonCode, reasonText in
                let outcome = await feed.decline(
                    occurrence,
                    reasonCode: reasonCode,
                    reasonText: reasonText
                )
                if case .failure(let message) = outcome {
                    throw NSError(
                        domain: "EventDetailView.Decline",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }
                Haptics.success()
            }
        }
        .sheet(isPresented: $showRegisterFlow) {
            RegistrationFlowSheet(feed: feed, occurrence: occurrence, artName: artName)
        }
        .sheet(isPresented: $showCompanionSheet) {
            ManualParticipantSheet(
                isPaid: false,
                title: "سجّل معك أحد",
                subtitle: "أضف لاعبًا يحضر معك في هذا الموعد",
                footnote: "يحجز له مقعدًا في هذا الموعد فقط، ولا يحتاج حساب في التطبيق."
            ) { name in
                await addCompanion(named: name)
            }
        }
        .sheet(item: $guestRegistrationMode) { mode in
            RegistrationFlowSheet(
                feed: feed,
                occurrence: occurrence,
                artName: artName,
                mode: mode
            )
        }
        .sheet(isPresented: $showPaymentReview) {
            RegistrationFlowSheet(
                feed: feed,
                occurrence: occurrence,
                artName: artName,
                reviewOnly: true,
                onSuccessDismiss: occurrence.requiresPaymentAction ? { dismiss() } : nil
            )
        }
        .task {
            await feed.reloadOccurrence(occurrence.id)
            await feed.reloadRoster(occurrence.id)
            await feed.reloadMemberResponses(occurrence.id)
            #if DEBUG
            if initiallyShowsGuestOnlyRegistration,
               !handledInitialRegistration,
               !feed.isCurrentTeamOwner,
               [.available, .declined].contains(feed.participationState(for: occurrence)),
               !isHistorical,
               !occurrence.isCancelled {
                handledInitialRegistration = true
                await Task.yield()
                guestRegistrationMode = .guestOnly
                return
            }
            if initiallyShowsGuestRegistration,
               !handledInitialRegistration,
               !feed.isCurrentTeamOwner,
               feed.participationState(for: occurrence) == .registered
                 || feed.participationState(for: occurrence) == .awaitingPayment,
               !isHistorical,
               !occurrence.isCancelled {
                handledInitialRegistration = true
                await Task.yield()
                guestRegistrationMode = .additionalGuests
                return
            }
            #endif
            guard initiallyShowsRegistration,
                  !handledInitialRegistration,
                  !feed.isCurrentTeamOwner,
                  !occurrence.isCancelled else { return }
            handledInitialRegistration = true
            if isHistorical {
                // Roster refresh above can reveal that this payment was
                // already declared on another device after Home built its
                // card. Use the reconciled state instead of reopening a stale
                // payment flow from the immutable launch value.
                if showsOverduePaymentAction {
                    await Task.yield()
                    showPaymentReview = true
                }
                return
            }
            let state = feed.participationState(for: occurrence)
            if state == .available || state == .declined {
                await Task.yield()
                showRegisterFlow = true
            }
        }
        .alert("رفض طلب الدفع؟", isPresented: Binding(
            get: { memberAwaitingRejection != nil },
            set: { if !$0 { memberAwaitingRejection = nil } }
        )) {
            Button("رفض الطلب", role: .destructive) {
                if let member = memberAwaitingRejection {
                    rejectPayment(member)
                }
                memberAwaitingRejection = nil
            }
            Button("تراجع", role: .cancel) { memberAwaitingRejection = nil }
        } message: {
            Text(
                memberAwaitingRejection?.userId == nil
                    ? "سيُلغى طلب الضيوف المعلّق وتتحرر مقاعدهم، ويبقى تسجيل العضو محفوظًا."
                    : "سيُلغى حجز اللاعب وكل الضيوف المسجلين معه وتتحرر مقاعدهم."
            )
        }
        .fullScreenCover(isPresented: $showDeclinedResponses) {
            DeclinedResponsesPage(
                responses: declinedResponses,
                reasonDisplay: declineReasonDisplay(for:)
            )
            // A cover is opaque by default. Clearing it is what lets the page
            // sit over the exercise artwork as a blurred, dimmed overlay.
            //
            // The material must be resolved in the dark scheme: a presentation
            // background does not inherit the detail screen's `.colorScheme`,
            // and the light variant turns the blur into a near-white sheet that
            // the page's white text disappears into.
            .presentationBackground {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Color.black.opacity(0.3)
                }
                .environment(\.colorScheme, .dark)
            }
        }
        .fullScreenCover(item: $lineupCoverPresentation) { source in
            LineupFlowView(feed: feed, occurrence: occurrence, artName: artName) { plan in
                finishLineup(with: plan)
            }
            .navigationTransition(.zoom(sourceID: source, in: lineupZoom))
        }
        .onChange(of: lineupCoverPresentation) { _, presented in
            if presented == nil { presentPendingFeedback() }
        }
        .onChange(of: lineupCardPresentation) { _, presented in
            if presented == nil { presentPendingFeedback() }
        }
        .sheet(item: $feedbackInFlight) { feature in
            FeatureFeedbackSheet(feature: feature)
        }
        .onAppear {
            if !occurrence.isCancelled, lineupPlan == nil {
                lineupPlan = LineupStore.load(eventID: occurrence.id)
            }
        }
        .onDisappear {
            lineupTransitionTask?.cancel()
        }
        .sheet(isPresented: $showMemberReminder) {
            MemberReminderSheet { kind in
                let outcome = await feed.remindMembers(kind, on: occurrence)
                switch outcome {
                case .sent(let message):
                    showReminderToast(message)
                    return message
                case .failure(let message):
                    throw NSError(
                        domain: "EventDetailView.MemberReminder",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }
            }
        }
        .sheet(isPresented: $showManualAdd) {
            ManualParticipantSheet(isPaid: occurrence.price > 0) { name in
                let outcome = await feed.addManualParticipant(named: name, to: occurrence)
                if case .failure(let message) = outcome { return message }
                return nil
            }
        }
        .sheet(item: $memberInDetails) { member in
            PlayerDetailsSheet(
                member: member,
                avatarImageData: avatarData(for: member),
                share: occurrence.price,
                seatNumber: seatNumber(of: member),
                // A player's share and payment state are organizer-only.
                showsPayment: feed.isCurrentTeamOwner,
                loadRating: ratingLoader(for: member),
                submitRating: ratingSubmitter(for: member),
                registeredByName: registeredByName(for: member),
                // A free exercise has nothing to chase, a guest or a manually
                // seated player has no account to notify, and nobody needs to
                // be reminded of their own share.
                onRemind: feed.isCurrentTeamOwner
                    && occurrence.price > 0
                    && member.userId != nil
                    && member.userId != feed.currentUserID
                    ? { await feed.remindPayment(member, on: occurrence) }
                    : nil,
                onRemove: feed.isCurrentTeamOwner
                    ? { memberAwaitingRemoval = member }
                    : nil
            )
        }
        .alert("إزالة اللاعب؟", isPresented: Binding(
            get: { memberAwaitingRemoval != nil },
            set: { if !$0 { memberAwaitingRemoval = nil } }
        )) {
            Button("إزالة", role: .destructive) {
                if let member = memberAwaitingRemoval {
                    removeParticipant(member)
                }
                memberAwaitingRemoval = nil
            }
            Button("تراجع", role: .cancel) { memberAwaitingRemoval = nil }
        } message: {
            Text("سيُزال \(memberAwaitingRemoval?.name ?? "اللاعب") من قائمة «\(occurrence.title)» ويتحرر مقعده.")
        }
        .alert("تعذر إكمال العملية", isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )) {
            Button("حسنًا", role: .cancel) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "")
                .font(TamrinFont.body)
        }
    }

    /// How much artwork stays sharp above the panel.
    private static let artworkWindow: CGFloat = 300
    /// The stretch over which the panel's frost dissolves in from the artwork.
    private static let panelFadeHeight: CGFloat = 150
    /// How far above the panel's edge that dissolve begins.
    private static let panelFadeLead: CGFloat = 60

    /// Everything the organizer reads or acts on lives in one container, and
    /// the blur is that container's own background rather than a band painted
    /// on the screen. Add rows or scroll and the frosted surface travels with
    /// them, so no card is ever left sitting on bare artwork.
    private var contentPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroTitle
                .padding(.bottom, 6)

            if occurrence.isCancelled {
                cancellationPanel
            } else if showsOverduePaymentAction {
                overduePaymentCTA
            } else if isHistorical {
                historicalStatusPanel
            } else if !feed.isCurrentTeamOwner {
                participationCTA
            }

            // One row of square tiles rather than a wall of full-width rows.
            // Whichever tiles apply share the width between them.
            if !declinedResponses.isEmpty || canRemindMembers || canShareJoinLink {
                HStack(spacing: 10) {
                    if !declinedResponses.isEmpty { declinedResponsesButton }
                    if canRemindMembers { remindMembersButton }
                    if canShareJoinLink { shareButton }
                }
            }

            // Full width under the tiles, and titled with the venue itself when
            // we know its name: getting there is one destination, not a choice
            // among three, and the pitch's name says more than "الاتجاهات".
            if hasDirections { directionsButton }

            progressPanel

            // Between the count and the names: the split is what the organizer
            // does once he knows how many showed up, and before he reads the
            // list person by person.
            if showsLineup {
                lineupSection
            }

            Text("القائمة")
                .font(TamrinFont.font(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.top, 8)
                .padding(.horizontal, 4)

            // Above the names, not after them: the organizer reaches it
            // without scrolling past a full roster.
            if canRegisterManually {
                manualAddButton
            }

            rosterRows
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Transparent above the panel, then a long dissolve into full frost. The
    /// ramp starts a little before the panel's top edge so the title is already
    /// sitting on softened artwork, exactly as it did when the mask was pinned
    /// to the screen.
    private var panelMask: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: max(panelTop - Self.panelFadeLead, 0))
            LinearGradient(
                colors: [.black.opacity(0), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.panelFadeHeight)
            Color.black
        }
    }

    private var heroTitle: some View {
        VStack(spacing: 7) {
            if occurrence.isCancelled {
                Text("هذا الموعد متخطّى")
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
    private var cancellationPanel: some View {
        if let reason = cancellationReasonDisplay {
            VStack(alignment: .leading, spacing: 8) {
                Label("سبب التخطي", systemImage: "info.circle.fill")
                    .font(TamrinFont.font(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Text(reason)
                    .font(TamrinFont.font(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .tamrinGlassCard()
        } else {
            Text("موعد هذا الأسبوع متخطّى، وتستمر المواعيد القادمة كالمعتاد.")
                .font(TamrinFont.font(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.76))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .tamrinGlassCard()
        }
    }

    private var cancellationReasonDisplay: String? {
        let custom = occurrence.cancellationReasonText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty { return custom }
        switch occurrence.cancellationReasonCode {
        case "weather": return "ظرف الطقس"
        case "match_or_event_conflict": return "تعارض مع مباراة أو حدث مهم"
        case "low_attendance": return "قلة العدد"
        case "occasion": return "وجود مناسبة"
        case "other": return "سبب آخر"
        default: return nil
        }
    }

    private var isHistorical: Bool {
        occurrence.isPast(relativeTo: .now)
    }

    /// The API metadata keeps the payment door open after the clock has ended.
    /// Once declaration succeeds the roster becomes payment-pending before the
    /// success sheet is dismissed, so the old detail settles back to read-only.
    private var showsOverduePaymentAction: Bool {
        guard isHistorical,
              occurrence.requiresPaymentAction,
              !feed.isCurrentTeamOwner else { return false }
        let paymentRows = roster.filter { $0.paymentOwnerId == feed.currentUserID }
        if paymentRows.contains(where: { $0.status == .awaitingPayment }) {
            return true
        }
        if paymentRows.contains(where: { $0.status == .paymentPending }) {
            return false
        }
        // Before the roster arrives, the server-computed occurrence flag is
        // authoritative. This also covers a standalone guest debt where the
        // payer never reserved a self seat.
        return true
    }

    private var overduePaymentCTA: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("باقي دفع القطة", systemImage: "banknote.fill")
                .font(TamrinFont.font(size: 15, weight: .bold))
                .foregroundStyle(.white)

            Text("انتهى الموعد، وتقدر تسدد قطتك الآن قبل الانتقال للموعد القادم.")
                .font(TamrinFont.font(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Haptics.impact(.light)
                showPaymentReview = true
            } label: {
                Label("دفع القطة", systemImage: "banknote.fill")
                    .font(TamrinFont.font(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: TamrinControlMetrics.glassActionHeight)
                    .contentShape(.capsule)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .tint(Self.moneyGreen)
            .accessibilityHint("يفتح مبلغ القطة ووسائل الدفع المتاحة")
        }
        .padding(16)
        .tamrinGlassCard()
    }

    private var historicalStatusPanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))

            VStack(alignment: .leading, spacing: 2) {
                Text("تمرين سابق")
                    .font(TamrinFont.font(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Text("انتهى التسجيل والتعديل لهذا الموعد")
                    .font(TamrinFont.font(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.62))
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .tamrinGlassCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var participationCTA: some View {
        if feed.participationState(for: occurrence) == .unavailable {
            Button {
                Task { await feed.reloadRoster(occurrence.id) }
            } label: {
                Label("تعذر التحقق من تسجيلك. حاول مجددًا", systemImage: "arrow.clockwise")
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: TamrinControlMetrics.glassActionHeight)
                    .contentShape(.capsule)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
        } else if let mine = myRegistration {
            if mine.status == .paymentPending {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text("بانتظار تأكيد الدفع")
                            .font(TamrinFont.font(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Button {
                            showPaymentReview = true
                        } label: {
                            Label("مراجعة التفاصيل", systemImage: "doc.text.magnifyingglass")
                                .font(TamrinFont.font(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(.white.opacity(0.13), in: .capsule)
                        }
                        .buttonStyle(.plain)

                        Button {
                            showWithdrawConfirm = true
                        } label: {
                            Text("إلغاء الطلب")
                                .font(TamrinFont.font(size: 13, weight: .bold))
                                .foregroundStyle(.red.opacity(0.95))
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(.red.opacity(0.12), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .tamrinGlassCard()
            } else {
                VStack(spacing: 10) {
                    if mine.status == .awaitingPayment, occurrence.price > 0 {
                        Button {
                            Haptics.impact(.light)
                            showPaymentReview = true
                        } label: {
                            Label("دفع القطة", systemImage: "banknote.fill")
                                .font(TamrinFont.font(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: TamrinControlMetrics.glassActionHeight)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.regular)
                        // Banknote green rather than the app's lime: this is
                        // the one button in the app that moves money, and it
                        // should read as money rather than as another accent.
                        .tint(Self.moneyGreen)
                        .accessibilityHint("يفتح مبلغ القطة ووسائل الدفع المتاحة")
                    }

                    if mine.status == .paymentPending, occurrence.price > 0 {
                        paymentStateRow(
                            title: "بانتظار تأكيد وصول القطة",
                            systemImage: "hourglass",
                            tint: .orange
                        )
                    }

                    if mine.status == .registered, occurrence.price > 0 {
                        paymentStateRow(
                            title: "القطة مدفوعة",
                            systemImage: "checkmark.seal.fill",
                            tint: Self.moneyGreen
                        )
                    }

                    if mine.status == .registered || mine.status == .awaitingPayment,
                       occurrence.isPublished,
                       !occurrence.isCancelled {
                        Button {
                            Haptics.impact(.medium)
                            if occurrence.price > 0 {
                                guestRegistrationMode = .additionalGuests
                            } else {
                                showCompanionSheet = true
                            }
                        } label: {
                            // The quiet glass capsule, not the filled one:
                            // adding guests is a secondary action beside the
                            // registration state above it.
                            Label("سجّل معك أحد", systemImage: "person.badge.plus")
                                .font(TamrinFont.font(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: TamrinControlMetrics.glassActionHeight)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.regular)
                        .accessibilityLabel("إضافة لاعبين معك")
                        .accessibilityHint("يفتح تسجيل ضيوف جدد دون تغيير تسجيلك")
                    }

                    participationStatusButton(for: mine)
                }
            }
        } else {
            let full = occurrence.capacity > 0 && confirmedCount >= occurrence.capacity
            let closed = full && occurrence.capacityPolicy == .closed
            VStack(spacing: 10) {
                if closed {
                    // Nothing to press: every seat is taken and the organizer
                    // did not open a reserve list.
                    Label("التسجيل مغلق", systemImage: "lock.fill")
                        .font(TamrinFont.font(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: TamrinControlMetrics.glassActionHeight)
                        .background(.white.opacity(0.08), in: .capsule)
                        .accessibilityLabel("التسجيل مغلق، اكتمل العدد")
                } else {
                    Button {
                        Haptics.impact(.medium)
                        showRegisterFlow = true
                    } label: {
                        Label(
                            full ? "سجل كاحتياط" : "سجل في التمرين",
                            systemImage: full ? "person.badge.clock.fill" : "plus"
                        )
                        .font(TamrinFont.font(size: 16, weight: .bold))
                        .foregroundStyle(TamrinTheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: TamrinControlMetrics.glassActionHeight)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .tint(.white.opacity(0.94))
                }
            }
        }
    }

    /// Adds one companion to a free exercise. Returns nil on success, or the
    /// reason it did not happen, which the sheet shows in place.
    @MainActor
    private func addCompanion(named name: String) async -> String? {
        do {
            let destination = try await feed.paymentDestination(for: occurrence)
            let outcome = await feed.addGuests(
                [name],
                to: occurrence,
                expectedDestination: destination
            )
            if case .failure(let message) = outcome { return message }
            await feed.reloadRoster(occurrence.id)
            return nil
        } catch {
            return "تعذر إضافة اللاعب. تحقق من اتصالك وحاول مرة أخرى."
        }
    }

    /// A statement of where the money stands. Not a button: neither state has
    /// anything for the player to do — one is waiting on the organizer, the
    /// other is finished.
    private func paymentStateRow(
        title: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(TamrinFont.font(size: 15, weight: .bold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .frame(height: TamrinControlMetrics.glassActionHeight)
        .background(.white.opacity(0.08), in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private func participationStatusButton(for member: FeedMember) -> some View {
        Button { showWithdrawConfirm = true } label: {
            HStack(spacing: 10) {
                Image(systemName: member.status == .waitlisted ? "clock.fill" : "checkmark.circle.fill")
                    .foregroundStyle(member.status == .waitlisted ? .orange : TamrinTheme.lime)
                Text(member.status == .waitlisted ? "أنت في قائمة الانتظار" : "مكانك محفوظ")
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(member.status == .waitlisted ? "انسحب" : "اعتذر")
                    .font(TamrinFont.font(size: 13, weight: .medium))
                    .foregroundStyle(.red.opacity(0.95))
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: TamrinControlMetrics.glassActionHeight)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .accessibilityHint("يفتح تأكيد الاعتذار عن الموعد")
    }

    /// Clamped so an over-subscribed list cannot draw past the track.
    private var filledFraction: CGFloat {
        guard occurrence.capacity > 0 else { return 0 }
        return min(CGFloat(confirmedCount) / CGFloat(occurrence.capacity), 1)
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("المسجلون في الموعد")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                // "٩ من ١٤" — the word «من» disambiguates registered-vs-capacity
                // and pins the bidi order (the designer's "9\14" could flip in RTL).
                Text("\(confirmedCount.formatted()) من \(occurrence.capacity.formatted())")
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            // Drawn rather than tinted: a `ProgressView` owns its 4pt height,
            // and scaling it up stretches the caps with it. `.leading` is the
            // right edge here, so the fill grows the way the page reads.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.24))
                    Capsule()
                        .fill(.white)
                        .frame(width: proxy.size.width * filledFraction)
                }
            }
            .frame(height: 7)
            .animation(.smooth(duration: 0.3), value: filledFraction)
            .accessibilityElement()
            .accessibilityLabel("المسجلون")
            .accessibilityValue("\(confirmedCount.formatted()) من \(occurrence.capacity.formatted())")
            if waitingCount > 0 {
                Text("\(waitingCount.formatted()) في قائمة الانتظار")
                    .font(TamrinFont.font(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .tamrinGlassCard()
    }

    /// The list itself moved to its own page, so the detail screen keeps one
    /// row per section: name, how many, and a chevron that says it opens.
    private var declinedResponsesButton: some View {
        Button {
            showDeclinedResponses = true
        } label: {
            EventActionTile(symbol: "person.crop.circle.badge.xmark", title: "المعتذرون") {
                Text(declinedResponses.count.formatted())
                    .font(TamrinFont.font(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(.white.opacity(0.22), in: .capsule)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("المعتذرون، \(declinedResponses.count.formatted())")
        .accessibilityHint("يفتح قائمة المعتذرين وأسبابهم")
    }

    // MARK: - Lineup

    /// Splitting the sides is the organizer's job, and only while the exercise
    /// is still going ahead.
    private var canBuildLineup: Bool {
        feed.isCurrentTeamOwner && !occurrence.isCancelled && !isHistorical
    }

    /// Splitting the sides is the organizer's job; reading the result is
    /// everyone's. Gating the whole section on ownership meant a player could
    /// not see which side he was on — which is the one thing he opens this page
    /// for once a split exists.
    private var showsLineup: Bool {
        !occurrence.isCancelled && (canBuildLineup || resolvedLineup != nil)
    }

    /// The saved split against today's roster. Names, positions and photos are
    /// read fresh, so a player who left the exercise simply is not drawn.
    private var resolvedLineup: LineupTeams? {
        guard let lineupPlan else { return nil }
        let teams = lineupPlan.resolve(
            against: feed.lineupCandidates(
                for: occurrence,
                usesFootballPositions: lineupSportStyle.usesFootballFeatures
            )
        ).teams
        return teams.allPlayers.isEmpty ? nil : teams
    }

    private var displayedLineup: LineupTeams? {
        if lineupCardPresentation != nil, let lineupTransitionTeams {
            return lineupTransitionTeams
        }
        return resolvedLineup
    }

    /// The side the signed-in person plays on, when he is in the split at all.
    ///
    /// Matched through the roster rather than against `currentUserID` directly:
    /// a lineup player carries the registration row's id, not the account's,
    /// and the two are only the same by coincidence in some rows.
    private func mySide(in teams: LineupTeams) -> LineupSide? {
        guard let mine = roster.first(where: { $0.userId == feed.currentUserID }) else { return nil }
        return LineupSide.allCases.first { side in
            teams[side].contains { $0.id == mine.id }
        }
    }

    @ViewBuilder
    private var lineupSection: some View {
        Text("التشكيلة")
            .font(TamrinFont.font(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.top, 8)
            .padding(.horizontal, 4)

        if let teams = displayedLineup {
            // Each side is one card you press to go in — one showing its pitch,
            // the other resting under it. The level each side adds up to is the
            // organizer's working number while he splits; here the cards are
            // only the answer.
            //
            // The open one is the side this person is on. He came to see where
            // he is playing, and having to open the other card to find himself
            // is a step that exists for no one. The first side stays the
            // default for anyone not in the split — an organizer who is not
            // playing, or someone reading before he registers.
            let openSide = mySide(in: teams) ?? .first
            ForEach(LineupSide.allCases) { side in
                let card = LineupTeamCard(
                    side: side,
                    players: teams[side],
                    isExpanded: side == openSide,
                    sportStyle: lineupSportStyle,
                    onOpen: { openLineup(from: .card(side)) },
                    showsLevel: false
                )
                .clipShape(TamrinCard.shape)

                let isPresentedCard = lineupCardPresentation == side
                card
                    .matchedGeometryEffect(
                        id: LineupZoomSource.card(side),
                        in: lineupZoom,
                        properties: .frame,
                        anchor: .center,
                        // Hand ownership to the always-visible overlay hero on
                        // open, then back to this hidden anchor on close.
                        isSource: !isPresentedCard || !lineupCardExpanded
                    )
                    // Keep the source's geometry alive without crossfading a
                    // second card over the hero while either flight is moving.
                    .opacity(isPresentedCard ? 0 : 1)
                    // Wallet's stacked card is four points narrower per side
                    // than the detail card, giving the flight a 1.023× breath.
                    .padding(.horizontal, 4)
            }
        } else if canBuildLineup {
            buildLineupButton
        }
    }

    /// The lineup page closed. A saved split means the feature was used all
    /// the way through, which is the moment worth asking about it.
    private func finishLineup(with plan: LineupPlan?) {
        lineupPlan = plan
        guard plan != nil, FeatureFeedbackStore.shouldAsk(about: .lineup) else { return }
        pendingFeedback = .lineup
    }

    private func presentPendingFeedback() {
        guard let pending = pendingFeedback else { return }
        pendingFeedback = nil
        feedbackInFlight = pending
    }

    /// Opens the page out of the card that was pressed.
    private func openLineup(from source: LineupZoomSource) {
        Haptics.impact(.light)
        lineupTransitionTask?.cancel()

        switch source {
        case .entry:
            lineupTransitionTeams = nil
            lineupCoverPresentation = source

        case .card(let side):
            lineupTransitionTeams = resolvedLineup
            lineupCardExpanded = false
            lineupBackdropVisible = false
            lineupDetailsVisible = false
            lineupCardSettled = false
            lineupCardIsClosing = false
            // Install an invisible destination first. Its measured geometry
            // starts the hand-off once SwiftUI has actually laid it out.
            lineupCardPresentation = side
        }
    }

    /// `onGeometryChange` in the destination calls this only after its card
    /// has a real frame. That makes the first matched frame deterministic even
    /// when a device misses a display refresh under load.
    private func startLineupCardTransition(for side: LineupSide) {
        guard lineupCardPresentation == side,
              !lineupCardExpanded,
              !lineupCardIsClosing else { return }

        lineupTransitionTask?.cancel()

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                lineupCardExpanded = true
                lineupBackdropVisible = true
                lineupDetailsVisible = true
            }
            lineupTransitionTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(190))
                guard !Task.isCancelled,
                      lineupCardPresentation == side,
                      !lineupCardIsClosing else { return }
                lineupCardSettled = true
            }
            return
        }

        // A fixed timing curve keeps the card's travel direct and predictable:
        // no overshoot, damping, or second settling beat at either endpoint.
        withAnimation(.easeInOut(duration: 0.32)) {
            lineupCardExpanded = true
        }
        // The old page falls away on its own curve. An ease-in starts almost
        // clear, keeping the selected card sharp at hand-off, then reaches a
        // full fade over the destination's already-soft art at about 220 ms.
        withAnimation(.easeIn(duration: 0.22)) {
            lineupBackdropVisible = true
        }

        lineupTransitionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  lineupCardPresentation == side,
                  !lineupCardIsClosing else { return }
            withAnimation(.easeOut(duration: 0.20)) {
                lineupDetailsVisible = true
            }

            // The header can be visible during the last part of the flight, but
            // it must not swap teams underneath the moving hero.
            try? await Task.sleep(for: .milliseconds(170))
            guard !Task.isCancelled,
                  lineupCardPresentation == side,
                  !lineupCardIsClosing else { return }
            lineupCardSettled = true
        }
    }

    /// The list begins softening on the same frame as the card returns.
    private func closeLineupCard() {
        guard let side = lineupCardPresentation, !lineupCardIsClosing else { return }
        lineupTransitionTask?.cancel()
        lineupCardIsClosing = true
        lineupCardSettled = false

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                lineupDetailsVisible = false
                lineupCardExpanded = false
                lineupBackdropVisible = false
            }
        } else {
            withAnimation(.easeIn(duration: 0.14)) {
                lineupDetailsVisible = false
            }
            withAnimation(.easeInOut(duration: 0.28)) {
                lineupCardExpanded = false
            }
            withAnimation(.easeOut(duration: 0.20)) {
                lineupBackdropVisible = false
            }
        }

        // Keep the transparent page alive until the returning card has reached
        // the source exactly; removing it earlier exposes the folded anchor.
        lineupTransitionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 190 : 300))
            guard !Task.isCancelled,
                  lineupCardPresentation == side,
                  !lineupCardExpanded else { return }
            lineupCardPresentation = nil
            lineupTransitionTeams = nil
            lineupCardIsClosing = false
        }
    }

    private var buildLineupButton: some View {
        Button {
            openLineup(from: .entry)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shuffle")
                    .font(.system(size: 15, weight: .semibold))
                Text("قسّم الفريقين")
                    .font(TamrinFont.font(size: 15, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 14)
            .tamrinGlassCard()
            .contentShape(.rect)
        }
        .buttonStyle(SpringCardPressStyle())
        .matchedTransitionSource(id: LineupZoomSource.entry, in: lineupZoom)
        .accessibilityLabel("قسّم الفريقين")
        .accessibilityHint("يفتح صفحة التشكيلة لتقسيم المسجلين على فريقين")
    }

    private func declineReasonDisplay(for response: EventMemberResponseRecord) -> String {
        let customReason = response.reasonText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let customReason, !customReason.isEmpty { return customReason }

        switch response.reasonCode {
        case "traveling": return "مسافر"
        case "tired": return "تعبان"
        case "injured": return "مصاب"
        case "commitment": return "لدي ارتباط"
        case "other": return "أخرى"
        default: return "لم يُذكر سبب"
        }
    }

    @ViewBuilder
    private var rosterRows: some View {
        if seatedRoster.isEmpty, reserveRoster.isEmpty {
            Text("كن أول المسجلين.")
                .font(TamrinFont.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .tamrinGlassCard()
        } else {
            // Tighter than the 14 the page uses between its sections, so the
            // roster reads as one block of names rather than separate cards —
            // while the manual-registration row above keeps that wider gap and
            // stays visibly apart from the people.
            VStack(spacing: 8) {
                ForEach(seatedRoster) { person in
                    rosterRow(for: person)
                }
            }

            // The reserve list is its own list. Someone waiting for a seat is
            // not in the exercise yet, and mixing them into the roster made the
            // count read as larger than it is.
            if !reserveRoster.isEmpty {
                Text("الاحتياط")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 14)
                    .padding(.horizontal, 4)

                VStack(spacing: 8) {
                    ForEach(reserveRoster) { person in
                        rosterRow(for: person)
                    }
                }
            }
        }
    }

    /// The people holding a seat, and the people waiting for one.
    private var seatedRoster: [FeedMember] { roster.filter { $0.status != .waitlisted } }
    private var reserveRoster: [FeedMember] { roster.filter { $0.status == .waitlisted } }

    /// The colour money wears in this app, on both ends of the transfer.
    static let moneyGreen = Color(red: 0.15, green: 0.56, blue: 0.38)

    private func rosterRow(for person: FeedMember) -> some View {
        let isReviewing = showsPaymentReview(for: person)
        return VStack(spacing: 0) {
            MemberRowCard(
                name: person.name,
                subtitle: rosterSubtitle(for: person),
                avatarImageData: avatarData(for: person),
                avatarImageUrl: person.avatarUrl,
                // One card, not two stacked: the question belongs to this row.
                drawsCard: !isReviewing
            ) {
                HStack(spacing: 6) {
                    rosterStatusAccessory(for: person)
                    if feed.isCurrentTeamOwner {
                        rosterMenu(for: person)
                    }
                }
            }

            // A declared transfer is a question put to the organizer, so the
            // card grows to ask it in words rather than leaving two glyphs to
            // carry the decision.
            if isReviewing {
                paymentReviewPanel(for: person)
            }
        }
        .modifier(RosterCardBackground(isOn: isReviewing))
        .animation(.snappy(duration: 0.34, extraBounce: 0.08), value: person.status)
        .animation(.snappy(duration: 0.28), value: paymentActionInFlight)
        // A tap gesture rather than a Button: the card holds its own menu, and
        // a button inside a button swallows it. While the card is asking about
        // a payment it stops being one big target — the two answers are.
        .contentShape(.rect)
        .onTapGesture { if !isReviewing { memberInDetails = person } }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("يفتح تفاصيل اللاعب وتقييمه")
        .accessibilityAction { memberInDetails = person }
    }

    /// Only the states that need acting on carry a mark. A confirmed seat is
    /// the norm on this list, so it shows nothing — being in the list is
    /// already what says it.
    @ViewBuilder
    private func rosterStatusAccessory(for person: FeedMember) -> some View {
        if person.status == .waitlisted {
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
        } else if person.status == .paymentPending, !feed.isCurrentTeamOwner {
            Image(systemName: "hourglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityLabel("بانتظار تأكيد وصول القطة")
        }
    }

    /// One follow-up payment may contain several guest rows. Show a single
    /// confirm/reject control for their shared registrar instead of repeating
    /// the same destructive action on every name.
    private func isPrimaryPendingPaymentRow(_ member: FeedMember) -> Bool {
        guard let ownerID = member.paymentOwnerId else { return false }
        let pendingRows = roster.filter {
            $0.status == .paymentPending && $0.paymentOwnerId == ownerID
        }
        let primaryRow = pendingRows.first { $0.userId == ownerID }
            ?? pendingRows.first
        return primaryRow?.id == member.id
    }

    /// Manual registration is a real seat, so it follows the same rules as a
    /// member's own: the exercise must be live and its list still open.
    private var canRegisterManually: Bool {
        feed.isCurrentTeamOwner
            && occurrence.isPublished
            && !occurrence.isCancelled
            && !isHistorical
    }

    private func showReminderToast(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            reminderToast = message
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            guard reminderToast == message else { return }
            withAnimation(.easeOut(duration: 0.2)) { reminderToast = nil }
        }
    }

    /// Directions need somewhere to go: a pin, or failing that a place name a
    /// maps app can search for.
    private var hasDirections: Bool {
        (occurrence.latitude != nil && occurrence.longitude != nil) || !venueName.isEmpty
    }

    // MARK: - Share

    /// What this tile hands out is the way into the exercise, not the date in
    /// front of it. That belongs to the exercise, so publishing the date has no
    /// say in it and the tile is there every time an organizer opens the page.
    private var teamInvite: FeedTeam? {
        guard feed.isCurrentTeamOwner, let team = feed.currentTeam else { return nil }
        return team.inviteURL == nil && team.inviteCode.isEmpty ? nil : team
    }

    /// Inviting into the exercise is an organizer's act: members open dates,
    /// they don't hand out the door to the exercise itself.
    private var canShareJoinLink: Bool {
        teamInvite != nil
    }

    @ViewBuilder
    private var shareButton: some View {
        if let team = teamInvite {
            ShareLink(
                item: teamInviteItem(team),
                subject: Text("انضم إلى \(team.name)"),
                message: Text(teamInviteMessage(team))
            ) {
                EventActionTile(symbol: "square.and.arrow.up.fill", title: "مشاركة")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("مشاركة رابط الانضمام للتمرين")
        }
    }

    /// Share stays available before the backend has issued a join URL — the
    /// invite code alone is enough to join.
    private func teamInviteItem(_ team: FeedTeam) -> String {
        team.inviteURL?.absoluteString ?? team.inviteCode
    }

    private func teamInviteMessage(_ team: FeedTeam) -> String {
        team.inviteURL == nil
            ? "انضم لتمريننا برمز الدعوة: \(team.inviteCode)"
            : "هذا رابط الانضمام لتمريننا"
    }

    /// A plain menu, not a popover: the choice is two labelled destinations,
    /// which is exactly what the platform's own dropdown is for.
    private var directionsButton: some View {
        Menu {
            // Each row carries the app's own mark rather than a generic
            // symbol — a menu of destinations reads as the apps themselves.
            // The catalogue images are template-rendered, so the menu tints
            // them like any system glyph.
            Button {
                openDirections(.hudhud)
            } label: {
                Label { Text("هدهد") } icon: { Image("MapAppHudhud") }
            }

            Button {
                openDirections(.googleMaps)
            } label: {
                Label { Text("خرائط قوقل") } icon: { Image("MapAppGoogleMaps") }
            }
        } label: {
            // A full-width row rather than a tile, and read like a list row
            // rather than a centred button: the venue sits on the leading edge
            // with its mark, and a chevron on the far side says it opens
            // something. `chevron.forward` so it follows the language's
            // direction instead of always pointing right.
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text(directionsTitle)
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 8)

                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 16)
            .tamrinGlassCard()
            .contentShape(.rect)
        }
        .accessibilityLabel(venueName.isEmpty ? "الاتجاهات" : "الاتجاهات إلى \(venueName)")
        .accessibilityHint("يفتح قائمة تطبيقات الخرائط")
    }

    private var venueName: String {
        occurrence.locationName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The venue names itself when it can; otherwise the action does.
    private var directionsTitle: String {
        venueName.isEmpty ? "الاتجاهات" : venueName
    }

    private func openDirections(_ provider: EventDirectionsProvider) {
        let destination = EventDirectionsDestination(
            latitude: occurrence.latitude,
            longitude: occurrence.longitude,
            name: occurrence.locationName
        )
        guard let url = provider.url(for: destination) else { return }
        Haptics.impact(.light)
        UIApplication.shared.open(url)
    }

    /// A reminder is only meaningful once the exercise is out and still live.
    private var canRemindMembers: Bool {
        feed.isCurrentTeamOwner
            && occurrence.isPublished
            && !occurrence.isCancelled
            && !isHistorical
    }

    private var remindMembersButton: some View {
        Button {
            showMemberReminder = true
        } label: {
            EventActionTile(symbol: "bell.badge.fill", title: "إشعار الأعضاء")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("إشعار الأعضاء")
        .accessibilityHint("يفتح خيارات تذكير الأعضاء بالتسجيل أو بدفع القطة")
    }

    private var manualAddButton: some View {
        Button {
            showManualAdd = true
        } label: {
            // Centred label with a bare plus beside it: this row is an action,
            // not a person, so it deliberately drops the avatar column the
            // member cards above it line up on.
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                Text("تسجيل لاعب يدويًا")
                    .font(TamrinFont.font(size: 15, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 14)
            .tamrinGlassCard()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("تسجيل لاعب يدويًا")
    }

    @ViewBuilder
    private func rosterMenu(for member: FeedMember) -> some View {
        if removalInFlight == member.id {
            ProgressView()
                .tint(.white)
                .frame(width: TamrinControlMetrics.touchTarget, height: TamrinControlMetrics.touchTarget)
        } else {
            Menu {
                Button("تفاصيل اللاعب", systemImage: "info.circle") {
                    memberInDetails = member
                }
                if !isHistorical {
                    Button("إزالة اللاعب من التمرين", systemImage: "person.badge.minus", role: .destructive) {
                        memberAwaitingRemoval = member
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(
                        width: TamrinControlMetrics.touchTarget,
                        height: TamrinControlMetrics.touchTarget
                    )
                    .contentShape(.rect)
            }
            .accessibilityLabel("خيارات \(member.name)")
        }
    }

    private func removeParticipant(_ member: FeedMember) {
        guard removalInFlight == nil else { return }
        removalInFlight = member.id
        Task {
            let outcome = await feed.removeParticipant(member, from: occurrence)
            removalInFlight = nil
            switch outcome {
            case .success:
                Haptics.success()
            case .failure(let message):
                actionErrorMessage = message
                Haptics.error()
            }
        }
    }

    /// Only the organizer decides, once per payer — a follow-up request can
    /// carry several guest rows that share one transfer.
    private func showsPaymentReview(for member: FeedMember) -> Bool {
        !isHistorical
            && feed.isCurrentTeamOwner
            && member.status == .paymentPending
            && isPrimaryPendingPaymentRow(member)
    }

    /// The question and its two answers, filling the card's width.
    private func paymentReviewPanel(for member: FeedMember) -> some View {
        VStack(spacing: 10) {
            Text("هل وصلتك قطة «\(member.name.firstNameOnly)»؟")
                .font(TamrinFont.font(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if paymentActionInFlight == member.paymentOwnerId {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, minHeight: 34)
            } else {
                HStack(spacing: 10) {
                    paymentAnswerButton(
                        title: "وصلت",
                        isAffirmative: true
                    ) { confirmPayment(member) }
                    .accessibilityLabel("تأكيد وصول قطة \(member.name)")

                    paymentAnswerButton(
                        title: "باقي",
                        isAffirmative: false
                    ) { memberAwaitingRejection = member }
                    .accessibilityLabel("قطة \(member.name) لم تصل بعد")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    /// The system's own glass capsules, the same pair of styles every other
    /// decision in the app is offered with.
    @ViewBuilder
    private func paymentAnswerButton(
        title: String,
        isAffirmative: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let label = Text(title)
            .font(TamrinFont.font(size: 14, weight: .bold))
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .contentShape(.capsule)

        if isAffirmative {
            Button(action: action) { label.foregroundStyle(.white) }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .tint(Self.moneyGreen)
        } else {
            Button(action: action) { label.foregroundStyle(.white) }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        }
    }

    private func paymentReviewActions(for member: FeedMember) -> some View {
        HStack(spacing: 6) {
            if paymentActionInFlight == member.paymentOwnerId {
                ProgressView()
                    .tint(.white)
                    .frame(width: TamrinControlMetrics.touchTarget, height: TamrinControlMetrics.touchTarget)
            } else {
                Button {
                    confirmPayment(member)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(TamrinTheme.ink)
                        .frame(width: 36, height: 36)
                        .background(TamrinTheme.lime, in: .circle)
                        .frame(minWidth: TamrinControlMetrics.touchTarget, minHeight: TamrinControlMetrics.touchTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("تأكيد دفعة \(member.name)")

                Button {
                    memberAwaitingRejection = member
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                        .background(.red.opacity(0.14), in: .circle)
                        .frame(minWidth: TamrinControlMetrics.touchTarget, minHeight: TamrinControlMetrics.touchTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("رفض دفعة \(member.name)")
            }
        }
    }

    private func confirmPayment(_ member: FeedMember) {
        guard let joinerId = member.paymentOwnerId, paymentActionInFlight == nil else { return }
        paymentActionInFlight = joinerId
        Task {
            let outcome = await feed.confirmPayment(for: member, in: occurrence)
            withAnimation(.snappy(duration: 0.34, extraBounce: 0.08)) {
                paymentActionInFlight = nil
            }
            switch outcome {
            case .success:
                Haptics.success()
            case .failure(let message):
                actionErrorMessage = message
                Haptics.error()
            }
        }
    }

    private func rejectPayment(_ member: FeedMember) {
        guard let joinerId = member.paymentOwnerId, paymentActionInFlight == nil else { return }
        paymentActionInFlight = joinerId
        Task {
            let outcome = await feed.rejectPayment(for: member, in: occurrence)
            paymentActionInFlight = nil
            switch outcome {
            case .success:
                Haptics.success()
            case .failure(let message):
                actionErrorMessage = message
                Haptics.error()
            }
        }
    }
}

/// Who apologised and why, on its own page: a full-screen cover that rises from
/// the bottom over the blurred, dimmed exercise artwork. The bar is a centred
/// title with a single light circular Done button on the far side, and each
/// person is one wide, softly rounded card — name over reason, avatar leading.
private struct DeclinedResponsesPage: View {
    let responses: [EventMemberResponseRecord]
    let reasonDisplay: (EventMemberResponseRecord) -> String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader

                VStack(spacing: 8) {
                    ForEach(responses) { response in
                        row(for: response)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top) { topBar }
        .environment(\.layoutDirection, .rightToLeft)
        .colorScheme(.dark)
    }

    private var topBar: some View {
        ZStack {
            Text("المعتذرون")
                .font(TamrinFont.font(size: 17, weight: .bold))
                .foregroundStyle(.white)

            HStack {
                Spacer(minLength: 0)

                Button {
                    dismiss()
                } label: {
                    Label("إغلاق", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(
                            width: TamrinControlMetrics.glassIconContent,
                            height: TamrinControlMetrics.glassIconContent
                        )
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .accessibilityLabel("إغلاق")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Text("اعتذروا")
                .font(TamrinFont.font(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))

            Spacer(minLength: 0)

            Text("الإجمالي: \(responses.count.formatted())")
                .font(TamrinFont.font(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 4)
    }

    private func row(for response: EventMemberResponseRecord) -> some View {
        MemberRowCard(
            name: response.displayName,
            subtitle: reasonDisplay(response),
            avatarImageUrl: response.avatarUrl
        )
        .accessibilityElement(children: .combine)
    }
}

/// Player registration and manual-payment flow. Payment is intentionally
/// submitted only after the player reviews the destination and confirms from
/// the detail step.
struct RegistrationFlowSheet: View {
    enum Mode: String, Identifiable {
        case selfAndGuests
        case additionalGuests
        case guestOnly

        var id: String { rawValue }
    }

    @Bindable var feed: HomeStore
    let occurrence: FeedOccurrence
    var artName: String = "ExerciseArt1"
    var mode: Mode = .selfAndGuests
    var reviewOnly = false
    var onSuccessDismiss: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step
    @State private var guestNames: [String] = []
    @State private var showGuestSection = false
    /// Whether the member has claimed a seat for themselves. Starts off, so
    /// registering is a deliberate tap on your own card rather than something
    /// that already happened when the sheet opened.
    @State private var includesSelf = false
    /// Set when the member chooses to bring guests without taking a seat: the
    /// request reserves no seat for them and charges them nothing.
    @State private var guestsWithoutSelf = false
    @State private var destination: PaymentDestination?
    @State private var isLoadingDestination = false
    @State private var submitting = false
    @State private var failureMessage: String?
    @State private var copiedMessage: String?
    @FocusState private var focusedGuest: Int?

    private enum Step: Hashable {
        case selection
        case paymentMethod
        case details
        case success
    }

    init(
        feed: HomeStore,
        occurrence: FeedOccurrence,
        artName: String = "ExerciseArt1",
        mode: Mode = .selfAndGuests,
        reviewOnly: Bool = false,
        onSuccessDismiss: (() -> Void)? = nil
    ) {
        self.feed = feed
        self.occurrence = occurrence
        self.artName = artName
        self.mode = mode
        self.reviewOnly = reviewOnly
        self.onSuccessDismiss = onSuccessDismiss
        _step = State(initialValue: reviewOnly ? .paymentMethod : .selection)
        _guestNames = State(initialValue: mode == .selfAndGuests ? [] : [""])
        _showGuestSection = State(initialValue: mode != .selfAndGuests)
    }

    /// The flow's accent, shared by the submit button and the seat marker so
    /// the thing you tick and the thing it enables are visibly one action.
    private static let accent = Color(red: 0.20, green: 0.47, blue: 0.96)

    private var isGuestRequest: Bool { mode != .selfAndGuests || guestsWithoutSelf }
    private var registersWithoutSelf: Bool { mode == .guestOnly || guestsWithoutSelf }

    /// The member's own card is only a choice on the plain registration; the
    /// guest-only entries arrive with that decision already made.
    private var offersSelfSeat: Bool { mode == .selfAndGuests }

    /// Nothing can be submitted until the request has someone in it: either a
    /// seat for the member, or at least one named guest.
    private var canContinue: Bool {
        if offersSelfSeat && !guestsWithoutSelf { return includesSelf }
        return !validGuests.isEmpty
    }


    private var memberSummaryTitle: String {
        switch mode {
        case .selfAndGuests:
            feed.profileName.isEmpty ? "أنا" : feed.profileName
        case .additionalGuests:
            "تسجيلك محفوظ مسبقًا"
        case .guestOnly:
            "لن تُسجَّل أنت"
        }
    }

    private var memberSummarySubtitle: String {
        switch mode {
        case .selfAndGuests: "اللاعب الأساسي"
        case .additionalGuests: "الطلب الجديد للضيوف فقط"
        case .guestOnly: "المقاعد والمبلغ للضيوف فقط"
        }
    }

    private var memberSummaryIcon: String {
        registersWithoutSelf ? "minus.circle.fill" : "checkmark.circle.fill"
    }

    private var memberSummaryTint: Color {
        registersWithoutSelf ? .white.opacity(0.58) : TamrinTheme.lime
    }

    private var memberSummaryBackground: Color {
        registersWithoutSelf
            ? Color(red: 0.20, green: 0.47, blue: 0.96).opacity(0.14)
            : TamrinTheme.lime.opacity(0.2)
    }

    private var memberSummaryAccessibilityLabel: String {
        switch mode {
        case .selfAndGuests:
            "\(feed.profileName.isEmpty ? "أنا" : feed.profileName)، اللاعب الأساسي، مشمول"
        case .additionalGuests:
            "تسجيلك محفوظ، ولن تُحسب ضمن الطلب الجديد"
        case .guestOnly:
            "لن تُسجّل أنت، والمقاعد والمبلغ للضيوف فقط"
        }
    }

    private var validGuests: [String] {
        guestNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A follow-up guest request never charges for the already-seated member.
    private var groupSize: Int { (isGuestRequest ? 0 : 1) + validGuests.count }

    private var displayedGroupSize: Int {
        reviewOnly ? max(1, destination?.groupSize ?? 1) : groupSize
    }

    private var payableAmount: Double {
        let price = destination?.pricePerPerson ?? occurrence.price
        return max(0, price) * Double(groupSize)
    }

    /// Review mode uses the immutable amount and group size captured when the
    /// player submitted, not whatever the organizer may configure later.
    private var displayedAmount: Double {
        guard reviewOnly else { return payableAmount }
        return max(0, destination?.pricePerPerson ?? occurrence.price) * Double(displayedGroupSize)
    }

    /// A pending payer has an immutable destination snapshot. A previously
    /// registered player opening the T-40 contribution entry point does not,
    /// so that player is browsing the organizer's current choices instead.
    private var isSubmittedPaymentReview: Bool {
        reviewOnly && destination?.selectedMethod != nil
    }

    /// Title for the step currently on screen — shown by the navigation bar
    /// rather than a hand-drawn header row.
    private var stepTitle: String {
        switch step {
        case .selection: isGuestRequest ? "سجّل ضيوفك" : "سجّل في الموعد"
        case .paymentMethod: reviewOnly ? "وسيلة الدفع" : "وسائل الدفع"
        case .details: "تفاصيل الدفع"
        case .success: "تم"
        }
    }

    /// Where the bar's leading button goes back to, or nil when it should
    /// close the sheet instead.
    private var backStep: Step? {
        switch step {
        case .selection, .success: nil
        case .paymentMethod: reviewOnly ? nil : .selection
        case .details: .paymentMethod
        }
    }

    /// The home-indicator strip `fittedSheet` adds to every sheet's height. It
    /// is cancelled below so the submit button's bottom margin is the one this
    /// sheet sets, not that strip plus it.
    private var bottomSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.safeAreaInsets.bottom ?? 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Every step lays out at its natural height, so the sheet can
                // stop exactly there instead of at a guessed screen fraction.
                Group {
                    switch step {
                    case .selection:
                        selectionStep
                    case .paymentMethod:
                        paymentMethodStep
                    case .details:
                        detailsStep
                    case .success:
                        successStep
                    }
                }
                .sheetContentHeight()
            }
            .scrollBounceBehavior(.basedOnSize)
            // The content may reach the screen's bottom edge; its own padding
            // is what keeps the last control clear of it. The scroll view also
            // reserves the safe area as a content margin, which is a second
            // helping of the same strip — hence both lines.
            .ignoresSafeArea(.container, edges: .bottom)
            .contentMargins(.bottom, 0, for: .scrollContent)
            .navigationTitle(stepTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if let backStep {
                        Button("رجوع", systemImage: "chevron.backward") {
                            withAnimation(.smooth(duration: 0.3)) { step = backStep }
                        }
                    } else {
                        Button("إغلاق", systemImage: "xmark") { dismiss() }
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: step)
        .overlay(alignment: .top) {
            if let copiedMessage {
                Label(copiedMessage, systemImage: "checkmark.circle.fill")
                    .font(TamrinFont.font(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(TamrinTheme.floatingChrome.opacity(0.92), in: .capsule)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .preferredColorScheme(.dark)
        .fittedSheet(
            minHeight: 300,
            includesNavigationBar: true,
            background: TamrinTheme.sheet,
            extraHeight: -bottomSafeInset
        )
        .task {
            if reviewOnly, destination == nil {
                await loadDestination()
            }
        }
        .alert("تعذر إكمال العملية", isPresented: Binding(
            get: { failureMessage != nil },
            set: { if !$0 { failureMessage = nil } }
        )) {
            Button("حسنًا", role: .cancel) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
                .font(TamrinFont.body)
        }
    }

    private var selectionStep: some View {
        VStack(spacing: 0) {
            Group {
                VStack(spacing: 12) {
                    // The member's own row, drawn as the app's member card so
                    // it is the same object here as on the roster. The circle
                    // on the far side is the seat: empty until it is claimed.
                    if offersSelfSeat {
                        Button {
                            Haptics.selection()
                            includesSelf.toggle()
                            if includesSelf { guestsWithoutSelf = false }
                        } label: {
                            MemberRowCard(
                                name: feed.profileName.isEmpty ? "أنا" : feed.profileName,
                                subtitle: includesSelf ? "اللاعب الأساسي" : "اضغط لتحجز مقعدك",
                                avatarImageData: feed.avatarData,
                                avatarImageUrl: feed.avatarUrl
                            ) {
                                // Palette rendering both ways, so one image can
                                // morph into the other: layer one is the ring
                                // or the tick, layer two the disc behind it.
                                Image(systemName: includesSelf ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22, weight: .semibold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(
                                        includesSelf ? Color.white : Color.white.opacity(0.3),
                                        includesSelf ? Self.accent : Color.clear
                                    )
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(includesSelf ? .isSelected : [])
                        .accessibilityHint(includesSelf ? "يلغي حجز مقعدك" : "يحجز مقعدك في الموعد")
                    } else {
                        MemberRowCard(
                            name: memberSummaryTitle,
                            subtitle: memberSummarySubtitle,
                            avatarImageData: feed.avatarData,
                            avatarImageUrl: feed.avatarUrl
                        ) {
                            Image(systemName: memberSummaryIcon)
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(memberSummaryTint)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(memberSummaryAccessibilityLabel)
                    }

                    if showGuestSection || isGuestRequest {
                        VStack(spacing: 9) {
                            ForEach(guestNames.indices, id: \.self) { index in
                                HStack(spacing: 8) {
                                    TextField("اسم اللاعب الإضافي", text: $guestNames[index])
                                        .font(TamrinFont.font(size: 15, weight: .medium))
                                        .foregroundStyle(.white)
                                        .focused($focusedGuest, equals: index)
                                        .padding(.horizontal, 14)
                                        .frame(height: 48)
                                        // A text field, not a card: it keeps the
                                        // app's capsule input shape.
                                        .background(.white.opacity(0.08), in: .capsule)

                                    Button {
                                        guestNames.remove(at: index)
                                        if guestNames.isEmpty {
                                            showGuestSection = false
                                            guestsWithoutSelf = false
                                        }
                                    } label: {
                                        Image(systemName: "minus")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.red)
                                            .frame(width: 40, height: 40)
                                            .background(.red.opacity(0.12), in: .circle)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("حذف اللاعب")
                                }
                            }

                            Button {
                                guestNames.append("")
                                focusedGuest = guestNames.count - 1
                            } label: {
                                Label("إضافة لاعب آخر", systemImage: "plus")
                                    .font(TamrinFont.font(size: 14, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 42)
                                    .background(.white.opacity(0.07), in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        // One button, two meanings: with a seat claimed it adds
                        // people alongside you, without one it registers them
                        // instead of you.
                        // Same glass row as «تسجيل لاعب يدويًا» on the event
                        // page: this is the app's secondary action shape.
                        Button {
                            showGuestSection = true
                            guestsWithoutSelf = !includesSelf
                            guestNames = [""]
                            focusedGuest = 0
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "person.badge.plus")
                                    .font(.system(size: 15, weight: .semibold))
                                    .contentTransition(.symbolEffect(.replace))
                                Text(includesSelf ? "بسجل معي أحد" : "سجّل ضيف بدونك")
                                    .font(TamrinFont.font(size: 15, weight: .medium))
                                    .contentTransition(.interpolate)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .padding(.horizontal, 14)
                            .tamrinGlassCard()
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
                .animation(.smooth(duration: 0.32, extraBounce: 0.08), value: includesSelf)
            }

            // Registering is the whole of this sheet now, paid or free: the
            // seat is taken here and the money is settled later from «دفع
            // القطة», which is the only thing that opens the payment steps.
            primaryButton(
                title: "تسجيل",
                color: Self.accent,
                isLoading: submitting,
                isEnabled: canContinue && !submitting
            ) {
                focusedGuest = nil
                register()
            }
        }
    }

    /// Takes the seat. The destination is still loaded first because the
    /// preview and fixture paths read the price from it; the server call it
    /// ends in does not ask for a payment method at all.
    private func register() {
        guard !submitting else { return }
        submitting = true
        Task {
            await loadDestination()
            submitting = false
            guard destination != nil else { return }
            submitRegistration()
        }
    }

    private var paymentMethodStep: some View {
        VStack(spacing: 0) {
            if isLoadingDestination {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("جاري تحميل وسائل الدفع")
                        .font(TamrinFont.font(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 64)
            } else if let destination {
                Group {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(
                            isSubmittedPaymentReview
                                ? "راجع الوسيلة التي حوّلت إليها"
                                : (reviewOnly
                                    ? "اختر وسيلة الدفع لعرض بياناتها"
                                    : "اختر وسيلة الدفع المناسبة لك")
                        )
                            .font(TamrinFont.font(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if destination.status == .free
                            || destination.availablePaymentMethods.isEmpty
                            || (reviewOnly && destination.selectedMethod != nil) {
                            snapshotDestinationRow(destination)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(destination.availablePaymentMethods) { method in
                                    availablePaymentMethodRow(method, in: destination)
                                }
                            }
                        }

                        if destination.status != .free {
                            HStack {
                                Text(isSubmittedPaymentReview ? "المبلغ المسجل" : "المبلغ المطلوب")
                                    .font(TamrinFont.font(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.55))
                                Spacer()
                                Text(currency(displayedAmount))
                                    .font(TamrinFont.font(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .padding(15)
                            .tamrinGlassCard()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            } else {
                Text("تعذر تحميل وسيلة الدفع")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 64)
            }
        }
    }

    private var detailsStep: some View {
        VStack(spacing: 0) {
            if let destination {
                Group {
                    VStack(spacing: 12) {
                        destinationLogo(destination, size: 66)

                        Text(destinationTitle(destination))
                            .font(TamrinFont.font(size: 20, weight: .bold))
                            .foregroundStyle(.white)

                        if destination.status == .free {
                            Text("هذا الموعد بدون رسوم")
                                .font(TamrinFont.font(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(0.62))
                        } else {
                            Text(currency(displayedAmount))
                                .font(TamrinFont.font(size: 27, weight: .bold))
                                .foregroundStyle(.white)
                            if displayedGroupSize > 1 {
                                Text("لعدد \(displayedGroupSize.counted(.player))")
                                    .font(TamrinFont.font(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.48))
                            }
                        }

                        destinationFields(destination)

                        if let provider = destination.provider,
                           !provider.isCash,
                           let openAppTitle = provider.openAppTitle {
                            Button { } label: {
                                HStack(spacing: 10) {
                                    Text(openAppTitle)
                                        .font(TamrinFont.font(size: 15, weight: .bold))
                                    Spacer()
                                    Text("قريبًا")
                                        .font(TamrinFont.font(size: 11, weight: .bold))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(.white.opacity(0.18), in: .capsule)
                                }
                                .foregroundStyle(provider.brandForegroundColor)
                                .padding(.horizontal, 16)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(provider.brandColor, in: .rect(cornerRadius: 17, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(true)
                            .accessibilityLabel("\(openAppTitle)، قريبًا")
                            .accessibilityHint("فتح التطبيق غير متاح حاليًا")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }

                // Review is now the paying step: the seat already exists, and
                // this is where its owner says the money is on its way.
                if reviewOnly {
                    primaryButton(
                        title: destination.provider == .cash
                            ? (occurrence.isPast(relativeTo: .now) ? "سددت للمشرف" : "سأسدد في الملعب")
                            : "حوّلت المبلغ",
                        color: destination.provider?.brandColor ?? Self.accent,
                        isLoading: submitting,
                        isEnabled: !submitting && destination.selectedMethod != nil
                    ) {
                        guard let method = destination.selectedMethod else { return }
                        declarePayment(using: method)
                    }
                } else {
                    primaryButton(
                        title: destination.status == .free
                            ? (isGuestRequest ? "تأكيد الضيوف" : "تأكيد التسجيل")
                            : (destination.provider == .cash ? "سأسدد في الملعب" : "حوّلت المبلغ"),
                        color: destination.provider?.brandColor ?? Self.accent,
                        isLoading: submitting,
                        isEnabled: !submitting
                    ) {
                        submitRegistration()
                    }
                }
            }
        }
    }

    private var successStep: some View {
        VStack(spacing: 14) {
            Color.clear.frame(height: 26)

            ZStack {
                Circle().fill(TamrinTheme.lime)
                Image(systemName: successSymbol)
                    .font(.system(size: 31, weight: .bold))
                    .foregroundStyle(TamrinTheme.ink)
            }
            .frame(width: 76, height: 76)

            Text(successTitle)
                .font(TamrinFont.font(size: 24, weight: .bold))
                .foregroundStyle(.white)

            Text(successSubtitle)
                .font(TamrinFont.font(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            primaryButton(title: "تم", color: .white, foregroundColor: .black) {
                dismiss()
                onSuccessDismiss?()
            }
        }
    }

    private func loadDestination() async {
        guard !isLoadingDestination else { return }
        isLoadingDestination = true
        defer { isLoadingDestination = false }

        do {
            let loaded = try await (isGuestRequest
                ? feed.guestPaymentDestination(for: occurrence)
                : feed.paymentDestination(for: occurrence))
            guard loaded.status != .paymentMethodRequired else {
                failureMessage = "لم يضف المشرف وسيلة دفع لهذا الموعد بعد."
                if !reviewOnly { step = .selection }
                return
            }
            destination = loaded
        } catch {
            failureMessage = error.localizedDescription
            if !reviewOnly { step = .selection }
        }
    }

    /// Registering and paying end on the same screen but are no longer the same
    /// event: a seat is granted outright, while a declared transfer is a claim
    /// the organizer still has to confirm.
    private var declaredPayment: Bool { reviewOnly }

    private var successSymbol: String {
        if declaredPayment {
            return destination?.provider == .cash ? "banknote.fill" : "checkmark"
        }
        return "checkmark"
    }

    private var successTitle: String {
        if declaredPayment { return "سُجّل تحويلك" }
        if isGuestRequest { return "سُجّل ضيوفك" }
        return "أنت في القائمة"
    }

    private var successSubtitle: String {
        if declaredPayment {
            return destination?.provider == .cash
                ? (occurrence.isPast(relativeTo: .now)
                    ? "سُجّل سدادك للمشرف، وينتظر تأكيده"
                    : "تسدد للمشرف في الملعب، وينتظر تأكيده")
                : "طلبك الآن بانتظار تأكيد وصول القطة من المشرف"
        }
        if isGuestRequest { return "أضيف الضيوف إلى قائمة التمرين" }
        return "اسمك مسجل في قائمة التمرين"
    }

    private func declarePayment(using method: PaymentDestinationMethod) {
        guard !submitting else { return }
        submitting = true
        Task {
            let outcome = await feed.declarePayment(for: occurrence, method: method)
            submitting = false
            switch outcome {
            case .success:
                Haptics.success()
                withAnimation { step = .success }
            case .failure(let message):
                Haptics.error()
                failureMessage = message
            }
        }
    }

    private func submitRegistration() {
        guard !submitting, step == .details || step == .selection,
              let destination else { return }
        submitting = true
        Task {
            let outcome = if isGuestRequest {
                await feed.addGuests(
                    validGuests,
                    to: occurrence,
                    expectedDestination: destination,
                    withoutSelf: registersWithoutSelf
                )
            } else {
                await feed.submitRegistration(
                    guests: validGuests,
                    for: occurrence,
                    expectedDestination: destination
                )
            }
            submitting = false
            switch outcome {
            case .success:
                Haptics.success()
                step = .success
            case .failure(let message):
                Haptics.error()
                failureMessage = message
            }
        }
    }

    @ViewBuilder
    private func destinationFields(_ destination: PaymentDestination) -> some View {
        if let provider = destination.provider, provider.requiresMobileNumber,
           let mobileNumber = destination.mobileNumber, !mobileNumber.isEmpty {
            paymentValueRow(
                title: "رقم الجوال",
                displayedValue: STCPay.displayForm(mobileNumber),
                copiedValue: mobileNumber,
                copiedLabel: "نُسخ رقم الجوال"
            )
        } else if let provider = destination.provider, provider.requiresIBAN {
            if let iban = destination.iban, !iban.isEmpty {
                paymentValueRow(
                    title: "IBAN",
                    displayedValue: groupedIBAN(iban),
                    copiedValue: iban.replacingOccurrences(of: " ", with: "").uppercased(),
                    copiedLabel: "نُسخ الآيبان"
                )
            }
            if let accountNumber = destination.accountNumber, !accountNumber.isEmpty {
                paymentValueRow(
                    title: "رقم الحساب",
                    displayedValue: accountNumber,
                    copiedValue: accountNumber,
                    copiedLabel: "نُسخ رقم الحساب"
                )
            }
        } else if destination.provider == .cash {
            Label("ادفع المبلغ للمشرف عند وصولك للملعب", systemImage: "person.crop.circle.badge.checkmark")
                .font(TamrinFont.font(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tamrinGlassCard()
        }
    }

    private func paymentValueRow(
        title: String,
        displayedValue: String,
        copiedValue: String,
        copiedLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(TamrinFont.font(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))

            HStack(spacing: 10) {
                Text(displayedValue)
                    .font(TamrinFont.font(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .environment(\.layoutDirection, .leftToRight)

                Spacer(minLength: 6)

                Button {
                    copy(copiedValue, message: copiedLabel)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("نسخ \(title)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tamrinGlassCard()
    }

    private func primaryButton(
        title: String,
        color: Color,
        foregroundColor: Color = .white,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        // The same glass capsule either way — only its tint changes. Disabled
        // is a barely-there wash that still reads as a button; dropping to the
        // untinted glass style instead made it disappear into the sheet, and
        // keeping the accent at full strength made an unpressable button look
        // pressable.
        TamrinActionButton(
            title: title,
            isLoading: isLoading,
            tint: isEnabled ? color : .white.opacity(0.14),
            labelColor: isEnabled ? foregroundColor : .white.opacity(0.4),
            action: action
        )
            .disabled(!isEnabled)
            .animation(.smooth(duration: 0.25), value: isEnabled)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            // The sheet still reserves ~24pt of home-indicator strip beneath
            // the content, so this is the remainder that brings the gap under
            // the button up to the ~26pt its sides sit at. Measured, not
            // guessed: the two margins are meant to read as identical.
            .padding(.bottom, 3)
    }

    private func availablePaymentMethodRow(
        _ method: PaymentDestinationMethod,
        in loadedDestination: PaymentDestination
    ) -> some View {
        Button {
            Haptics.selection()
            destination = loadedDestination.selecting(method)
            step = .details
        } label: {
            TamrinRowCard(
                title: method.provider.displayName,
                subtitle: paymentMethodSubtitle(method)
            ) {
                PaymentProviderLogo(
                    provider: method.provider,
                    size: TamrinRowCard<EmptyView, EmptyView>.leadingSize
                )
                .accessibilityHidden(true)
            } accessory: {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .contentShape(.rect(cornerRadius: TamrinCard.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(method.provider.displayName)
        .accessibilityHint("عرض بيانات وسيلة الدفع")
    }

    private func snapshotDestinationRow(_ destination: PaymentDestination) -> some View {
        Button {
            Haptics.selection()
            step = .details
        } label: {
            HStack(spacing: 14) {
                destinationLogo(destination)

                VStack(alignment: .leading, spacing: 4) {
                    Text(destinationTitle(destination))
                        .font(TamrinFont.font(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                    Text(destinationSubtitle(destination))
                        .font(TamrinFont.font(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 78)
            .background(
                destination.provider?.brandSurfaceColor ?? .white.opacity(0.1),
                in: .rect(cornerRadius: 22, style: .continuous)
            )
            .contentShape(.rect(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(destinationTitle(destination))
        .accessibilityHint("عرض بيانات وسيلة الدفع")
    }

    private func paymentMethodSubtitle(_ method: PaymentDestinationMethod) -> String {
        switch method.provider.methodType {
        case .cash:
            return "الدفع عند الحضور"
        case .mobileWallet:
            guard let mobile = method.mobileNumber, !mobile.isEmpty else {
                return "تحويل إلى رقم الجوال"
            }
            return "رقم الجوال •••• \(mobile.suffix(4))"
        case .bankAccount:
            guard let iban = method.iban, !iban.isEmpty else { return "تحويل بنكي" }
            return "IBAN •••• \(iban.suffix(4))"
        }
    }

    @ViewBuilder
    private func destinationLogo(_ destination: PaymentDestination, size: CGFloat = 52) -> some View {
        if let provider = destination.provider {
            PaymentProviderLogo(provider: provider, size: size)
                .accessibilityHidden(true)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(TamrinTheme.lime)
                Image(systemName: "gift.fill")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(TamrinTheme.ink)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }

    private func destinationTitle(_ destination: PaymentDestination) -> String {
        destination.provider?.displayName ?? "بدون رسوم"
    }

    private func destinationSubtitle(_ destination: PaymentDestination) -> String {
        guard let provider = destination.provider else { return "التسجيل مجاني" }
        switch provider.methodType {
        case .cash: return "الدفع عند الحضور"
        case .mobileWallet: return "تحويل إلى رقم الجوال"
        case .bankAccount: return "تحويل بنكي"
        }
    }

    private func currency(_ amount: Double) -> String {
        let value = amount.formatted(
            .number
                .locale(.tamrin)
                .precision(.fractionLength(0 ... 2))
        )
        return "\(value) ر.س"
    }

    private func groupedIBAN(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: " ", with: "").uppercased()
        return stride(from: 0, to: compact.count, by: 4).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: min(4, compact.distance(from: start, to: compact.endIndex)))
            return String(compact[start ..< end])
        }.joined(separator: " ")
    }

    private func copy(_ value: String, message: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            copiedMessage = message
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard copiedMessage == message else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                copiedMessage = nil
            }
        }
    }
}

#Preview {
    let feed = HomeStore.preview
    return EventDetailView(feed: feed, occurrence: feed.occurrences[0], artName: "ExerciseArt1")
}


/// One square action above the roster: the symbol on top, the label under it,
/// and an optional badge beside the symbol. Three of these share a row, so the
/// shape is fixed here rather than at each call site.
struct EventActionTile<Badge: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var badge: Badge

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .frame(height: 24)

            HStack(spacing: 6) {
                Text(title)
                    .font(TamrinFont.font(size: 13, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                badge
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 88)
        .tamrinGlassCard()
        .contentShape(.rect)
    }
}

extension EventActionTile where Badge == EmptyView {
    init(symbol: String, title: String) {
        self.init(symbol: symbol, title: title) { EmptyView() }
    }
}


/// Paints the glass card around a roster row that has grown a question, so the
/// row and its answers read as one object.
private struct RosterCardBackground: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.tamrinGlassCard()
        } else {
            content
        }
    }
}
