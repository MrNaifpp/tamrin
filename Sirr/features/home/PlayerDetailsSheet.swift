import Combine
import SwiftUI

/// Who this player is on this exercise. The sheet opens on the player
/// themselves — photo, position and name, no chrome above it — and everything
/// anyone might act on follows underneath.
///
/// Two audiences read the same sheet. Everyone sees who the player is and how
/// the group rates him; only the organizer sees the money.
struct PlayerDetailsSheet: View {
    let member: FeedMember
    /// A photo already in memory — mine, before its upload has landed.
    var avatarImageData: Data?
    /// What this player owes for the exercise; 0 for a free one.
    let share: Double
    /// 1-based position in the roster: who took the third seat, and so on.
    var seatNumber: Int?
    /// The share and its status are the organizer's business. Everyone else
    /// reads the sheet without them, including the player themselves.
    var showsPayment: Bool = false
    /// Reading and writing this player's rating. A guest has neither. My own
    /// sheet has a reader but no writer, so it shows the anonymous average
    /// without ever offering self-rating.
    ///
    /// `@MainActor` is not decoration: `HomeStore` is main-actor isolated, and
    /// handing these out as non-isolated closures made every call hop actors
    /// with a captured store and member. That corrupted the context — writes
    /// silently did nothing, then the submit segfaulted. `onRemind` below was
    /// already declared this way for the same reason.
    var loadRating: (@MainActor () async throws -> PlayerRatingSummary)?
    var submitRating: (@MainActor (PlayerRatingScores) async throws -> SubmitRatingResult)?
    /// Guests have no account of their own; this names the member who reserved
    /// their seat instead of leaving the relationship hidden behind an id.
    var registeredByName: String?
    /// Nil hides the reminder button — a free exercise, a player with no
    /// account to reach, or a viewer who is not the organizer.
    var onRemind: (@MainActor () async -> HomeStore.PaymentReminderOutcome)?
    /// What removing this person means where the sheet was opened from: out of
    /// this exercise, or out of the group entirely.
    var removeTitle: String = "إزالة اللاعب من التمرين"
    /// Nil for a member who is not the organizer's to remove.
    var onRemove: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    /// Seeded from the roster so a reminder sent before this sheet was opened
    /// — or from another device — still holds the button closed.
    @State private var cooldownEndsAt: Date?
    @State private var justSent = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var now = Date()

    // Rating
    @State private var rating: PlayerRatingSummary?
    @State private var isLoadingRating = true
    @State private var ratingLoadFailed = false
    @State private var isRatingFlowOpen = false
    /// Shown once, ahead of the first rating anyone gives.
    ///
    /// A wrong mental model here produces wrong numbers rather than a confused
    /// user — someone who believes his score is published rates politely, and
    /// someone who believes he is judging against professionals rates the whole
    /// group in the thirties. Neither can be taken back out of the average
    /// afterwards, so the explaining has to come first.
    @State private var isRatingOnboardingOpen = false
    @State private var detent: PresentationDetent = .large

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(
        member: FeedMember,
        avatarImageData: Data? = nil,
        share: Double,
        seatNumber: Int? = nil,
        showsPayment: Bool = false,
        loadRating: (@MainActor () async throws -> PlayerRatingSummary)? = nil,
        submitRating: (@MainActor (PlayerRatingScores) async throws -> SubmitRatingResult)? = nil,
        registeredByName: String? = nil,
        removeTitle: String = "إزالة اللاعب من التمرين",
        onRemind: (@MainActor () async -> HomeStore.PaymentReminderOutcome)? = nil,
        onRemove: (() -> Void)? = nil
    ) {
        self.member = member
        self.avatarImageData = avatarImageData
        self.share = share
        self.seatNumber = seatNumber
        self.showsPayment = showsPayment
        self.removeTitle = removeTitle
        self.loadRating = loadRating
        self.submitRating = submitRating
        self.registeredByName = registeredByName
        self.onRemind = onRemind
        self.onRemove = onRemove
        _cooldownEndsAt = State(
            initialValue: member.paymentReminderSentAt?.addingTimeInterval(Self.cooldown)
        )
    }

    /// Long enough that a second tap is a decision, short enough to still be
    /// useful on the day of the exercise.
    private static let cooldown: TimeInterval = 3600

    private var paymentTile: (value: String, caption: String, symbol: String, tint: Color) {
        switch member.status {
        case .registered:
            return ("مسدّدة", "حالة القطة", "checkmark.seal.fill", TamrinTheme.brandGreen)
        case .awaitingPayment:
            return ("لم تُدفع", "حالة القطة", "banknote", .orange)
        case .paymentPending:
            return ("بانتظار تأكيدك", "حالة القطة", "hourglass", .orange)
        case .waitlisted:
            return ("في الانتظار", "مكانه بالقائمة", "person.badge.clock.fill", .orange)
        }
    }

    private var canViewRating: Bool { loadRating != nil }
    private var canSubmitRating: Bool { submitRating != nil }
    private var ratingPosition: PlayerPosition? { PlayerPosition.exact(from: positionText) }

    /// The freshly fetched position wins over the roster's copy, which may be
    /// a screen old.
    private var positionText: String {
        let fetched = rating?.position.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fetched.isEmpty ? member.position : fetched
    }

    private var remaining: TimeInterval {
        guard let cooldownEndsAt else { return 0 }
        return max(cooldownEndsAt.timeIntervalSince(now), 0)
    }

    private var isCoolingDown: Bool { remaining > 0 }

    /// mm:ss — a countdown the organizer can watch, rather than a static
    /// "try later" that gives no idea how much later.
    private var remainingText: String {
        let total = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var body: some View {
        NavigationStack {
            details
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
                .scrollableSheetContent()
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.clear)
                .animation(.smooth(duration: 0.3), value: justSent)
                .animation(.smooth(duration: 0.28), value: errorMessage)
                .animation(.smooth(duration: 0.3), value: rating?.ratingsCount)
                .onReceive(ticker) { now = $0 }
                .task { await fetchRating() }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("تم") { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
        .environment(\.layoutDirection, .rightToLeft)
        // The system's own half sheet, left entirely to the system: at a
        // non-large detent iOS insets it from the screen edges and paints its
        // own translucent material. Overriding the presentation background —
        // which `fittedSheet` does — is what flattened it into an opaque panel
        // spanning the full width.
        // Opens at half and pulls up to full: a player's details run longer
        // than a half sheet once the money and the rating panel are both on it.
        // Left at the system's default content interaction — `.scrolls` gave
        // the scroll view first claim on an upward drag, so pulling the sheet
        // open did nothing and only the grabber could resize it.
        // Opens full rather than at half. Everything worth reading here — the
        // player, the rating panel, the money — sits below the fold at the
        // medium detent, so opening there showed the header and asked for a
        // drag before the sheet said anything. Both detents stay: pulling it
        // back down is still allowed, it is just no longer where it starts.
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        // The rating flow is its own sheet on top of this one, not a second
        // face of it: it is a fixed half sheet that never scrolls, while this
        // one scrolls and expands. One surface could not be both.
        // Full screen, not a sheet: the first card plays the feature running,
        // and a clip in a half sheet is a thumbnail.
        .fullScreenCover(isPresented: $isRatingOnboardingOpen) {
            RatingOnboardingSheet {
                isRatingOnboardingOpen = false
                // Straight into the thing it just explained, rather than back
                // to the button to press again.
                isRatingFlowOpen = true
            }
        }
        .sheet(isPresented: $isRatingFlowOpen) {
            if let submitRating, let ratingPosition {
                PlayerRatingSheet(
                    playerName: member.name,
                    position: ratingPosition,
                    initial: rating?.mine,
                    submit: submitRating,
                    onFinish: { summary in
                        rating = summary
                        isRatingFlowOpen = false
                    }
                )
            }
        }
    }

    private func openRating() {
        if RatingOnboarding.hasSeen {
            isRatingFlowOpen = true
        } else {
            isRatingOnboardingOpen = true
        }
    }

    // MARK: - Details

    private var details: some View {
        VStack(spacing: 22) {
            identity

            if canViewRating { ratingPanel }

            facts

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(TamrinFont.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.blurReplace)
            }

            VStack(spacing: 10) {
                if onRemind != nil { reminderButton }
                if let onRemove { removeButton(onRemove) }
            }
        }
    }

    // MARK: - Identity

    /// The photo, with the player's position pinned to its lower edge the way
    /// a squad list marks a shirt, then the name.
    private var identity: some View {
        VStack(spacing: 10) {
            PlayerPortrait(
                name: member.name,
                avatarData: avatarImageData,
                avatarUrl: member.avatarUrl
            )

            Text(member.name)
                .font(TamrinFont.font(size: 24, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            if !positionText.isEmpty {
                PositionTag(position: positionText)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Rating

    /// Whether this person has earned the right to see the number.
    ///
    /// Rating is a trade, not a lookup: you get the group's verdict once you
    /// have given yours. Showing it first lets someone read the room and then
    /// rate to match it, which quietly turns an average of independent opinions
    /// into an average of one opinion repeated.
    ///
    /// Anyone who cannot rate at all is not being asked for anything, so
    /// nothing is withheld from them — a player's own sheet still shows him
    /// what the group thinks.
    private var revealsRating: Bool {
        guard canSubmitRating else { return true }
        return rating?.hasRated == true
    }

    @ViewBuilder
    private var ratingPanel: some View {
        if revealsRating, let rating, let average = rating.average,
           let overall = rating.averageOverall {
            RatedPanel(
                average: average,
                overall: overall,
                ratersCount: rating.ratingsCount,
                myOverall: rating.myOverall,
                actionTitle: canSubmitRating
                    ? (rating.hasRated ? "عدّل تقييمك" : "قيّم اللاعب")
                    : nil,
                onAction: ratingPosition != nil && canSubmitRating
                    ? { openRating() }
                    : nil
            )
        } else {
            LockedRatingPanel(
                isUnrated: rating?.isUnrated ?? true,
                ratersCount: rating?.ratingsCount ?? 0,
                hasRated: rating?.hasRated ?? false,
                isLoading: isLoadingRating && rating == nil,
                loadFailed: ratingLoadFailed,
                canSubmit: canSubmitRating,
                positionRequired: canSubmitRating && ratingPosition == nil,
                onRate: canSubmitRating && ratingPosition != nil
                    ? { openRating() }
                    : nil
            )
        }
    }

    // MARK: - Facts

    /// Two square tiles over one wide row: the shape the group already reads on
    /// the team page, so the player's numbers are not a second visual language.
    private var facts: some View {
        VStack(spacing: 10) {
            if showsPayment {
                HStack(spacing: 10) {
                    FactTile(
                        symbol: "banknote.fill",
                        value: share == 0 ? "مجاني" : "\(share.cleanAmount) ﷼",
                        caption: "قطته"
                    )
                    FactTile(
                        symbol: paymentTile.symbol,
                        value: paymentTile.value,
                        caption: paymentTile.caption,
                        tint: paymentTile.tint
                    )
                }
            }

            if let seatNumber {
                FactRow(
                    symbol: "flag.checkered",
                    caption: "ترتيبه في التسجيل",
                    value: seatNumber.arabicOrdinal
                )
            }

            if let registeredByName {
                FactRow(
                    symbol: "person.badge.plus",
                    caption: "سجّله",
                    value: registeredByName
                )
            }

            if let joinedAt = member.joinedAt {
                FactRow(
                    symbol: "clock.badge.checkmark",
                    caption: "سجّل يوم",
                    value: "\(joinedAt.arabicDate) · \(joinedAt.arabicTime)"
                )
            }
        }
    }

    // MARK: - Actions

    /// Three states in one control: ready, just-sent, and counting down. The
    /// just-sent state is deliberately loud — a filled green bar with a
    /// checkmark — because the push itself leaves no trace on this screen.
    private var reminderButton: some View {
        Button {
            Task { await sendReminder() }
        } label: {
            HStack(spacing: 9) {
                if isSending {
                    ProgressView().controlSize(.small).tint(TamrinTheme.ink)
                } else {
                    Image(systemName: justSent ? "checkmark.circle.fill" : "bell.badge.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }

                Text(reminderTitle)
                    .font(TamrinFont.font(size: 16, weight: .bold))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(justSent ? .white : (isCoolingDown ? Color.secondary : TamrinTheme.ink))
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(reminderBackground, in: .rect(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(SpringCardPressStyle())
        .disabled(isSending || isCoolingDown)
        .accessibilityLabel(reminderTitle)
        .accessibilityHint(
            isCoolingDown
                ? "أُرسل تذكير قريبًا. الزر يفتح بعد \(remainingText)"
                : "يرسل إشعارًا للاعب يذكّره بدفع قطته"
        )
    }

    private var reminderTitle: String {
        if justSent && !isCoolingDown { return "أُرسل التذكير" }
        if justSent { return "أُرسل التذكير · \(remainingText)" }
        if isCoolingDown { return "تقدر تذكّره بعد \(remainingText)" }
        return "تذكير بالقطة"
    }

    private var reminderBackground: Color {
        if justSent { return TamrinTheme.brandGreen }
        if isCoolingDown { return TamrinTheme.secondary }
        return TamrinTheme.lime
    }

    private func removeButton(_ remove: @escaping () -> Void) -> some View {
        Button(role: .destructive) {
            dismiss()
            remove()
        } label: {
            Label(removeTitle, systemImage: "person.badge.minus")
                .font(TamrinFont.font(size: 15, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .background(.red.opacity(0.12), in: .rect(cornerRadius: 22, style: .continuous))
    }

    /// Swaps the content inside the fixed half-sheet and holds taps off until
    /// the replacement animation has settled.
    @MainActor
    private func fetchRating() async {
        guard let loadRating, rating == nil else { return }
        isLoadingRating = true
        defer { isLoadingRating = false }
        do {
            rating = try await loadRating()
            ratingLoadFailed = false
        } catch {
            ratingLoadFailed = true
            // Deliberately silent: a rating that will not load is not worth an
            // alert over a sheet whose real subject is the player. The panel
            // keeps its locked state and the button still opens the flow,
            // which reports its own failure if the write fails too.
        }
    }

    @MainActor
    private func sendReminder() async {
        guard let onRemind, !isSending, !isCoolingDown else { return }
        isSending = true
        errorMessage = nil

        let outcome = await onRemind()
        isSending = false

        switch outcome {
        case .sent(let nextAllowedAt):
            Haptics.success()
            now = Date()
            cooldownEndsAt = nextAllowedAt
            justSent = true
        case .tooSoon(let nextAllowedAt):
            Haptics.impact(.rigid)
            now = Date()
            cooldownEndsAt = nextAllowedAt
            errorMessage = "أُرسل تذكير لهذا اللاعب قبل قليل."
        case .failure(let message):
            Haptics.error()
            errorMessage = message
        }
    }
}

// MARK: - Rating panels

/// The group's anonymous Overall in a crest, the six averages beneath, and a
/// quiet way back into the caller's own rating flow when editing is allowed.
private struct RatedPanel: View {
    let average: PlayerRatingScores
    let overall: Int
    let ratersCount: Int
    let myOverall: Int?
    var actionTitle: String?
    var onAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                RatingCrest(value: overall)

                VStack(alignment: .leading, spacing: 4) {
                    Text(RatingBand.label(for: overall))
                        .font(TamrinFont.font(size: 18, weight: .bold))
                    Text("من \(ratersCount.ratingsCounted)")
                        .font(TamrinFont.font(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                    if let myOverall {
                        Text("تقييمك: \(myOverall.tamrinNumber)")
                            .font(TamrinFont.font(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }

            AttributeGrid(scores: average)

            if let actionTitle, let onAction {
                Button(action: onAction) {
                    Label(
                        actionTitle,
                        systemImage: myOverall == nil ? "star.fill" : "slider.horizontal.3"
                    )
                    .frame(maxWidth: .infinity)
                }
                .tamrinSecondaryAction()
            }
        }
        .padding(16)
        .background(TamrinTheme.card, in: .rect(cornerRadius: 24, style: .continuous))
    }
}

/// The empty/loading state before an anonymous group average exists.
/// One step lighter than the panel it sits on, rather than the app's lime.
/// The accent made the action the loudest thing on a sheet that is mostly
/// about the player, and rating is an offer here, not the point of the screen.
private let ratingActionTint = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(white: 0.30, alpha: 1)
        : UIColor(white: 0.90, alpha: 1)
})

private struct LockedRatingPanel: View {
    let isUnrated: Bool
    let ratersCount: Int
    let hasRated: Bool
    let isLoading: Bool
    /// The fetch failed. Says so rather than claiming nobody has rated him.
    var loadFailed = false
    let canSubmit: Bool
    let positionRequired: Bool
    var onRate: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                RatingCrest(value: nil)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(TamrinFont.font(size: 18, weight: .bold))
                    Text(caption)
                        .font(TamrinFont.font(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if let onRate {
                Button(action: onRate) {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: hasRated ? "slider.horizontal.3" : "star.fill")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        Text(hasRated ? "عدّل تقييمك" : "قيّم اللاعب")
                    }
                    .frame(maxWidth: .infinity)
                }
                .tamrinPrimaryAction(tint: ratingActionTint)
                .disabled(isLoading)
            }
        }
        .padding(16)
        .background(TamrinTheme.card, in: .rect(cornerRadius: 24, style: .continuous))
    }

    /// Until the fetch lands, the panel says nothing it might have to take
    /// back — "nobody rated him" is a claim, not a placeholder.
    private var title: String {
        if isLoading { return "التقييم" }
        if loadFailed { return "تعذّر جلب التقييم" }
        if positionRequired { return "المركز مطلوب" }
        // Not "unavailable": it is available, and there is one thing to do
        // about it. Saying so is the whole point of the panel in this state.
        return isUnrated ? "باقي ما قُيم" : "قيّمه تشوف تقييمه"
    }

    private var caption: String {
        if isLoading { return "نجيب تقييمه…" }
        if loadFailed { return "تحقق من اتصالك وحاول مرة ثانية." }
        if positionRequired { return "لازم يحدد اللاعب مركزه قبل ما يبدأ التقييم." }
        if !canSubmit {
            return isUnrated
                ? "ما وصلك أي تقييم إلى الآن. تظهر النتيجة هنا بدون أسماء المقيمين."
                : "تقييمك مجهول ومحمي بدون أسماء المقيمين."
        }
        return isUnrated
            ? "كن أول من يقيّمه في ست معايير."
            : "عنده \(ratersCount.ratingsCounted). قيّمه وينفتح لك."
    }
}

/// The Overall as a card crest: one number, sized to be read across a room,
/// on the band colour that says roughly where it sits.
struct RatingCrest: View {
    /// Nil draws the locked crest.
    let value: Int?
    var size: CGFloat = 74

    private var tint: Color { value.map { RatingBand.tint(for: $0) } ?? TamrinTheme.secondary }

    var body: some View {
        VStack(spacing: 0) {
            if let value {
                Text(value.tamrinNumber)
                    .font(TamrinFont.font(size: size * 0.42, weight: .bold))
                    .foregroundStyle(TamrinTheme.ink)
                    .contentTransition(.numericText())
                Text("الإجمالي")
                    .font(TamrinFont.font(size: size * 0.145, weight: .medium))
                    .foregroundStyle(TamrinTheme.ink.opacity(0.65))
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(
                    // A crest, not a flat chip: the light falls from the top
                    // the way it does on the exercise posters.
                    LinearGradient(
                        colors: [tint, tint.opacity(value == nil ? 1 : 0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "التقييم الإجمالي \($0)" } ?? "التقييم مقفل")
    }
}

/// The six attributes as two columns of short bars — a shape that survives
/// being 150pt wide, which a radar chart does not.
struct AttributeGrid: View {
    let scores: PlayerRatingScores
    /// Passed by the rating flow's summary, where every bar is a way back to
    /// the step that set it. Nil elsewhere: the panel is a readout, not a
    /// control.
    var onSelect: ((PlayerAttribute) -> Void)?

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 7) {
            ForEach(PlayerAttribute.allCases) { attribute in
                if let onSelect {
                    Button { onSelect(attribute) } label: {
                        AttributeBar(
                            attribute: attribute,
                            value: scores[attribute],
                            isEditable: true
                        )
                    }
                    .buttonStyle(SpringCardPressStyle())
                    .accessibilityHint("يرجعك لتعديل \(attribute.title)")
                } else {
                    AttributeBar(attribute: attribute, value: scores[attribute])
                }
            }
        }
    }
}

private struct AttributeBar: View {
    let attribute: PlayerAttribute
    let value: Int
    /// Draws the pencil that says this bar is a way back into the flow.
    var isEditable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(attribute.shortTitle)
                    .font(TamrinFont.font(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if isEditable {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                Text(value.tamrinNumber)
                    .font(TamrinFont.font(size: 13, weight: .bold))
                    .contentTransition(.numericText())
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(RatingBand.tint(for: value))
                        .frame(width: max(geo.size.width * CGFloat(value) / 100, 3))
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isEditable ? TamrinTheme.lime.opacity(0.12) : Color.primary.opacity(0.04),
            in: .rect(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(attribute.title): \(value)")
    }
}

// MARK: - Position

/// The player's position: the word, on the colour that identifies it. The
/// colour is the whole design — a drawn pitch said the same thing in far more
/// space, and this sheet has none to spare.
struct PositionTag: View {
    let position: String

    private var tint: Color { PlayerPosition.resolved(from: position).tint }

    var body: some View {
        Text(position)
            .font(TamrinFont.font(size: 13, weight: .bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: .capsule)
            .accessibilityLabel("مركزه: \(position)")
    }
}

// MARK: - Building blocks

/// The player's photo at the size the sheet opens on, on the same avatar the
/// roster rows draw so a photo added anywhere shows here too.
private struct PlayerPortrait: View {
    let name: String
    var avatarData: Data?
    let avatarUrl: String?

    var body: some View {
        MemberAvatar(
            name: name,
            size: 104,
            imageData: avatarData,
            imageUrl: avatarUrl,
            tint: TamrinTheme.secondary,
            foreground: .primary
        )
        .overlay {
            Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

/// One square fact: a symbol, the figure, and what the figure is.
private struct FactTile: View {
    let symbol: String
    let value: String
    let caption: String
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(TamrinFont.font(size: 17, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption)
                    .font(TamrinFont.font(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(14)
        .background(TamrinTheme.card, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption): \(value)")
    }
}

/// One wide fact, for the values a square would have to shrink.
private struct FactRow: View {
    let symbol: String
    let caption: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(TamrinTheme.secondary, in: .circle)

            Text(caption)
                .font(TamrinFont.font(size: 14, weight: .regular))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(value)
                .font(TamrinFont.font(size: 15, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .background(TamrinTheme.card, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption): \(value)")
    }
}

extension Int {
    /// «الثالث» rather than «#3»: the roster position reads as a sentence, and
    /// past tenth it falls back to the numeral, which is how it is said aloud.
    var arabicOrdinal: String {
        let names = [
            "الأول", "الثاني", "الثالث", "الرابع", "الخامس",
            "السادس", "السابع", "الثامن", "التاسع", "العاشر"
        ]
        guard self >= 1 else { return "—" }
        if self <= names.count { return names[self - 1] }
        return "رقم \(formatted(.number.locale(.tamrin).grouping(.never)))"
    }

    /// Arabic-Indic digits, ungrouped — every rating figure in the app.
    var tamrinNumber: String {
        formatted(.number.locale(.tamrin).grouping(.never))
    }

    /// «3 تقييمات» / «تقييم واحد» — the app's own counting rule, so the caption
    /// agrees with the number the way the rest of the app's captions do.
    var ratingsCounted: String {
        self == 0 ? "بدون تقييمات" : counted(.rating)
    }
}

#Preview {
    Color.black
        .sheet(isPresented: .constant(true)) {
            PlayerDetailsSheet(
                member: FeedMember(
                    id: UUID(),
                    name: "أبو صقر",
                    status: .paymentPending,
                    userId: UUID(),
                    isManual: false,
                    joinedAt: .now,
                    position: "وسط"
                ),
                share: 312.5,
                seatNumber: 3,
                showsPayment: true,
                onRemind: { .sent(nextAllowedAt: Date().addingTimeInterval(3600)) },
                onRemove: {}
            )
        }
}
