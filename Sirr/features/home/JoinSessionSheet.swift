import SwiftUI

/// «سجّل في الموعد»: the member's own seat, and anyone they bring. Built the
/// way the one-field companion sheet is: an off-white sheet, white fields,
/// the action in the bar, and the sheet simply closes when it is done. What
/// happened shows on the exercise page under it.
struct JoinSessionSheet: View {
    @Bindable var feed: HomeStore
    let occurrence: FeedOccurrence

    @Environment(\.dismiss) private var dismiss
    /// Starts off, so taking a seat is a deliberate tap on your own card.
    @State private var includesSelf = false
    @State private var guestNames: [String] = []
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// An earlier workout in this group is unpaid, so the server refused.
    @State private var owedEventID: UUID?
    @FocusState private var focusedGuest: Int?

    private let maximumNameLength = 60
    /// One height for a guest's field and its remove button.
    private static let fieldHeight: CGFloat = 54

    private var settings: RegistrationSettings { occurrence.registrationSettings }

    private var validGuests: [String] {
        guestNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Guests can be switched off, and an approved exercise takes guests only
    /// alongside the member asking for them.
    private var offersGuests: Bool {
        settings.guestsAllowed && (settings.approvalMode == .auto || includesSelf)
    }

    private var canSubmit: Bool {
        !isSubmitting && (includesSelf ? true : !validGuests.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    selfCard

                    if offersGuests {
                        guestsSection
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(TamrinFont.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.blurReplace)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sheetContentHeight()
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(TamrinTheme.sheet)
            .animation(.smooth(duration: 0.28), value: errorMessage)
            .animation(.smooth(duration: 0.28), value: guestNames.count)
            .animation(.smooth(duration: 0.28), value: includesSelf)
            .sheetTitle(
                String(localized: "سجّل في الموعد"),
                subtitle: String(localized: "يوم \(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء", role: .cancel) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("تسجيل", action: submit)
                        .fontWeight(.semibold)
                        .disabled(!canSubmit)
                }
            }
            .overlay {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.large)
                        .padding(20)
                        .background(.regularMaterial, in: .rect(cornerRadius: 20, style: .continuous))
                        .transition(.blurReplace)
                }
            }
            .animation(.smooth(duration: 0.2), value: isSubmitting)
        }
        .environment(\.layoutDirection, .tamrin)
        .fittedSheet(minHeight: 240, includesNavigationBar: true)
        .interactiveDismissDisabled(isSubmitting)
        .alert(
            String(localized: "عليك قطة سابقة"),
            isPresented: Binding(get: { owedEventID != nil }, set: { if !$0 { owedEventID = nil } })
        ) {
            Button(String(localized: "ادفع الآن")) {
                // Home swaps its presented workout for the unpaid one, or,
                // when the feed does not hold it, closes back to Home where
                // the unpaid workout is listed.
                feed.requestedOccurrenceID = owedEventID
                owedEventID = nil
                dismiss()
            }
            Button(String(localized: "لاحقاً"), role: .cancel) { owedEventID = nil }
        } message: {
            Text(owedMessage)
        }
    }

    private var owedMessage: String {
        guard let owedEventID, let unpaid = feed.occurrence(withID: owedEventID) else {
            return String(localized: "ما دفعت قطتك في تمرين سابق. ادفعها عشان تقدر تسجّل.")
        }
        return String(localized: "ما دفعت قطتك في \(unpaid.title). ادفعها عشان تقدر تسجّل.")
    }

    // MARK: Sections

    /// The member's own seat, drawn as the member card it becomes on the
    /// list. The circle is the seat: empty until it is claimed.
    private var selfCard: some View {
        Button {
            Haptics.selection()
            includesSelf.toggle()
            errorMessage = nil
            if !includesSelf, !offersGuests { guestNames = [] }
        } label: {
            HStack(spacing: 12) {
                MemberAvatar(
                    name: feed.profileName.isEmpty ? String(localized: "أنا") : feed.profileName,
                    size: 40,
                    imageData: feed.avatarData,
                    imageUrl: feed.avatarUrl,
                    tint: TamrinTheme.secondary,
                    foreground: .primary
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.profileName.isEmpty ? String(localized: "أنا") : feed.profileName)
                        .font(TamrinFont.headline)
                        .foregroundStyle(.primary)
                    Text(includesSelf ? String(localized: "مقعدك محجوز") : String(localized: "اضغط لتحجز مقعدك"))
                        .font(TamrinFont.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.interpolate)
                }
                Spacer(minLength: 8)
                Image(systemName: includesSelf ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(includesSelf ? Color.accentColor : Color.secondary.opacity(0.35))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TamrinTheme.card, in: .rect(cornerRadius: 22, style: .continuous))
            .contentShape(.rect(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
        .accessibilityAddTraits(includesSelf ? .isSelected : [])
    }

    @ViewBuilder
    private var guestsSection: some View {
        if guestNames.isEmpty {
            Button {
                guestNames = [""]
                focusedGuest = 0
            } label: {
                Label(
                    includesSelf ? String(localized: "بسجل معي أحد") : String(localized: "سجّل ضيف بدونك"),
                    systemImage: "person.badge.plus"
                )
                .font(TamrinFont.font(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .background(TamrinTheme.card, in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
        } else {
            Text("اسم اللاعب")
                .font(TamrinFont.font(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            ForEach(guestNames.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField("مثلًا: خالد العتيبي", text: guestBinding(at: index))
                        .font(TamrinFont.headline)
                        .focused($focusedGuest, equals: index)
                        .submitLabel(.done)
                        .disabled(isSubmitting)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: Self.fieldHeight)
                        .background(TamrinTheme.card, in: .capsule)

                    Button {
                        guestNames.remove(at: index)
                    } label: {
                        // As tall as the field beside it, and as wide.
                        Image(systemName: "minus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.red)
                            .frame(width: Self.fieldHeight, height: Self.fieldHeight)
                            .background(.red.opacity(0.1), in: .circle)
                            .contentShape(.circle)
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
                    .font(TamrinFont.font(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
        }
    }

    private func guestBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { guestNames.indices.contains(index) ? guestNames[index] : "" },
            set: { newValue in
                guard guestNames.indices.contains(index) else { return }
                guestNames[index] = String(newValue.prefix(maximumNameLength))
            }
        )
    }

    // MARK: Submit

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        focusedGuest = nil
        let guests = validGuests
        let withoutSelf = !includesSelf

        Task {
            let failure = await register(guests: guests, withoutSelf: withoutSelf)
            isSubmitting = false
            if let failure {
                Haptics.error()
                errorMessage = failure
            } else if owedEventID != nil {
                Haptics.error()
            } else {
                Haptics.success()
                dismiss()
            }
        }
    }

    /// Nil when the seat (or the request for it) went through. A full session
    /// that keeps a queue puts the member on it, which is what registering
    /// late means; the exercise page shows where they landed.
    @MainActor
    private func register(guests: [String], withoutSelf: Bool) async -> String? {
        let destination: PaymentDestination
        do {
            destination = try await (withoutSelf
                ? feed.guestPaymentDestination(for: occurrence)
                : feed.paymentDestination(for: occurrence))
        } catch {
            return error.localizedDescription
        }
        guard destination.status != .paymentMethodRequired else {
            return String(localized: "لم يضف المشرف وسيلة دفع لهذا الموعد بعد.")
        }

        let outcome = withoutSelf
            ? await feed.addGuests(guests, to: occurrence, expectedDestination: destination, withoutSelf: true)
            : await feed.submitRegistration(guests: guests, for: occurrence, expectedDestination: destination)

        switch outcome {
        case .success, .requested:
            return nil
        case .failure(let message):
            return message
        case .seatsFullOfferWaitlist:
            if case .failure(let message) = await feed.joinWaitlist(occurrence) { return message }
            return nil
        case .closedAtCapacity:
            return String(localized: "اكتمل العدد، وما فيه قائمة انتظار لهذا الموعد.")
        case .paymentOwed(let eventId):
            owedEventID = eventId
            return nil
        }
    }
}
