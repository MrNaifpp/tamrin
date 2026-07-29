import UIKit

/// Single gate for every haptic in the app, so one settings toggle can switch
/// them all off. Call sites read the same as the raw generators they replaced.
@MainActor
enum Haptics {
    /// The settings sheet binds `@AppStorage` to this same key, so flipping the
    /// toggle is immediately visible here — no observation plumbing needed.
    static let enabledKey = "settings.hapticsEnabled"

    /// Absent means the toggle was never touched, and haptics ship on.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func selection() {
        guard isEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat? = nil) {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        if let intensity {
            generator.impactOccurred(intensity: intensity)
        } else {
            generator.impactOccurred()
        }
    }
}
