import SwiftUI

/// Rating a player, six attributes at a time, without ever leaving the player's
/// sheet. One attribute fills the sheet at a time — a number that large is hard
/// to answer carelessly — and the seventh screen is the Overall those six blend
/// into, with every one of them still reachable for a second thought.
struct PlayerRatingFlowView: View {
    let playerName: String
    /// Decides the weights the Overall is blended with, so the number the rater
    /// sees before submitting is the number the server will store.
    let position: PlayerPosition
    /// A previous rating by this rater, when they are revising one.
    var initial: PlayerRatingScores?
    let submit: @MainActor (PlayerRatingScores) async throws -> SubmitRatingResult
    let onFinish: (PlayerRatingSummary) -> Void

    @State private var scores: PlayerRatingScores
    @State private var stepIndex: Int
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(
        playerName: String,
        position: PlayerPosition,
        initial: PlayerRatingScores? = nil,
        submit: @escaping @MainActor (PlayerRatingScores) async throws -> SubmitRatingResult,
        onFinish: @escaping (PlayerRatingSummary) -> Void
    ) {
        self.playerName = playerName
        self.position = position
        self.initial = initial
        self.submit = submit
        self.onFinish = onFinish
        _scores = State(initialValue: initial ?? .neutral)
        // Revising an existing rating opens on the summary: the rater already
        // answered the six and is usually here to change one of them.
        _stepIndex = State(initialValue: initial == nil ? 0 : Self.summaryIndex)
    }

    private static var summaryIndex: Int { PlayerAttribute.allCases.count }

    private var isSummary: Bool { stepIndex >= Self.summaryIndex }
    private var attribute: PlayerAttribute? {
        isSummary ? nil : PlayerAttribute.allCases[stepIndex]
    }
    private var overall: Int { scores.overall(for: position) }

    var body: some View {
        VStack(spacing: 12) {
            header

            if let attribute {
                attributeStep(attribute)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    summaryStep
                        .padding(.vertical, 2)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: .infinity)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(TamrinFont.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            controls
        }
        .animation(.smooth(duration: 0.28), value: stepIndex)
        .animation(.smooth(duration: 0.25), value: errorMessage)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Keep both labels on the player's side of the header. The native
            // navigation-bar Cancel action owns the opposite corner, and a
            // split HStack let the step count drift underneath that glass pill.
            VStack(alignment: .leading, spacing: 2) {
                Text(isSummary ? "تقييمك لـ \(playerName)" : "قيّم \(playerName)")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(isSummary ? "النتيجة" : "\((stepIndex + 1).tamrinNumber) من \(PlayerAttribute.allCases.count.tamrinNumber)")
                    .font(TamrinFont.font(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            StepTrack(current: stepIndex, total: PlayerAttribute.allCases.count)
        }
    }

    // MARK: - One attribute

    /// The same visual hierarchy as the reference picker: a quiet label, one
    /// dominant value, then a ruler moving beneath a fixed centre mark.
    private func attributeStep(_ attribute: PlayerAttribute) -> some View {
        VStack(spacing: 14) {
            Label {
                Text(attribute.title)
                    .font(TamrinFont.font(size: 16, weight: .medium))
            } icon: {
                Image(systemName: attribute.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .foregroundStyle(.secondary)

            // The digits roll rather than swap: `numericText` is the system's
            // own odometer, so scrubbing the ruler reads as one moving number.
            Text(scores[attribute].tamrinNumber)
                .font(TamrinFont.font(size: 74, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(scores[attribute])))
                .animation(.smooth(duration: 0.35), value: scores[attribute])

            Label(
                "تقييمك مجهول، ولن يظهر اسمك للاعب.",
                systemImage: "eye.slash.fill"
            )
            .font(TamrinFont.font(size: 11, weight: .regular))
            .foregroundStyle(.secondary)

            RatingRuler(
                value: Binding(
                    get: { scores[attribute] },
                    set: { scores[attribute] = $0 }
                ),
                label: attribute.title
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background(TamrinTheme.card, in: .rect(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Summary

    private var summaryStep: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                RatingCrest(value: overall, size: 104)

                Text(RatingBand.label(for: overall))
                    .font(TamrinFont.font(size: 17, weight: .bold))

                // Naming the weighting is what keeps the number from looking
                // arbitrary: a defender's Overall is not a striker's average.
                Text("محسوب بأوزان مركز \(position.rawValue)")
                    .font(TamrinFont.font(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            AttributeGrid(scores: scores, onSelect: { attribute in
                Haptics.selection()
                stepIndex = PlayerAttribute.allCases.firstIndex(of: attribute) ?? 0
            })

            Label(
                "التقييمات مجهولة — اللاعب يشوف متوسط تقييمه فقط، وما يعرف مين قيّمه.",
                systemImage: "eye.slash.fill"
            )
            .font(TamrinFont.font(size: 12, weight: .regular))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(TamrinTheme.card, in: .rect(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            if stepIndex > 0 {
                Button {
                    Haptics.selection()
                    stepIndex -= 1
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 42, height: 42)
                }
                .tamrinSecondaryAction()
                .accessibilityLabel("رجوع")
            }

            Button {
                advance()
            } label: {
                HStack(spacing: 8) {
                    if isSubmitting {
                        ProgressView().controlSize(.small).tint(TamrinTheme.ink)
                    }
                    Text(primaryTitle)
                        .font(TamrinFont.font(size: 16, weight: .bold))
                }
                .frame(maxWidth: .infinity)
            }
            .tamrinPrimaryAction(tint: TamrinTheme.lime)
            .disabled(isSubmitting)
        }
    }

    private var primaryTitle: String {
        if isSummary { return isSubmitting ? "يُحفظ…" : "قدّم التقييم" }
        if stepIndex == PlayerAttribute.allCases.count - 1 { return "شوف النتيجة" }
        return "التالي"
    }

    private func advance() {
        guard !isSubmitting else { return }
        if isSummary {
            Task { await send() }
        } else {
            Haptics.impact(.light)
            stepIndex += 1
        }
    }

    @MainActor
    private func send() async {
        isSubmitting = true
        errorMessage = nil
        do {
            switch try await submit(scores) {
            case .saved(let summary):
                Haptics.success()
                onFinish(summary)
            case .isSelf:
                errorMessage = "ما تقدر تقيّم نفسك."
            case .notAMember:
                errorMessage = "هذا اللاعب ما عاد عضوًا في المجموعة."
            case .positionRequired:
                errorMessage = "لازم يحدد اللاعب مركزه قبل التقييم."
            case .outOfRange:
                errorMessage = "قيم التقييم لازم تكون بين 0 و 100."
            }
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
        isSubmitting = false
    }
}

// MARK: - Step track

/// Six segments, filled behind you and hollow ahead — the flow's length is
/// visible from its first screen, which is what stops it feeling open-ended.
private struct StepTrack: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? TamrinTheme.lime : Color.primary.opacity(0.12))
                    .frame(height: 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("الخطوة \(min(current + 1, total)) من \(total)")
    }
}

// MARK: - Slider

/// The 0–100 control: a ruler that scrubs under a fixed centre mark, the way
/// a time or weight picker does. Dragging moves the scale, not a knob, so the
/// number under the mark is always the answer.
///
/// Layout direction is pinned left-to-right so dragging the ruler left brings
/// larger values from the right to the marker, just like the reference.
struct RatingRuler: View {
    @Binding var value: Int
    var label: String

    /// The reference leaves enough space to feel every stop, with distant
    /// values collapsing to dots and the values around the marker growing.
    private static let unit: CGFloat = 11
    private static let height: CGFloat = 58

    @State private var centredValue: Int?

    init(value: Binding<Int>, label: String) {
        self._value = value
        self.label = label
        _centredValue = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        GeometryReader { geo in
            let viewportMidX = geo.size.width / 2
            let unit = Self.unit
            let viewportSpace = "rating-ruler-viewport"

            ZStack {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(0...100, id: \.self) { tick in
                            Capsule()
                                .fill(Color.primary)
                                .frame(width: 3, height: 18)
                                .frame(width: unit, height: Self.height)
                                .visualEffect { content, proxy in
                                    // Measure the rendered tick inside the
                                    // fixed viewport — not inside the moving
                                    // scroll content — so seven neighbours on
                                    // either side grow toward the marker.
                                    let frame = proxy.frame(in: .named(viewportSpace))
                                    let distance = abs(frame.midX - viewportMidX) / unit
                                    let proximity = max(0, 1 - min(distance / 7, 1))
                                    let visibleHeight = 3 + 15 * pow(proximity, 0.82)
                                    return content
                                        .scaleEffect(y: visibleHeight / 18)
                                        .opacity(Double(0.12 + proximity * 0.18))
                                }
                                .id(tick)
                                .accessibilityHidden(true)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .contentMargins(
                    .horizontal,
                    max((geo.size.width - unit) / 2, 0),
                    for: .scrollContent
                )
                .scrollTargetBehavior(.viewAligned(anchor: .center))
                .scrollPosition(id: $centredValue, anchor: .center)

                // The mark the number is read against.
                Capsule()
                    .fill(.red)
                    .frame(width: 5, height: 28)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: viewportSpace)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.92),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .onChange(of: centredValue) { _, newValue in
                guard let newValue, newValue != value else { return }
                value = newValue
            }
            .onChange(of: value) { _, newValue in
                guard centredValue != newValue else { return }
                withAnimation(.snappy(duration: 0.22)) { centredValue = newValue }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .frame(height: Self.height)
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: update(to: value + 1)
            case .decrement: update(to: value - 1)
            default: break
            }
        }
    }

    private func update(to newValue: Int) {
        let clamped = min(max(newValue, 0), 100)
        guard clamped != value else { return }
        value = clamped
    }
}

#Preview {
    PlayerRatingFlowView(
        playerName: "أبو صقر",
        position: .midfielder,
        submit: { _ in .isSelf },
        onFinish: { _ in }
    )
    .padding(20)
    .background(TamrinTheme.sheet)
    .environment(\.layoutDirection, .rightToLeft)
}
