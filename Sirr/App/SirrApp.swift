//
//  SirrApp.swift
//  Sirr
//
//  Created by فارس أبومالح on 07/04/1447 AH.
//

import SwiftUI

@main
struct SirrApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    init() {
        // Configure app-wide font settings
        setupAppFont()
    }
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .applyAppFont()
                // Anything that formats against the environment locale rather
                // than passing one explicitly still has to land on 0123456789.
                .environment(\.locale, .tamrin)
                .onOpenURL { url in
                    DeepLinkRouter.shared.submit(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        DeepLinkRouter.shared.submit(url)
                    }
                }
        }
    }
    
    private func setupAppFont() {
        // Keep UIKit-backed controls on the same Thmanyah + ss01 pipeline as
        // SwiftUI. The builder fails loudly if a bundled face is ever missing.
        let customFont = TamrinFont.uiFont(size: 18)
        UILabel.appearance().font = customFont
        UITextField.appearance().font = customFont
        UITextView.appearance().font = customFont

        // The bar's own `titleTextAttributes` is the pre-iOS 13 path and no
        // longer reaches a SwiftUI navigation bar: the title is drawn from the
        // `UINavigationBarAppearance` objects, so a font set only on the bar is
        // silently ignored and the title falls back to the system face. Each
        // appearance is mutated in place, leaving its background configuration
        // — and therefore every screen's `toolbarBackground` — untouched.
        let navigationBar = UINavigationBar.appearance()
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: TamrinFont.uiFont(size: 17, weight: .bold)
        ]
        let largeTitleAttributes: [NSAttributedString.Key: Any] = [
            .font: TamrinFont.uiFont(size: 34, weight: .bold)
        ]

        func applyTitleFonts(to appearance: UINavigationBarAppearance) -> UINavigationBarAppearance {
            appearance.titleTextAttributes = titleAttributes
            appearance.largeTitleTextAttributes = largeTitleAttributes
            return appearance
        }

        navigationBar.standardAppearance = applyTitleFonts(to: navigationBar.standardAppearance)
        navigationBar.compactAppearance = applyTitleFonts(
            to: navigationBar.compactAppearance ?? navigationBar.standardAppearance
        )
        // Left nil, this one falls back to `standardAppearance`; it is only
        // styled when a bar already carries its own.
        if let scrollEdge = navigationBar.scrollEdgeAppearance {
            navigationBar.scrollEdgeAppearance = applyTitleFonts(to: scrollEdge)
        }
        if let compactScrollEdge = navigationBar.compactScrollEdgeAppearance {
            navigationBar.compactScrollEdgeAppearance = applyTitleFonts(to: compactScrollEdge)
        }

        let barButton = UIBarButtonItem.appearance()
        let barButtonFont: [NSAttributedString.Key: Any] = [
            .font: TamrinFont.uiFont(size: 17, weight: .medium)
        ]
        barButton.setTitleTextAttributes(barButtonFont, for: .normal)
        barButton.setTitleTextAttributes(barButtonFont, for: .highlighted)
    }
}
