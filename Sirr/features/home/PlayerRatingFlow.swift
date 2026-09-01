import SwiftUI

/// What a score looks like.
///
/// Hue carries it — red through amber to green — because that reading is
/// already in everyone before they open the app, and it needs no legend beside
/// the number.
///
/// The stops are not evenly spread on purpose. Half the range is spent getting
/// out of red, green proper is not reached until 85, and the deep green belongs
/// to 95 and up: a ramp that turned green at the midpoint would tell a rater he
/// had said something good when he had said something average, which is the
/// exact judgement the colour exists to sharpen.
enum RatingTint {
    /// Score → hue in degrees, interpolated between.
    private static let stops: [(score: Double, hue: Double)] = [
        (0, 0),      // red
        (50, 20),    // burnt orange — the neutral start, still nearer red
        (70, 58),    // yellow-green
        (85, 124),   // green proper
        (95, 140),   // deep green
        (100, 146)
    ]

    static func of(_ score: Int) -> Color {
        let value = Double(min(max(score, 0), 100))
        var hue = stops[stops.count - 1].hue
        for index in 1..<stops.count where value <= stops[index].score {
            let low = stops[index - 1]
            let high = stops[index]
            let span = high.score - low.score
            let progress = span > 0 ? (value - low.score) / span : 0
            hue = low.hue + (high.hue - low.hue) * progress
            break
        }
        // Deepening rather than only turning: the top of the scale reads as a
        // richer, darker green rather than a brighter one, so the nineties do
        // not glare. Full depth by 95, which is where the scale is meant to
        // look like it has been earned.
        let depth = min(max((value - 85) / 10, 0), 1)
        return Color(
            hue: hue / 360,
            saturation: 0.72 + 0.22 * depth,
            brightness: 0.98 - 0.30 * depth
        )
    }
}

/// The colour this flow moves forward on, shared by its progress track and its
/// primary button so they read as one motion.
private let ratingForward = Color(red: 0.20, green: 0.47, blue: 0.96)

/// The rating flow as its own surface: a half sheet over the player's sheet,
/// fixed at that height and never scrolling. Every step is built to fit it, so
/// the flow reads as one screen you answer rather than a page you hunt through
/// — which is why it cannot share the player's sheet, that one grows and
/// scrolls.
struct PlayerRatingSheet: View {
    let playerName: String
    let position: PlayerPosition
    var initial: PlayerRatingScores?
    let submit: @MainActor (PlayerRatingScores) async throws -> SubmitRatingResult
    let onFinish: (PlayerRatingSummary) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PlayerRatingFlowView(
                playerName: playerName,
                position: position,
                initial: initial,
                submit: submit,
                onFinish: onFinish
            )
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Leaving the flow is a step back to the player's sheet
                    // underneath, not out of the player altogether.
                    Button("إلغاء") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        // One detent, no scroll view anywhere inside: the six steps and the
        // summary are each sized to sit inside a half sheet.
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

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

            // No scroll view anywhere in here: both steps are sized to fit the
            // half sheet, and each takes the room the sheet offers so the
            // primary button stays on its bottom edge.
            if let attribute {
                attributeStep(attribute)
                    .frame(maxHeight: .infinity)
            } else {
                summaryStep
                    .frame(maxHeight: .infinity, alignment: .top)
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
            HStack(spacing: 8) {
                Text(playerName)
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .lineLimit(1)

                PositionTag(position: position.rawValue)

                Spacer(minLength: 6)

                Text(isSummary
                     ? "النتيجة"
                     : "\((stepIndex + 1).tamrinNumber) من \(PlayerAttribute.allCases.count.tamrinNumber)")
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
                // The number says what it means while it is being set. A rater
                // meeting this scale for the first time has no idea whether 62
                // is generous or harsh; the colour is the part of the answer
                // that needs no reading.
                .foregroundStyle(RatingTint.of(scores[attribute]))
                .contentTransition(.numericText(value: Double(scores[attribute])))
                .animation(.smooth(duration: 0.35), value: scores[attribute])


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
    }

    // MARK: - Summary

    /// Cut to the half sheet it has to fit: the crest sits beside its band
    /// instead of above it, which is the row that bought the six bars their
    /// room back.
    private var summaryStep: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                RatingCrest(value: overall, size: 60)

                VStack(alignment: .leading, spacing: 2) {
                    Text(RatingBand.label(for: overall))
                        .font(TamrinFont.font(size: 17, weight: .bold))

                    // Naming the weighting is what keeps the number from looking
                    // arbitrary: a defender's Overall is not a striker's average.
                    Text("محسوب بأوزان مركز \(position.rawValue)")
                        .font(TamrinFont.font(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            AttributeGrid(scores: scores, onSelect: { attribute in
                Haptics.selection()
                stepIndex = PlayerAttribute.allCases.firstIndex(of: attribute) ?? 0
            })

            Label(
                "التقييمات مجهولة، واللاعب يشوف متوسط تقييمه فقط.",
                systemImage: "eye.slash.fill"
            )
            .font(TamrinFont.font(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(TamrinTheme.card, in: .rect(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            if stepIndex > 0 {
                // A circular icon button, sized by the system rather than by a
                // frame of mine: asking a capsule to hold one glyph is what
                // produced a ball taller than the primary beside it.
                Button {
                    Haptics.selection()
                    stepIndex -= 1
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel("رجوع")
            }

            Button {
                advance()
            } label: {
                HStack(spacing: 8) {
                    if isSubmitting {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    Text(primaryTitle)
                        .font(TamrinFont.font(size: 16, weight: .bold))
                }
                .frame(maxWidth: .infinity)
            }
            // Blue: the same forward motion the registration flow uses.
            .tamrinPrimaryAction(tint: ratingForward)
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
            errorMessage = ServerErrorMessage.arabic(for: error)
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
                    .fill(index <= current ? ratingForward : Color.primary.opacity(0.12))
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
