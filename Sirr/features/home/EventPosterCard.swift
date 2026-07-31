import SwiftUI

struct EventPosterCardAction: Identifiable {
    enum Kind {
        case primary
        case secondary
        case destructive
        case status
    }

    let id: String
    let title: String
    let systemImage: String
    let kind: Kind
    let isEnabled: Bool
    let isLoading: Bool
    let action: () -> Void

    init(
        id: String,
        title: String,
        systemImage: String,
        kind: Kind = .secondary,
        isEnabled: Bool = true,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.isEnabled = isEnabled
        self.isLoading = isLoading
        self.action = action
    }
}

/// Poster-style event card with an optional owner action bar. The details
/// button and action buttons are siblings so SwiftUI never nests buttons.
struct EventPosterCard: View {
    let occurrence: FeedOccurrence
    let registeredCount: Int
    let actions: [EventPosterCardAction]
    let action: () -> Void

    init(
        occurrence: FeedOccurrence,
        registeredCount: Int,
        actions: [EventPosterCardAction] = [],
        action: @escaping () -> Void
    ) {
        self.occurrence = occurrence
        self.registeredCount = registeredCount
        self.actions = actions
        self.action = action
    }

    /// A swipe that starts on the card is meant for the groups drawer (or the
    /// vertical card scroll), not for opening the event. The card fills the
    /// screen, so a swipe never leaves its bounds and SwiftUI would otherwise
    /// still count the release as a tap. Track the pan and drop the tap once
    /// the finger has clearly moved.
    @State private var didPan = false

    /// Enough travel to read as a swipe rather than a shaky finger.
    private let panSlop: CGFloat = 10

    private var artName: String { "ExerciseArt\((occurrence.artIndex % 3) + 1)" }
    private var hasActions: Bool { !actions.isEmpty }

    var body: some View {
        ZStack(alignment: .bottom) {
            Button {
                guard !didPan else { return }
                action()
            } label: {
                posterContent
            }
            .buttonStyle(SpringCardPressStyle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // The first change of a new touch reports no travel —
                        // use it to arm the next press rather than resetting on
                        // end, which would race the button's own action.
                        if value.translation == .zero {
                            didPan = false
                        } else if abs(value.translation.width) > panSlop
                                    || abs(value.translation.height) > panSlop {
                            didPan = true
                        }
                    }
            )
            .accessibilityLabel("\(occurrence.title)، \(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
            .accessibilityHint("يفتح تفاصيل الموعد")

            if hasActions {
                actionBar
                    .padding(16)
            }
        }
        .clipShape(.rect(cornerRadius: 36, style: .continuous))
        .contentShape(.rect(cornerRadius: 36, style: .continuous))
    }

    private var posterContent: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .overlay {
                    Image(artName)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }

            VStack(spacing: 7) {
                if occurrence.isCancelled {
                    Text("تم التخطي")
                        .font(TamrinFont.font(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13).padding(.vertical, 6)
                        .background(.red.opacity(0.85), in: .capsule)
                } else if occurrence.isRecurring {
                    Label("أسبوعيًا", systemImage: "repeat")
                        .font(TamrinFont.font(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white.opacity(0.18), in: .capsule)
                }

                Text(occurrence.title)
                    .font(TamrinFont.font(size: 27, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.7)

                Text("\(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .opacity(0.82)

                Text("\(occurrence.locationName) · \(registeredCount)/\(occurrence.capacity) · \(occurrence.price == 0 ? "مجاني" : "\(occurrence.price.cleanAmount) ﷼")")
                    .font(TamrinFont.font(size: 12, weight: .regular))
                    .opacity(0.68).lineLimit(1)
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.top, 72)
            .padding(.bottom, hasActions ? 136 : 56)
            .frame(maxWidth: .infinity)
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.10)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.55), location: 0.5),
                        .init(color: .black, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
            }
            .colorScheme(.dark)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            ForEach(actions) { item in
                EventPosterCardActionCell(item: item)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.black.opacity(0.28))
                }
        }
        .colorScheme(.dark)
        .accessibilityElement(children: .contain)
    }
}

private struct EventPosterCardActionCell: View {
    let item: EventPosterCardAction

    private var symbolColor: Color {
        switch item.kind {
        case .primary:
            TamrinTheme.lime
        case .secondary:
            .white.opacity(0.84)
        case .destructive:
            .white.opacity(0.72)
        case .status:
            TamrinTheme.lime
        }
    }

    private var accessibilityValue: String {
        if item.isLoading { return "جارٍ التنفيذ" }
        if item.kind == .status { return "مكتمل" }
        if !item.isEnabled { return "غير متاح حاليًا" }
        return ""
    }

    var body: some View {
        Button(action: item.action) {
            VStack(spacing: 5) {
                Group {
                    if item.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(symbolColor)
                    } else {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(symbolColor)
                    }
                }
                .frame(height: 24)
                .accessibilityHidden(true)

                Text(item.title)
                    .font(TamrinFont.font(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(EventActionPressStyle())
        .disabled(!item.isEnabled || item.isLoading)
        .opacity(item.isEnabled || item.kind == .status ? 1 : 0.42)
        .accessibilityLabel(item.title)
        .accessibilityValue(accessibilityValue)
    }
}

private struct EventActionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.62 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct EmptyScheduleCard: View {
    @Environment(\.colorScheme) private var colorScheme

    /// `secondarySystemBackground` sits at roughly the same value as the page
    /// behind it in dark mode, so the card had almost no edge. Lift it into its
    /// own step above the background instead.
    private var surface: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.19, alpha: 1)
                : .secondarySystemBackground
        })
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(surface)

            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.white.opacity(0.05), .clear]
                    : [Color.white.opacity(0.92), Color(uiColor: .secondarySystemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(.rect(cornerRadius: 36, style: .continuous))

            VStack(spacing: 13) {
                Image(systemName: "calendar")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, height: 58)
                    .background(Color(uiColor: .tertiarySystemFill), in: .circle)

                Text("ما فيه مواعيد قادمة")
                    .font(TamrinFont.headline)
                    .foregroundStyle(.primary)

                Text("المواعيد الجديدة بتظهر هنا أول ما تُنشر.")
                    .font(TamrinFont.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect(cornerRadius: 36, style: .continuous))
    }
}

#Preview {
    let occ = FeedOccurrence(id: UUID(), title: "كورة الثلاثاء", startAt: Date(),
                             locationName: "ملعب النخيل", capacity: 14,
                             price: 25, isCancelled: false, artIndex: 0)
    return EventPosterCard(occurrence: occ, registeredCount: 9, action: {})
        .frame(height: 420).padding()
        .environment(\.layoutDirection, .rightToLeft)
}
