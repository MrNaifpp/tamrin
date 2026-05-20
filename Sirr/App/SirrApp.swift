//
//  SirrApp.swift
//  Sirr
//
//  Created by فارس أبومالح on 07/04/1447 AH.
//

import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@main
struct SirrApp: App {
    private let isRunningForPreviews: Bool

    init() {
        isRunningForPreviews = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"

        guard !isRunningForPreviews else {
            return
        }

        registerBundledFonts()
        setupAppFont()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .applyAppFont()
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar_SA"))
#if os(macOS)
                .frame(minWidth: 1240, minHeight: 820)
#endif
        }
#if os(macOS)
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
#endif
    }
    
    private func setupAppFont() {
        #if canImport(UIKit)
        UIView.appearance().semanticContentAttribute = .forceRightToLeft
        if let customFont = UIFont(name: "TheYearofHandicrafts-Regular", size: 18) {
            UILabel.appearance().font = customFont
            UITextField.appearance().font = customFont
            UITextView.appearance().font = customFont
        }
        #endif
    }

    private func registerBundledFonts() {
        let fontFiles = [
            "TheYearofHandicrafts-Regular",
            "TheYearofHandicrafts-Medium",
            "TheYearofHandicrafts-SemiBold",
            "TheYearofHandicrafts-Bold",
            "TheYearofHandicrafts-Black"
        ]

        for fileName in fontFiles {
            guard let fontURL = Bundle.main.url(forResource: fileName, withExtension: "otf"),
                  let fontDataProvider = CGDataProvider(url: fontURL as CFURL),
                  let font = CGFont(fontDataProvider) else {
                continue
            }

            CTFontManagerRegisterGraphicsFont(font, nil)
        }
    }
}
