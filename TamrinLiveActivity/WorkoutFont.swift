import SwiftUI
import CoreText
import UIKit

enum WorkoutFontWeight {
    case light, regular, medium, bold

    var postScriptName: String {
        switch self {
        case .light: "Thmanyahsans12-Light"
        case .regular: "Thmanyahsans12-Regular"
        case .medium: "Thmanyahsans12-Medium"
        case .bold: "Thmanyahsans12-Bold"
        }
    }

    init(_ weight: Font.Weight) {
        switch weight {
        case .ultraLight, .thin, .light:
            self = .light
        case .medium:
            self = .medium
        case .semibold, .bold, .heavy, .black:
            self = .bold
        default:
            self = .regular
        }
    }
}

enum WorkoutFont {
    /// Thmanyah's identity alternates. CoreText enables Arabic shaping,
    /// ligatures, kerning and marks automatically; `ss01` is the intentional
    /// brand alternate and must stay enabled everywhere text is rendered.
    private static let brandFeatures: [[UIFontDescriptor.FeatureKey: Any]] = [
        [
            .type: kStylisticAlternativesType,
            .selector: kStylisticAltOneOnSelector
        ]
    ]

    static func uiFont(size: CGFloat, weight: WorkoutFontWeight = .regular) -> UIFont {
        guard let base = UIFont(name: weight.postScriptName, size: size) else {
            preconditionFailure("Missing bundled Thmanyah font: \(weight.postScriptName)")
        }
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: brandFeatures
        ])
        let result = UIFont(descriptor: descriptor, size: size)
        precondition(
            result.fontName == weight.postScriptName,
            "Unexpected font fallback: \(result.fontName)"
        )
        return result
    }

    static func font(size: CGFloat, weight: WorkoutFontWeight = .regular) -> Font {
        Font(uiFont(size: size, weight: weight) as CTFont)
    }

    static let body = font(size: 17, weight: .regular)
    static let caption = font(size: 12, weight: .medium)
    static let footnote = font(size: 13, weight: .regular)
    static let subheadline = font(size: 15, weight: .regular)
    static let headline = font(size: 17, weight: .medium)
    static let title3 = font(size: 20, weight: .bold)
    static let title2 = font(size: 24, weight: .bold)
    static let title = font(size: 30, weight: .bold)
    static let largeTitle = font(size: 40, weight: .bold)
    static let display = font(size: 46, weight: .bold)
}

