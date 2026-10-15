import SwiftUI

/// The last change to the rounded group total, shared by every viewer.
/// There is deliberately no identity or individual rating in this value.
struct PlayerRatingChange: Equatable {
    let previousOverall: Int
    let currentOverall: Int
    let changedAt: Date

    var delta: Int { currentOverall - previousOverall }
    var symbol: String { delta > 0 ? "arrow.up.right" : "arrow.down.right" }
    var explanation: String {
        let amount = abs(delta).tamrinNumber
        let date = changedAt.arabicDate
        return delta > 0
            ? String(localized: "ارتفع التقييم الإجمالي بمقدار \(amount)، آخر تغيّر في \(date)")
            : String(localized: "انخفض التقييم الإجمالي بمقدار \(amount)، آخر تغيّر في \(date)")
    }
}

struct RatingChangeIndicator: View {
    let change: PlayerRatingChange
    var compact = false
    var onLightArtwork = false
    var interactive = true
    @State private var showsExplanation = false

    var body: some View {
        Group {
            if interactive {
                Button { showsExplanation = true } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityLabel(change.explanation)
        .alert("تغيّر التقييم", isPresented: $showsExplanation) {
            Button("حسنًا", role: .cancel) {}
        } message: {
            Text(change.explanation + "\n" + String(localized: "يعكس التغيّر في متوسط تقييمات المجموعة، وليس تقييم شخص بعينه."))
        }
    }

    private var content: some View {
            HStack(spacing: 5) {
                Image(systemName: change.symbol)
                Text(abs(change.delta).tamrinNumber).monospacedDigit()
                if !compact { Text("آخر تغيّر") }
            }
            .font(TamrinFont.font(size: compact ? 14 : 12, weight: .medium))
            .foregroundStyle(change.delta > 0
                             ? (onLightArtwork ? Color(red: 0.12, green: 0.40, blue: 0.27) : Color.green)
                             : (onLightArtwork ? Color(red: 0.65, green: 0.22, blue: 0.16) : Color.orange))
            .padding(.vertical, 6)
            .contentShape(.rect)
    }
}
