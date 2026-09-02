import CoreText
import SwiftUI
import UIKit

private enum TamrinLiveActivityFontWeight {
    case regular
    case medium
    case bold

    var postScriptName: String {
        switch self {
        case .regular:
            "Thmanyahsans12-Regular"
        case .medium:
            "Thmanyahsans12-Medium"
        case .bold:
            "Thmanyahsans12-Bold"
        }
    }
}

enum TamrinLiveActivityFont {
    /// Matches the app-wide Thmanyah typography, including its brand alternate.
    private static let brandFeatures: [[UIFontDescriptor.FeatureKey: Any]] = [
        [
            .type: kStylisticAlternativesType,
            .selector: kStylisticAltOneOnSelector
        ]
    ]

    static func regular(_ size: CGFloat) -> Font {
        font(size: size, weight: .regular)
    }

    static func medium(_ size: CGFloat) -> Font {
        font(size: size, weight: .medium)
    }

    static func bold(_ size: CGFloat) -> Font {
        font(size: size, weight: .bold)
    }

    private static func font(size: CGFloat, weight: TamrinLiveActivityFontWeight) -> Font {
        guard let base = UIFont(name: weight.postScriptName, size: size) else {
            preconditionFailure("Missing bundled Thmanyah font: \(weight.postScriptName)")
        }

        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: brandFeatures
        ])
        let result = UIFont(descriptor: descriptor, size: size)
        return Font(result as CTFont)
    }
}
