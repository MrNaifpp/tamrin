//
//  FontExtension.swift
//  Sirr
//
//  Font configuration for the app
//

import SwiftUI

extension Font {
    // Custom font: TheYearofHandicrafts (خط عام الحرف)
    static func yearOfHandicrafts(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let fontName: String
        
        switch weight {
        case .black, .heavy:
            fontName = "TheYearofHandicrafts-Black"
        case .bold:
            fontName = "TheYearofHandicrafts-Bold"
        case .semibold:
            fontName = "TheYearofHandicrafts-SemiBold"
        case .medium:
            fontName = "TheYearofHandicrafts-Medium"
        default:
            fontName = "TheYearofHandicrafts-Regular"
        }
        
        // Try to use custom font, fallback to system font
        return Font.custom(fontName, size: size)
    }
    
    // App-wide font defaults
    static func appFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        return yearOfHandicrafts(size: size, weight: weight)
    }
    
    // Common font sizes
    static let appTitle = appFont(size: 32, weight: .bold)
    static let appLargeTitle = appFont(size: 30, weight: .bold)
    static let appHeadline = appFont(size: 28, weight: .semibold)
    static let appSubheadline = appFont(size: 20, weight: .semibold)
    static let appBody = appFont(size: 18, weight: .regular)
    static let appBodyMedium = appFont(size: 18, weight: .medium)
    static let appBodySemibold = appFont(size: 18, weight: .semibold)
    static let appCallout = appFont(size: 16, weight: .semibold)
    static let appCaption = appFont(size: 12, weight: .medium)
}

// View modifier to apply custom font globally
struct CustomFontModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.font, .appBody)
    }
}

extension View {
    func applyAppFont() -> some View {
        modifier(CustomFontModifier())
    }
}

