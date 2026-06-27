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
        // Fonts are loaded via Info.plist (INFOPLIST_KEY_UIAppFonts in build settings)
        // Set default font for UI components - TheYearofHandicrafts (عام الحرف)
        if let customFont = UIFont(name: "TheYearofHandicrafts-Regular", size: 18) {
            UILabel.appearance().font = customFont
            UITextField.appearance().font = customFont
            UITextView.appearance().font = customFont
        }
    }
}

