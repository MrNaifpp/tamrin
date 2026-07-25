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
    @State private var paymentActionError: String?
    @State private var handledInitialRegistration = false

    private var roster: [FeedMember] { feed.roster(for: occurrence) }
    private var myRegistration: FeedMember? { feed.myRegistration(for: occurrence) }
    private var confirmedCount: Int { feed.registeredCount(for: occurrence) }
    private var waitingCount: Int { feed.waitlistCount(for: occurrence) }
    private var declinedResponses: [EventMemberResponseRecord] {
        feed.declinedResponses(for: occurrence)
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                ZStack {
                    Image(artName)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    Image(artName)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                        .blur(radius: 26, opaque: true)
                        .mask {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.33),
                                .init(color: .black, location: 0.46),
                                .init(color: .black, location: 1)
                            ], startPoint: .top, endPoint: .bottom)
                        }
                }
            }
            .ignoresSafeArea()

            LinearGradient(stops: [
                .init(color: .black.opacity(0.32), location: 0),
                .init(color: .black.opacity(0.06), location: 0.26),
                .init(color: .black.opacity(0.30), location: 0.55),
                .init(color: .black.opacity(0.58), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    heroTitle
                        .padding(.top, 264)
                        .padding(.bottom, 6)

                    if occurrence.isCancelled {
                        cancellationPanel
                    } else if !feed.isCurrentTeamOwner {
                        participationCTA
                    }

                    progressPanel

                    if feed.isCurrentTeamOwner, !declinedResponses.isEmpty {
                        declinedResponsesPanel
                    }

                    Text("القائمة")
                        .font(TamrinFont.font(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.top, 8)
                        .padding(.horizontal, 4)

                    rosterRows
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
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
                UINotificationFeedbackGenerator().notificationOccurred(.success)
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
        .alert("تعذر تحديث الدفعة", isPresented: Binding(
            get: { paymentActionError != nil },
            set: { if !$0 { paymentActionError = nil } }
        )) {
            Button("حسنًا", role: .cancel) { paymentActionError = nil }
        } message: {
            Text(paymentActionError ?? "")
                .font(TamrinFont.body)
        }
    }

    private var heroTitle: some View {
        VStack(spacing: 7) {
            if occurrence.isCancelled {
                Text("تم تخطي هذا الموعد")
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
            .background(.white.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))
        } else {
            Text("تم تخطي تمرين هذا الأسبوع، وتستمر المواعيد القادمة كالمعتاد.")
                .font(TamrinFont.font(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.76))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.white.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))
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
                .background(.white.opacity(0.12), in: .rect(cornerRadius: 20, style: .continuous))
            } else {
                Button { showWithdrawConfirm = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: mine.status == .registered ? "checkmark.circle.fill" : "clock.fill")
                            .foregroundStyle(mine.status == .registered ? TamrinTheme.lime : .orange)
                        Text(mine.status == .registered ? "مكانك محفوظ" : "أنت في قائمة الانتظار")
                            .font(TamrinFont.font(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        Text(mine.status == .registered ? "اعتذر" : "انسحب")
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
                .accessibilityHint("يفتح تأكيد الاعتذار عن التمرين")
            }
        } else {
            let full = occurrence.capacity > 0 && confirmedCount >= occurrence.capacity
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("المسجلون في التمرين")
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
            ProgressView(value: Double(confirmedCount), total: Double(max(occurrence.capacity, 1)))
                .tint(TamrinTheme.lime)
            if waitingCount > 0 {
                Text("\(waitingCount.formatted()) في قائمة الانتظار")
                    .font(TamrinFont.font(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.white.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))
    }

    private var declinedResponsesPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("المعتذرون")
                .font(TamrinFont.font(size: 15, weight: .bold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(declinedResponses) { response in
                    HStack(alignment: .top, spacing: 12) {
                        MemberAvatar(name: response.displayName, size: 32)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(response.displayName)
                                .font(TamrinFont.font(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                            Text(declineReasonDisplay(for: response))
                                .font(TamrinFont.font(size: 13, weight: .regular))
                                .foregroundStyle(.white.opacity(0.66))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))
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
                .background(.white.opacity(0.1), in: .rect(cornerRadius: 16, style: .continuous))
        } else {
            VStack(spacing: 8) {
                ForEach(roster) { person in
                    HStack(spacing: 12) {
                        MemberAvatar(name: person.name)
                        Text(person.name)
                            .font(TamrinFont.font(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
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
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(TamrinTheme.lime)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(.white.opacity(0.1), in: .rect(cornerRadius: 16, style: .continuous))
                }
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
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .failure(let message):
                paymentActionError = message
                UINotificationFeedbackGenerator().notificationOccurred(.error)
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
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .failure(let message):
                paymentActionError = message
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

private struct MemberAvatar: View {
    let name: String
    var size: CGFloat = 34
    var body: some View {
        Circle()
            .fill(.white.opacity(0.28))
            .frame(width: size, height: size)
            .overlay {
                Text(String(name.prefix(1)))
                    .font(TamrinFont.font(size: size * 0.44, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
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

    /// Title for the step currently on screen — shown by the navigation bar
    /// rather than a hand-drawn header row.
    private var stepTitle: String {
        switch step {
        case .selection: "سجّل في التمرين"
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
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 18, style: .continuous))

                    HStack(spacing: 12) {
                        MemberAvatar(name: feed.profileName)
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
                                        .background(.white.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))

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
                        Text(reviewOnly ? "راجع الوسيلة التي حوّلت إليها" : "اختر وسيلة الدفع المناسبة لك")
                            .font(TamrinFont.font(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if reviewOnly || destination.status == .free || destination.availablePaymentMethods.isEmpty {
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
                                Text(reviewOnly ? "المبلغ المسجل" : "المبلغ المطلوب")
                                    .font(TamrinFont.font(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.55))
                                Spacer()
                                Text(currency(displayedAmount))
                                    .font(TamrinFont.font(size: 18, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .padding(15)
                            .background(.white.opacity(0.07), in: .rect(cornerRadius: 18, style: .continuous))
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
                            Text("هذا التمرين بدون رسوم")
                                .font(TamrinFont.font(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(0.62))
                        } else {
                            Text(currency(displayedAmount))
                                .font(TamrinFont.font(size: 27, weight: .bold))
                                .foregroundStyle(.white)
                            if displayedGroupSize > 1 {
                                Text("لعدد \(displayedGroupSize.formatted()) لاعبين")
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
                            : (destination.provider == .cash ? "سأسدد في الملعب" : "تم التحويل"),
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
                 ? "تم تسجيلك"
                 : "تم تسجيل التحويل")
                .font(TamrinFont.font(size: 24, weight: .bold))
                .foregroundStyle(.white)

            Text(destination?.status == .free
                 ? "مكانك محفوظ في التمرين"
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
                failureMessage = "لم يضف المشرف وسيلة دفع لهذا التمرين بعد."
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
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                step = .success
            case .failure(let message):
                UINotificationFeedbackGenerator().notificationOccurred(.error)
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
                copiedLabel: "تم نسخ رقم الجوال"
            )
        } else if let provider = destination.provider, provider.requiresIBAN {
            if let iban = destination.iban, !iban.isEmpty {
                paymentValueRow(
                    title: "IBAN",
                    displayedValue: groupedIBAN(iban),
                    copiedValue: iban.replacingOccurrences(of: " ", with: "").uppercased(),
                    copiedLabel: "تم نسخ الآيبان"
                )
            }
            if let accountNumber = destination.accountNumber, !accountNumber.isEmpty {
                paymentValueRow(
                    title: "رقم الحساب",
                    displayedValue: accountNumber,
                    copiedValue: accountNumber,
                    copiedLabel: "تم نسخ رقم الحساب"
                )
            }
        } else if destination.provider == .cash {
            Label("ادفع المبلغ للمشرف عند وصولك للملعب", systemImage: "person.crop.circle.badge.checkmark")
                .font(TamrinFont.font(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 18, style: .continuous))
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
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 18, style: .continuous))
    }

    private func primaryButton(
        title: String,
        color: Color,
        foregroundColor: Color = .white,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        TamrinActionButton(title: title, isLoading: isLoading, tint: color, action: action)
            .disabled(!isEnabled)
            .padding(.horizontal, 20)
            .padding(.top, 4)
    }

    private func availablePaymentMethodRow(
        _ method: PaymentDestinationMethod,
        in loadedDestination: PaymentDestination
    ) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            destination = loadedDestination.selecting(method)
            step = .details
        } label: {
            HStack(spacing: 14) {
                PaymentProviderLogo(provider: method.provider, size: 52)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(method.provider.displayName)
                        .font(TamrinFont.font(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                    Text(paymentMethodSubtitle(method))
                        .font(TamrinFont.font(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 78)
            .background(method.provider.brandSurfaceColor, in: .rect(cornerRadius: 22, style: .continuous))
            .contentShape(.rect(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(method.provider.displayName)
        .accessibilityHint("عرض بيانات وسيلة الدفع")
    }

    private func snapshotDestinationRow(_ destination: PaymentDestination) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
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
                .locale(Locale(identifier: "ar_SA"))
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
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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
