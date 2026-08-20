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

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(
        member: FeedMember,
        avatarImageData: Data? = nil,
        share: Double,
        seatNumber: Int? = nil,
        showsPayment: Bool = false,
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


    private var positionText: String {
        member.position.trimmingCharacters(in: .whitespacesAndNewlines)
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
                .onReceive(ticker) { now = $0 }
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
        // It opens at half and pulls up to full: a player's details run longer
        // than a half sheet once the money is on it. Left at the system's
        // default content interaction — `.scrolls` gave the scroll view first
        // claim on an upward drag, so pulling the sheet open did nothing and
        // only the grabber could resize it.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Details

    private var details: some View {
        VStack(spacing: 22) {
            identity

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
