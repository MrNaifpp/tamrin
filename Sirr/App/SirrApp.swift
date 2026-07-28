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

        let navigationBar = UINavigationBar.appearance()
        navigationBar.titleTextAttributes = [
            .font: TamrinFont.uiFont(size: 17, weight: .bold)
        ]
        navigationBar.largeTitleTextAttributes = [
            .font: TamrinFont.uiFont(size: 34, weight: .bold)
        ]

        let barButton = UIBarButtonItem.appearance()
        let barButtonFont: [NSAttributedString.Key: Any] = [
            .font: TamrinFont.uiFont(size: 17, weight: .medium)
        ]
        barButton.setTitleTextAttributes(barButtonFont, for: .normal)
        barButton.setTitleTextAttributes(barButtonFont, for: .highlighted)
    }
}
