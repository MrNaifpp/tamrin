import SwiftUI

/// Event detail page — the designer's OccurrenceDetailView (member view) bound
/// to HomeStore, including the manual-payment registration and review flow.
struct EventDetailView: View {
    @Bindable var feed: HomeStore
    let occurrence: FeedOccurrence
    var artName: String = "ExerciseArt1"
    var initiallyShowsRegistration = false
    @Environment(\.dismiss) private var dismiss
    @State private var showWithdrawConfirm = false
    @State private var showRegisterFlow = false
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
    /// Live top edge of the content panel, in screen coordinates. The blurred
    /// artwork is revealed from here down, so the frost follows the panel
    /// through every scroll and every added row.
    @State private var panelTop: CGFloat = .greatestFiniteMagnitude

    private var roster: [FeedMember] { feed.roster(for: occurrence) }
    private var myRegistration: FeedMember? { feed.myRegistration(for: occurrence) }
    private var confirmedCount: Int { feed.registeredCount(for: occurrence) }
    private var waitingCount: Int { feed.waitlistCount(for: occurrence) }
    private var declinedResponses: [EventMemberResponseRecord] {
        feed.declinedResponses(for: occurrence)
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

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    Image(artName)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()

                    // The same artwork, blurred, revealed only where the panel
                    // is. Because both layers are the one photograph, the panel
                    // edge dissolves as a change in focus rather than a veil
                    // laid over the picture — and the mask is measured from the
                    // panel's live position, so the frost travels with it.
                    Image(artName)
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
        .sheet(isPresented: $showPaymentReview) {
            RegistrationFlowSheet(
                feed: feed,
                occurrence: occurrence,
                artName: artName,
                reviewOnly: true
            )
        }
        .task {
            await feed.reloadOccurrence(occurrence.id)
            await feed.reloadRoster(occurrence.id)
            await feed.reloadMemberResponses(occurrence.id)
            guard initiallyShowsRegistration,
                  !handledInitialRegistration,
                  !feed.isCurrentTeamOwner,
                  !occurrence.isCancelled else { return }
            handledInitialRegistration = true
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
            Text("سيُلغى حجز اللاعب وكل الضيوف المسجلين معه وتتحرر مقاعدهم.")
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

    @ViewBuilder
    private var participationCTA: some View {
        if feed.participationState(for: occurrence) == .unavailable {
            Button {
                Task { await feed.reloadRoster(occurrence.id) }
            } label: {
                Label("تعذر التحقق من تسجيلك — حاول مجددًا", systemImage: "arrow.clockwise")
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
                    if mine.status == .registered,
                       occurrence.price > 0,
                       feed.paymentWasRequested(for: occurrence) {
                        Button {
                            Haptics.impact(.light)
                            showPaymentReview = true
                        } label: {
                            Label("دفع القطة", systemImage: "banknote.fill")
                                .font(TamrinFont.font(size: 16, weight: .bold))
                                .foregroundStyle(TamrinTheme.ink)
                                .frame(maxWidth: .infinity)
                                .frame(height: TamrinControlMetrics.glassActionHeight)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.regular)
                        .tint(TamrinTheme.lime)
                        .accessibilityHint("يفتح مبلغ القطة ووسائل الدفع المتاحة")
                    }

                    participationStatusButton(for: mine)
                }
            }
        } else {
            let full = occurrence.capacity > 0 && confirmedCount >= occurrence.capacity
            Button {
                Haptics.impact(.medium)
                showRegisterFlow = true
            } label: {
                Label(full ? "انضم لقائمة الانتظار" : "سجل في التمرين", systemImage: "plus")
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

    private func participationStatusButton(for member: FeedMember) -> some View {
        Button { showWithdrawConfirm = true } label: {
            HStack(spacing: 10) {
                Image(systemName: member.status == .registered ? "checkmark.circle.fill" : "clock.fill")
                    .foregroundStyle(member.status == .registered ? TamrinTheme.lime : .orange)
                Text(member.status == .registered ? "مكانك محفوظ" : "أنت في قائمة الانتظار")
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(member.status == .registered ? "اعتذر" : "انسحب")
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
        if roster.isEmpty {
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
                ForEach(roster) { person in
                    MemberRowCard(
                        name: person.name,
                        subtitle: person.isManual ? "سجّله المشرف" : nil,
                        avatarImageData: avatarData(for: person),
                        avatarImageUrl: person.avatarUrl
                    ) {
                        HStack(spacing: 6) {
                            rosterStatusAccessory(for: person)
                            if feed.isCurrentTeamOwner {
                                rosterMenu(for: person)
                            }
                        }
                    }
                    // A tap gesture rather than a Button: the card holds its own
                    // menu, and a button inside a button swallows it.
                    .contentShape(.rect)
                    .onTapGesture { memberInDetails = person }
                }
            }
        }
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
        } else if person.status == .paymentPending {
            if feed.isCurrentTeamOwner, person.userId != nil {
                paymentReviewActions(for: person)
            } else {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("بانتظار تأكيد الدفع")
            }
        }
    }

    /// Manual registration is a real seat, so it follows the same rules as a
    /// member's own: the exercise must be live and its list still open.
    private var canRegisterManually: Bool {
        feed.isCurrentTeamOwner && occurrence.isPublished && !occurrence.isCancelled
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
        feed.isCurrentTeamOwner && occurrence.isPublished && !occurrence.isCancelled
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
                Button("إزالة اللاعب من التمرين", systemImage: "person.badge.minus", role: .destructive) {
                    memberAwaitingRemoval = member
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

    private func paymentReviewActions(for member: FeedMember) -> some View {
        HStack(spacing: 6) {
            if paymentActionInFlight == member.userId {
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
        guard let joinerId = member.userId, paymentActionInFlight == nil else { return }
        paymentActionInFlight = joinerId
        Task {
            let outcome = await feed.confirmPayment(for: member, in: occurrence)
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

    private func rejectPayment(_ member: FeedMember) {
        guard let joinerId = member.userId, paymentActionInFlight == nil else { return }
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
    @Bindable var feed: HomeStore
    let occurrence: FeedOccurrence
    var artName: String = "ExerciseArt1"
    var reviewOnly = false

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step
    @State private var guestNames: [String] = []
    @State private var showGuestSection = false
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
        reviewOnly: Bool = false
    ) {
        self.feed = feed
        self.occurrence = occurrence
        self.artName = artName
        self.reviewOnly = reviewOnly
        _step = State(initialValue: reviewOnly ? .paymentMethod : .selection)
    }

    private var validGuests: [String] {
        guestNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// submit_payment_v2 always includes the payer, then adds their guests.
    private var groupSize: Int { 1 + validGuests.count }

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
        case .selection: "سجّل في الموعد"
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
            background: TamrinTheme.sheet
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
                    HStack(spacing: 12) {
                        Image(artName)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 68, height: 52)
                            .clipShape(.rect(cornerRadius: 14, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(occurrence.title)
                                .font(TamrinFont.font(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("يوم \(occurrence.startAt.arabicDay)، \(occurrence.startAt.arabicTime)")
                                .font(TamrinFont.font(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                            if occurrence.price > 0 {
                                Text("\(currency(occurrence.price)) للشخص")
                                    .font(TamrinFont.font(size: 12, weight: .bold))
                                    .foregroundStyle(TamrinTheme.lime)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .tamrinGlassCard()

                    HStack(spacing: 12) {
                        MemberAvatar(
                            name: feed.profileName,
                            imageData: feed.avatarData,
                            imageUrl: feed.avatarUrl
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feed.profileName.isEmpty ? "أنا" : feed.profileName)
                                .font(TamrinFont.font(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                            Text("اللاعب الأساسي")
                                .font(TamrinFont.font(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.52))
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(TamrinTheme.lime)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(TamrinTheme.lime.opacity(0.2), in: .rect(cornerRadius: 17, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(feed.profileName.isEmpty ? "أنا" : feed.profileName)، اللاعب الأساسي، مشمول")

                    if showGuestSection {
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
                                        if guestNames.isEmpty { showGuestSection = false }
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
                        Button {
                            showGuestSection = true
                            guestNames = [""]
                            focusedGuest = 0
                        } label: {
                            Label("يسجل معي أحد", systemImage: "person.badge.plus")
                                .font(TamrinFont.font(size: 14, weight: .bold))
                                .foregroundStyle(.white.opacity(0.82))
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(.white.opacity(0.08), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            primaryButton(
                title: occurrence.price > 0 ? "متابعة للدفع" : "متابعة",
                color: Color(red: 0.20, green: 0.47, blue: 0.96),
                isLoading: false
            ) {
                focusedGuest = nil
                withAnimation { step = .paymentMethod }
                Task { await loadDestination() }
            }
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

                if reviewOnly {
                    primaryButton(title: "تم", color: .white, foregroundColor: .black) {
                        dismiss()
                    }
                } else {
                    primaryButton(
                        title: destination.status == .free
                            ? "تأكيد التسجيل"
                            : (destination.provider == .cash ? "سأسدد في الملعب" : "حوّلت المبلغ"),
                        color: destination.provider?.brandColor ?? Color(red: 0.20, green: 0.47, blue: 0.96),
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
                Image(systemName: destination?.provider == .cash ? "banknote.fill" : "checkmark")
                    .font(.system(size: 31, weight: .bold))
                    .foregroundStyle(TamrinTheme.ink)
            }
            .frame(width: 76, height: 76)

            Text(destination?.status == .free || destination?.provider == .cash
                 ? "سُجّلت في الموعد"
                 : "سُجّل تحويلك")
                .font(TamrinFont.font(size: 24, weight: .bold))
                .foregroundStyle(.white)

            Text(destination?.status == .free
                 ? "مكانك محفوظ في الموعد"
                 : (destination?.provider == .cash
                    ? "مكانك محفوظ، وتسدد للمشرف في الملعب"
                    : "طلبك الآن بانتظار تأكيد الدفع من المشرف"))
                .font(TamrinFont.font(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            primaryButton(title: "تم", color: .white, foregroundColor: .black) {
                dismiss()
            }
        }
    }

    private func loadDestination() async {
        guard !isLoadingDestination else { return }
        isLoadingDestination = true
        defer { isLoadingDestination = false }

        do {
            let loaded = try await feed.paymentDestination(for: occurrence)
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

    private func submitRegistration() {
        guard !submitting, step == .details, let destination else { return }
        submitting = true
        Task {
            let outcome = await feed.submitRegistration(
                guests: validGuests,
                for: occurrence,
                expectedDestination: destination
            )
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
        TamrinActionButton(title: title, isLoading: isLoading, tint: color, labelColor: foregroundColor, action: action)
            .disabled(!isEnabled)
            .padding(.horizontal, 20)
            .padding(.top, 4)
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
