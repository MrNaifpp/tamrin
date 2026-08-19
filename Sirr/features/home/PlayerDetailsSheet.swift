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
    /// Nil hides the reminder button — a free exercise, a player with no
    /// account to reach, or a viewer who is not the organizer.
    var onRemind: (@MainActor () async -> HomeStore.PaymentReminderOutcome)?
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
    /// Holds taps while details and the rating flow replace one another, so a
    /// tap cannot land on a control moving into the same point mid-transition.
    @State private var isSurfaceSettling = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(
        member: FeedMember,
        avatarImageData: Data? = nil,
        share: Double,
        seatNumber: Int? = nil,
        showsPayment: Bool = false,
        loadRating: (@MainActor () async throws -> PlayerRatingSummary)? = nil,
        submitRating: (@MainActor (PlayerRatingScores) async throws -> SubmitRatingResult)? = nil,
        onRemind: (@MainActor () async -> HomeStore.PaymentReminderOutcome)? = nil,
        onRemove: (() -> Void)? = nil
    ) {
        self.member = member
        self.avatarImageData = avatarImageData
        self.share = share
        self.seatNumber = seatNumber
        self.showsPayment = showsPayment
        self.loadRating = loadRating
        self.submitRating = submitRating
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
            Group {
                if isRatingFlowOpen, let submitRating, let ratingPosition {
                    PlayerRatingFlowView(
                        playerName: member.name,
                        position: ratingPosition,
                        initial: rating?.mine,
                        submit: submitRating,
                        onFinish: { summary in
                            rating = summary
                            showRatingFlow(false)
                        }
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                    .transition(.blurReplace)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        details
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 20)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .transition(.blurReplace)
                }
            }
            .allowsHitTesting(!isSurfaceSettling)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.clear)
            .animation(.smooth(duration: 0.3), value: justSent)
            .animation(.smooth(duration: 0.28), value: errorMessage)
            .animation(.smooth(duration: 0.3), value: isRatingFlowOpen)
            .animation(.smooth(duration: 0.3), value: rating?.ratingsCount)
            .onReceive(ticker) { now = $0 }
            .task { await fetchRating() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Leaving the flow is a step back to the sheet it opened
                    // from, not out of the sheet altogether.
                    Button(isRatingFlowOpen ? "إلغاء" : "تم") {
                        if isRatingFlowOpen {
                            showRatingFlow(false)
                        } else {
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        // A single native half-sheet, including the entire six-step flow. It
        // never grows into a near-full-screen form; longer details scroll
        // inside the same surface.
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .presentationContentInteraction(.scrolls)
        .presentationBackground(.regularMaterial)
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

            PositionPitch(position: positionText)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Rating

    @ViewBuilder
    private var ratingPanel: some View {
        if let rating, let average = rating.average,
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
                    ? { showRatingFlow(true) }
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
                    ? { showRatingFlow(true) }
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
            Label("إزالة اللاعب من التمرين", systemImage: "person.badge.minus")
                .font(TamrinFont.font(size: 15, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .background(.red.opacity(0.12), in: .rect(cornerRadius: 22, style: .continuous))
    }

    /// Swaps the content inside the fixed half-sheet and holds taps off until
    /// the replacement animation has settled.
    private func showRatingFlow(_ open: Bool) {
        guard isRatingFlowOpen != open else { return }
        isSurfaceSettling = true
        isRatingFlowOpen = open
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            isSurfaceSettling = false
        }
    }

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
                .tamrinPrimaryAction(tint: TamrinTheme.lime)
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
        return isUnrated ? "باقي ما قُيم" : "التقييم غير متاح"
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
            : "عنده \(ratersCount.ratingsCounted)."
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
        LazyVGrid(columns: columns, spacing: 9) {
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
        VStack(alignment: .leading, spacing: 5) {
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
            .frame(height: 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isEditable ? TamrinTheme.lime.opacity(0.12) : Color.primary.opacity(0.04),
            in: .rect(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(attribute.title): \(value)")
    }
}

// MARK: - Position

/// The player's position drawn on a pitch: a pill carrying the position's
/// name, sitting in the part of the pitch that position holds, lit from
/// underneath in the position's colour.
///
/// Two things say the position at once — where the pill sits and what colour
/// it is — so it reads at a glance and still survives being looked at closely.
struct PositionPitch: View {
    let position: String

    private var trimmedPosition: String {
        position.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var displayPosition: String {
        trimmedPosition.isEmpty ? "المركز غير محدد" : trimmedPosition
    }
    private var resolved: PlayerPosition? { PlayerPosition.exact(from: position) }
    private var tint: Color { resolved?.tint ?? .secondary }

    /// Deliberately not full width: the pitch is an inset panel the sheet's
    /// other cards frame, not a band across it.
    private static let width: CGFloat = 208
    private static let height: CGFloat = 116

    var body: some View {
        ZStack {
            PitchMarkings()

            GeometryReader { geo in
                let zone = resolved?.pitchZone ?? (0.42...0.58)
                // The pitch attacks upward, so a zone measured from own goal
                // is a height measured down from the top.
                let centre = 1 - (zone.lowerBound + zone.upperBound) / 2
                let y = geo.size.height * centre

                ZStack {
                    // A wide, soft pool of colour under the pill rather than a
                    // halo around it — the glow is what carries across the
                    // sheet, the pill is what you read up close.
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [tint.opacity(0.85), tint.opacity(0.35), tint.opacity(0)],
                                center: .center,
                                startRadius: 2,
                                endRadius: 66
                            )
                        )
                        .frame(width: 150, height: 78)
                        .offset(y: 20)
                        .blur(radius: 14)

                    Text(displayPosition)
                        .font(TamrinFont.font(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule(style: .continuous).fill(tint))
                }
                .position(x: geo.size.width / 2, y: y)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("مركزه: \(displayPosition)")
    }
}

/// The pitch itself, drawn faintly enough that the pill stays the subject:
/// the touchline, the goal area the attack runs at, and the centre circle
/// breaking the near edge.
private struct PitchMarkings: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let line = Color.primary.opacity(0.10)
            let boxWidth = w * 0.44
            let boxHeight = h * 0.20
            let circle = h * 0.34

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(line, lineWidth: 1)

                // Goal area at the far end.
                Rectangle()
                    .strokeBorder(line, lineWidth: 1)
                    .frame(width: boxWidth, height: boxHeight)
                    .position(x: w / 2, y: boxHeight / 2)

                // The centre circle sits on the near edge, so the panel reads
                // as the half of the pitch being attacked.
                Circle()
                    .strokeBorder(line, lineWidth: 1)
                    .frame(width: circle, height: circle)
                    .position(x: w / 2, y: h)
            }
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
        }
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
