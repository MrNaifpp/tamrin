import ActivityKit
import SwiftUI
import WidgetKit

/// The extension ships no string catalog and may not run in the app's per-app
/// language, so its copy follows the language the app recorded on the
/// activity: each string is written here in both languages.
struct LiveActivityCopy {
    let isArabic: Bool

    func callAsFunction(_ arabic: String, _ english: String) -> String {
        isArabic ? arabic : english
    }

    var layoutDirection: LayoutDirection { isArabic ? .rightToLeft : .leftToRight }

    /// Western digits in both languages.
    var locale: Locale {
        Locale(identifier: isArabic ? "ar_SA@numbers=latn" : "en_US")
    }
}

extension WorkoutActivityAttributes {
    var copy: LiveActivityCopy { LiveActivityCopy(isArabic: isArabic) }
}

struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color(red: 0.055, green: 0.055, blue: 0.065).opacity(0.94))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.attributes.eventURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WorkoutMark(size: 26, copy: context.attributes.copy)
                        .padding(.leading, 6)
                        .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandCountdown(startDate: context.state.startDate, isStale: context.isStale, copy: context.attributes.copy)
                        .padding(.trailing, 6)
                        .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(context.attributes.title).font(WorkoutFont.headline).lineLimit(1)
                            Text(context.attributes.venueName)
                                .font(WorkoutFont.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let url = context.attributes.directionsURL {
                            DirectionsLink(url: url, copy: context.attributes.copy)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .environment(\.layoutDirection, context.attributes.copy.layoutDirection)
                }
            } compactLeading: {
                WorkoutMark(size: 20, copy: context.attributes.copy)
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .environment(\.layoutDirection, .leftToRight)
            } compactTrailing: {
                IslandCountdown(startDate: context.state.startDate, isStale: context.isStale, copy: context.attributes.copy)
                    .frame(width: 60, alignment: .trailing)
                    .padding(.leading, 4)
                    .padding(.trailing, 12)
                    .environment(\.layoutDirection, .leftToRight)
            } minimal: {
                WorkoutMark(size: 18, copy: context.attributes.copy)
            }
            .keylineTint(.white.opacity(0.25))
            .widgetURL(context.attributes.eventURL)
        }
    }
}

struct WorkoutLockScreenView: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(attributes.title)
                        .font(WorkoutFont.font(size: 20, weight: .medium).weight(.semibold))
                        .lineLimit(1)
                        .frame(height: 24)
                    if !attributes.venueName.isEmpty {
                        Text(attributes.venueName)
                            .font(WorkoutFont.font(size: 14))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                            .frame(height: 18)
                    }
                }
                Spacer(minLength: 4)
                if let url = attributes.directionsURL { DirectionsLink(url: url, copy: attributes.copy) }
            }
            VStack(spacing: 0) {
                Text(attributes.copy("يبدأ بعد", "Starts in"))
                    .font(WorkoutFont.font(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(height: 16)
                    .padding(.vertical, 6)

                CountdownText(
                    startDate: state.startDate,
                    size: 46,
                    staleSize: 28,
                    isStale: isStale,
                    copy: attributes.copy
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 52)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .environment(\.layoutDirection, attributes.copy.layoutDirection)
    }
}

private struct CountdownText: View {
    let startDate: Date
    let size: CGFloat
    let staleSize: CGFloat
    let isStale: Bool
    let copy: LiveActivityCopy
    var compactStaleText = false

    @ViewBuilder
    var body: some View {
        if isStale {
            Text(compactStaleText ? copy("الآن", "Now") : copy("حان وقت التمرين", "Time to play"))
                .font(WorkoutFont.font(size: staleSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Text(startDate, style: .timer)
                .font(WorkoutFont.font(size: size, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .environment(\.locale, copy.locale)
                .accessibilityLabel(copy("الوقت المتبقي", "Time remaining"))
        }
    }
}

private struct DirectionsLink: View {
    let url: URL
    let copy: LiveActivityCopy
    var body: some View {
        Link(destination: url) {
            Label(copy("الموقع", "Location"), systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                .font(WorkoutFont.font(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(.white.opacity(0.1), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copy("الاتجاهات إلى الملعب", "Directions to the venue"))
        .accessibilityHint(copy("يفتح هدهد إذا كان متوفرًا، وإلا خرائط Google", "Opens Hudhud if available, otherwise Google Maps"))
    }
}

private struct IslandCountdown: View {
    let startDate: Date
    let isStale: Bool
    let copy: LiveActivityCopy
    var body: some View {
        Group {
            if isStale {
                Text(verbatim: "0:00:00")
            } else {
                Text(timerInterval: startDate.addingTimeInterval(-86400)...startDate,
                     countsDown: true, showsHours: true)
                    .multilineTextAlignment(.trailing)
            }
        }
        .font(WorkoutFont.font(size: 14, weight: .bold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .lineLimit(1)
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .accessibilityLabel(copy("الوقت المتبقي بالساعات والدقائق والثواني", "Time remaining in hours, minutes and seconds"))
    }
}

private struct WorkoutMark: View {
    let size: CGFloat
    let copy: LiveActivityCopy
    var body: some View {
        Image("WorkoutLogo")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .accessibilityLabel(copy("تمرين", "Tamrin"))
    }
}

#Preview("شاشة القفل", as: .content, using: WorkoutActivityAttributes.preview) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivityAttributes.ContentState.preview
}

#Preview("Dynamic Island", as: .dynamicIsland(.compact), using: WorkoutActivityAttributes.preview) {
    WorkoutLiveActivity()
} contentStates: {
    WorkoutActivityAttributes.ContentState.preview
}

private extension WorkoutActivityAttributes {
    static let preview = WorkoutActivityAttributes(
        eventID: "00000000-0000-0000-0000-000000000001",
        title: "تمرين الخميس", venueName: "استاد الملك فهد الدولي",
        latitude: 24.8262878, longitude: 46.6189421
    )
}
private extension WorkoutActivityAttributes.ContentState {
    static let preview = WorkoutActivityAttributes.ContentState(
        startTimestamp: Date.now.addingTimeInterval(95 * 60).timeIntervalSince1970
    )
}
