import SwiftUI

/// Stands where the list will be until registration opens: the time left,
/// large, and the moment it ends. The organizer gets the way to open it now.
struct RegistrationCountdownPanel: View {
    let opensAt: Date
    var isOpening = false
    var onOpenNow: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            Text("يفتح التسجيل بعد")
                .font(TamrinFont.font(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let parts = Self.parts(until: opensAt, from: context.date)
                HStack(spacing: 8) {
                    unit(parts.days, label: String(localized: "يوم"))
                    separator
                    unit(parts.hours, label: String(localized: "ساعة"))
                    separator
                    unit(parts.minutes, label: String(localized: "دقيقة"))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.accessibilityText(parts))
            }

            Text("يوم \(opensAt.arabicDay)، الساعة \(opensAt.arabicTime)")
                .font(TamrinFont.font(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            if let onOpenNow {
                Button {
                    Haptics.impact(.medium)
                    onOpenNow()
                } label: {
                    Group {
                        if isOpening {
                            ProgressView().tint(.white)
                        } else {
                            Label("افتح التسجيل الآن", systemImage: "lock.open.fill")
                        }
                    }
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: TamrinControlMetrics.glassActionHeight)
                    .contentShape(.capsule)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .disabled(isOpening)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .tamrinGlassCard()
    }

    private func unit(_ value: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value.formatted(.number.locale(.tamrin).precision(.integerLength(2...))))
                .font(TamrinFont.font(size: 40, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.smooth(duration: 0.3), value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(TamrinFont.font(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    private var separator: some View {
        Text(":")
            .font(TamrinFont.font(size: 30, weight: .bold))
            .foregroundStyle(.white.opacity(0.35))
            .padding(.bottom, 20)
    }

    struct Parts: Equatable {
        var days = 0, hours = 0, minutes = 0
    }

    /// Rounded up to the minute, so the last minute reads 00:00:01 until the
    /// moment it opens rather than sitting on zero.
    static func parts(until target: Date, from now: Date) -> Parts {
        let seconds = max(0, target.timeIntervalSince(now))
        let total = Int((seconds / 60).rounded(.up))
        return Parts(
            days: total / 1440,
            hours: total % 1440 / 60,
            minutes: total % 60
        )
    }

    private static func accessibilityText(_ parts: Parts) -> String {
        let format = String(localized: "يفتح التسجيل بعد \(parts.days) يوم و\(parts.hours) ساعة و\(parts.minutes) دقيقة")
        return format
    }
}
