//
//  SirrApp.swift
//  Sirr
//
//  Created by فارس أبومالح on 07/04/1447 AH.
//

import SwiftUI

extension Notification.Name {
    static let deepLinkReceived = Notification.Name("deepLinkReceived")
}

@main
struct SirrApp: App {
    init() {
        // Configure app-wide font settings
        setupAppFont()
        
        // DEBUG: Check if font files are in bundle
        print("\n📦 CHECKING BUNDLE FOR FONT FILES:")
        let fontFiles = [
            "TheYearofHandicrafts-Regular.otf",
            "TheYearofHandicrafts-Medium.otf",
            "TheYearofHandicrafts-SemiBold.otf",
            "TheYearofHandicrafts-Bold.otf",
            "TheYearofHandicrafts-Black.otf"
        ]
        
        for fileName in fontFiles {
            if let fontURL = Bundle.main.url(forResource: fileName.replacingOccurrences(of: ".otf", with: ""), withExtension: "otf") {
                print("✅ \(fileName) found in bundle at: \(fontURL.lastPathComponent)")
                
                // Try to register the font
                if let fontDataProvider = CGDataProvider(url: fontURL as CFURL),
                   let font = CGFont(fontDataProvider) {
                    var error: Unmanaged<CFError>?
                    if CTFontManagerRegisterGraphicsFont(font, &error) {
                        if let postScriptName = font.postScriptName {
                            print("   📝 Registered as: \(postScriptName)")
                        }
                    } else if let error = error?.takeRetainedValue() {
                        print("   ⚠️ Registration error: \(error)")
                    }
                }
            } else {
                print("❌ \(fileName) NOT in bundle")
            }
        }
        
        print("\n🔍 FONT DEBUG INFO:")
        let fontsToTest = [
            "TheYearofHandicrafts-Regular",
            "TheYearofHandicrafts-Medium",
            "TheYearofHandicrafts-SemiBold",
            "TheYearofHandicrafts-Bold",
            "TheYearofHandicrafts-Black"
        ]
        
        for fontName in fontsToTest {
            if let font = UIFont(name: fontName, size: 18) {
                print("✅ \(fontName) → LOADED (actual: \(font.fontName))")
            } else {
                print("❌ \(fontName) → NOT FOUND")
            }
        }
        print("📋 Check console for complete font list\n")
    }
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .applyAppFont()
                .onOpenURL { url in
                    NotificationCenter.default.post(name: .deepLinkReceived, object: url)
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

