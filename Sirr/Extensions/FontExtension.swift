//
//  FontExtension.swift
//  Sirr
//
//  App-wide Thmanyah typography aliases
//

import SwiftUI

extension Font {
    /// Compatibility entry point used by the legacy screens. It deliberately
    /// routes through the same Thmanyah + ss01 builder as the current UI.
    static func appFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        TamrinFont.font(size: size, weight: TamrinFontWeight(weight))
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

struct CustomFontModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.font, TamrinFont.body)
    }
}

extension View {
    func applyAppFont() -> some View {
        modifier(CustomFontModifier())
    }
}
