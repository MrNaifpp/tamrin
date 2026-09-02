import ActivityKit
import SwiftUI
import WidgetKit

struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLockScreenView(context: context)
                .activityBackgroundTint(WorkoutLiveActivityStyle.background)
                .activitySystemActionForegroundColor(.white)
                .environment(\.locale, WorkoutLiveActivityStyle.locale)
                .widgetURL(context.attributes.eventURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.title)
                        .font(TamrinLiveActivityFont.medium(14))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: 148, alignment: .leading)
                        .environment(\.layoutDirection, .rightToLeft)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text("يبدأ بعد")
                        .font(TamrinLiveActivityFont.regular(11))
                        .foregroundStyle(WorkoutLiveActivityStyle.secondaryText)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        CountdownText(
                            startDate: context.state.startDate,
                            size: 38,
                            staleSize: 24,
                            isStale: context.isStale
                        )
                        .frame(maxWidth: .infinity, minHeight: 42, alignment: .center)

                        HStack(spacing: 10) {
                            if !context.attributes.venueName.isEmpty {
                                Text(context.attributes.venueName)
                                    .font(TamrinLiveActivityFont.regular(12))
                                    .foregroundStyle(WorkoutLiveActivityStyle.secondaryText)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            if let directionsURL = context.attributes.directionsURL {
                                WorkoutLocationButton(destination: directionsURL, compact: true)
                            }
                        }
                    }
                    .padding(.top, 3)
                    .environment(\.layoutDirection, .rightToLeft)
                }
            } compactLeading: {
                Text("تمرين")
                    .font(TamrinLiveActivityFont.medium(11))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .environment(\.layoutDirection, .rightToLeft)
                    .accessibilityLabel("تمرين قادم")
            } compactTrailing: {
                CountdownText(
                    startDate: context.state.startDate,
                    size: 15,
                    staleSize: 13,
                    isStale: context.isStale,
                    compactStaleText: true
                )
                .frame(width: 62, alignment: .trailing)
            } minimal: {
                Text("ت")
                    .font(TamrinLiveActivityFont.bold(15))
                    .foregroundStyle(.white)
                    .accessibilityLabel("تمرين قادم")
            }
            .keylineTint(.white.opacity(0.35))
            .widgetURL(context.attributes.eventURL)
        }
    }
}

private struct WorkoutLockScreenView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("التمرين القادم")
                        .font(TamrinLiveActivityFont.medium(12))
                        .foregroundStyle(WorkoutLiveActivityStyle.secondaryText)

                    Text(context.attributes.title)
                        .font(TamrinLiveActivityFont.medium(17))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if !context.attributes.venueName.isEmpty {
                        Text(context.attributes.venueName)
                            .font(TamrinLiveActivityFont.regular(13))
                            .foregroundStyle(WorkoutLiveActivityStyle.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let directionsURL = context.attributes.directionsURL {
                    WorkoutLocationButton(destination: directionsURL)
                }
            }

            VStack(spacing: 0) {
                Text("يبدأ بعد")
                    .font(TamrinLiveActivityFont.regular(12))
                    .foregroundStyle(WorkoutLiveActivityStyle.secondaryText)

                CountdownText(
                    startDate: context.state.startDate,
                    size: 46,
                    staleSize: 28,
                    isStale: context.isStale
                )
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

private struct WorkoutLocationButton: View {
    let destination: URL
    var compact = false

    var body: some View {
        Link(destination: destination) {
            Text("الموقع")
                .font(compact ? TamrinLiveActivityFont.medium(11) : TamrinLiveActivityFont.medium(13))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 11 : 14)
                .frame(height: compact ? 30 : 38)
                .background(WorkoutLiveActivityStyle.buttonFill, in: .capsule)
                .overlay {
                    Capsule()
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("الموقع")
        .accessibilityHint("يفتح الاتجاهات إلى الملعب في هدهد")
    }
}

private struct CountdownText: View {
    let startDate: Date
    let size: CGFloat
    let staleSize: CGFloat
    let isStale: Bool
    var compactStaleText = false

    @ViewBuilder
    var body: some View {
        if isStale {
            Text(compactStaleText ? "الآن" : "حان وقت التمرين")
                .font(TamrinLiveActivityFont.bold(staleSize))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Text(startDate, style: .timer)
                .font(TamrinLiveActivityFont.bold(size))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .environment(\.locale, WorkoutLiveActivityStyle.locale)
                .accessibilityLabel("الوقت المتبقي")
        }
    }
}

private enum WorkoutLiveActivityStyle {
    static let locale = Locale(identifier: "ar_SA@numbers=latn")
    static let background = Color(white: 0.058)
    static let secondaryText = Color.white.opacity(0.62)
    static let buttonFill = Color.white.opacity(0.1)
}

#Preview("شاشة القفل", as: .content, using: WorkoutActivityAttributes.preview) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivityAttributes.ContentState.preview
}

#Preview("Dynamic Island", as: .dynamicIsland(.expanded), using: WorkoutActivityAttributes.preview) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivityAttributes.ContentState.preview
}

private extension WorkoutActivityAttributes {
    static let preview = WorkoutActivityAttributes(
        eventID: "00000000-0000-0000-0000-000000000001",
        title: "تمرين الخميس",
        venueName: "ملعب النخيل",
        latitude: 24.7743,
        longitude: 46.7386
    )
}

private extension WorkoutActivityAttributes.ContentState {
    static let preview = WorkoutActivityAttributes.ContentState(
        startTimestamp: Date.now.addingTimeInterval(75 * 60).timeIntervalSince1970
    )
}
