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

/// Publish state of an event, shown as a tag at the top of its card. Only
/// organizers ever see it: members are shown published events alone.
enum EventPosterPublishTag {
    case published
    case unpublished
}

/// Poster-style event card with an optional owner action bar. The details
/// button, the publish tag and the action buttons are siblings so SwiftUI
/// never nests buttons.
struct EventPosterCard: View {
    let occurrence: FeedOccurrence
    let registeredCount: Int
    let publishTag: EventPosterPublishTag?
    let actions: [EventPosterCardAction]
    let action: () -> Void

    init(
        occurrence: FeedOccurrence,
        registeredCount: Int,
        publishTag: EventPosterPublishTag? = nil,
        actions: [EventPosterCardAction] = [],
        action: @escaping () -> Void
    ) {
        self.occurrence = occurrence
        self.registeredCount = registeredCount
        self.publishTag = publishTag
        self.actions = actions
        self.action = action
    }

    private var artName: String { "ExerciseArt\((occurrence.artIndex % 3) + 1)" }
    private var hasActions: Bool { !actions.isEmpty }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Deliberately no gesture of its own: any DragGesture attached to
            // the card — even .simultaneousGesture with a slop — competes with
            // the home ScrollView's pan and made the card stack unscrollable
            // (the card fills the screen, so every scroll starts on it). The
            // swipe-must-not-tap suppression lives with the drawer gesture in
            // DesignerHomeView, which observes pans without blocking scroll.
            Button(action: action) {
                posterContent
            }
            .buttonStyle(SpringCardPressStyle())
            .accessibilityLabel("\(occurrence.title)، \(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
            .accessibilityHint("يفتح تفاصيل الموعد")

            if hasActions {
                actionBar
                    .padding(16)
            }
        }
        // `.trailing` is the physical left edge: the card lives inside the
        // app's RTL environment, so the tag sits opposite the reading edge.
        .overlay(alignment: .topTrailing) {
            if let publishTag {
                EventPosterPublishTagView(state: publishTag)
                    .padding(.top, 20)
                    .padding(.trailing, 20)
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
                    Text("متخطّى")
                        .font(TamrinFont.font(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13).padding(.vertical, 6)
                        .background(.red.opacity(0.85), in: .capsule)
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

/// Tinted glass capsule telling the organizer whether members can see this
/// event yet. Tapping it explains what the state means, anchored to the tag
/// itself so the answer arrives where the question was asked.
private struct EventPosterPublishTagView: View {
    let state: EventPosterPublishTag

    @State private var isExplanationPresented = false

    private var isPublished: Bool { state == .published }
    private var title: String { isPublished ? "منشور" : "غير منشور" }
    private var tint: Color { isPublished ? TamrinTheme.brandGreen : Color(white: 0.92) }
    /// Both labels are the capsule's own colour taken darker: a deep green on
    /// the green tag, and plain ink at half strength on the near-white one.
    private var labelColor: Color {
        isPublished ? Color(red: 0.16, green: 0.47, blue: 0.28) : .black.opacity(0.5)
    }

    private var explanation: String {
        isPublished
            ? "هذا الموعد ظاهر لأعضاء التمرين وتصلهم إشعاراته."
            : "هذا الموعد غير ظاهر للأعضاء وسيظهر لهم اذا نشرته."
    }

    var body: some View {
        Button {
            Haptics.impact(.light)
            isExplanationPresented = true
        } label: {
            Text(title)
                .font(TamrinFont.font(size: 14, weight: .bold))
                .foregroundStyle(labelColor)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(tint.opacity(0.55)).interactive(), in: .capsule)
        .popover(isPresented: $isExplanationPresented, arrowEdge: .bottom) {
            Text(explanation)
                .font(TamrinFont.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(width: 260)
                .environment(\.layoutDirection, .rightToLeft)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("حالة الموعد: \(title)")
        .accessibilityHint("يعرض شرحًا لحالة النشر")
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
    return EventPosterCard(occurrence: occ, registeredCount: 9, publishTag: .unpublished, action: {})
        .frame(height: 420).padding()
        .environment(\.layoutDirection, .rightToLeft)
}
