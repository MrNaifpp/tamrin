//
//  FontExtensionAlt.swift
//  Sirr
//
//  Compatibility helper retained for older call sites.
//

import SwiftUI

extension Font {
    static func tryCustomFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        TamrinFont.font(size: size, weight: TamrinFontWeight(weight))
    }
}

