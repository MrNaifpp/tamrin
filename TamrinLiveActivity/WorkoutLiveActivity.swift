import ActivityKit
import SwiftUI
import WidgetKit

struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLockScreenView(context: context)
                .activityBackgroundTint(WorkoutLiveActivityStyle.background)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.eventURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WorkoutMark(size: 32)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(
                        startDate: context.state.startDate,
                        size: 17,
                        isStale: context.isStale
                    )
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.attributes.title)
                                .font(.headline)
                                .lineLimit(1)

                            if !context.attributes.venueName.isEmpty {
                                Text(context.attributes.venueName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 8)

                        if let directionsURL = context.attributes.directionsURL {
                            Link(destination: directionsURL) {
                                Label("الموقع", systemImage: "location.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(WorkoutLiveActivityStyle.accent, in: .capsule)
                            }
                            .accessibilityLabel("الموقع")
                            .accessibilityHint("يفتح الاتجاهات إلى الملعب في هدهد")
                        }
                    }
                    .environment(\.layoutDirection, .rightToLeft)
                }
            } compactLeading: {
                WorkoutMark(size: 20)
            } compactTrailing: {
                if context.isStale {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(WorkoutLiveActivityStyle.accent)
                        .accessibilityLabel("حان وقت التمرين")
                } else {
                    CountdownText(startDate: context.state.startDate, size: 13, isStale: false)
                        .frame(maxWidth: 54)
                }
            } minimal: {
                Image(systemName: "figure.run")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WorkoutLiveActivityStyle.accent)
                    .accessibilityLabel("تمرين قادم")
            }
            .keylineTint(WorkoutLiveActivityStyle.accent)
            .widgetURL(context.attributes.eventURL)
        }
    }
}

private struct WorkoutLockScreenView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                WorkoutMark(size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("التمرين القادم")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))

                    Text(context.attributes.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("يبدأ بعد")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))

                    CountdownText(
                        startDate: context.state.startDate,
                        size: 22,
                        isStale: context.isStale
                    )
                }
            }

            HStack(spacing: 10) {
                if !context.attributes.venueName.isEmpty {
                    Label(context.attributes.venueName, systemImage: "sportscourt.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let directionsURL = context.attributes.directionsURL {
                    Link(destination: directionsURL) {
                        Label("الموقع", systemImage: "location.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(WorkoutLiveActivityStyle.accent, in: .capsule)
                    }
                    .accessibilityLabel("الموقع")
                    .accessibilityHint("يفتح الاتجاهات إلى الملعب في هدهد")
                }
            }
        }
        .padding(16)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

private struct CountdownText: View {
    let startDate: Date
    let size: CGFloat
    let isStale: Bool

    @ViewBuilder
    var body: some View {
        if isStale {
            Text("حان وقت التمرين")
                .font(.system(size: min(size, 16), weight: .bold, design: .rounded))
                .foregroundStyle(WorkoutLiveActivityStyle.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Text(startDate, style: .timer)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(WorkoutLiveActivityStyle.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel("الوقت المتبقي")
        }
    }
}

private struct WorkoutMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "figure.run")
            .font(.system(size: size * 0.48, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(WorkoutLiveActivityStyle.accent, in: .circle)
            .accessibilityHidden(true)
    }
}

private enum WorkoutLiveActivityStyle {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.065)
    static let accent = Color(red: 0.78, green: 1.0, blue: 0.18)
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
