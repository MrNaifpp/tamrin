//
//  FontDebugger.swift
//  Sirr
//
//  Use this to verify font installation
//

import SwiftUI
#if canImport(UIKit)
import UIKit
private typealias PlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
private typealias PlatformFont = NSFont
#endif

struct FontDebugger {
    /// Print all available fonts in the console
    static func printAllFonts() {
        print("\n========== AVAILABLE FONTS ==========")
        for family in availableFamilyNames() {
            print("📦 Font Family: \(family)")
            let names = fontNames(forFamilyName: family)
            for fontName in names {
                print("   ✓ \(fontName)")
            }
        }
        print("=====================================\n")
    }
    
    /// Check if TheYearofHandicrafts fonts are loaded
    static func verifyCustomFonts() {
        print("\n========== CUSTOM FONT CHECK ==========")
        let fontsToCheck = [
            "TheYearofHandicrafts-Regular",
            "TheYearofHandicrafts-Medium",
            "TheYearofHandicrafts-SemiBold",
            "TheYearofHandicrafts-Bold",
            "TheYearofHandicrafts-Black"
        ]
        
        for fontName in fontsToCheck {
            if PlatformFont(name: fontName, size: 18) != nil {
                print("✅ \(fontName) - LOADED")
            } else {
                print("❌ \(fontName) - NOT FOUND")
            }
        }
        print("=======================================\n")
    }
    
    /// Run all checks
    static func runAllChecks() {
        verifyCustomFonts()
        printAllFonts()
    }

    private static func availableFamilyNames() -> [String] {
        #if canImport(UIKit)
        return UIFont.familyNames.sorted()
        #elseif canImport(AppKit)
        return NSFontManager.shared.availableFontFamilies.sorted()
        #else
        return []
        #endif
    }

    private static func fontNames(forFamilyName family: String) -> [String] {
        #if canImport(UIKit)
        return UIFont.fontNames(forFamilyName: family)
        #elseif canImport(AppKit)
        return NSFontManager.shared.availableMembers(ofFontFamily: family)?
            .compactMap { member in
                member.count > 0 ? member[0] as? String : nil
            } ?? []
        #else
        return []
        #endif
    }
}

// Preview view to test fonts
struct FontDebugView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Font Test - عام الحرف")
                    .font(.appTitle)
                
                Group {
                    Text("Regular: مرحباً بكم في التطبيق")
                        .font(.appFont(size: 20, weight: .regular))
                    
                    Text("Medium: مرحباً بكم في التطبيق")
                        .font(.appFont(size: 20, weight: .medium))
                    
                    Text("SemiBold: مرحباً بكم في التطبيق")
                        .font(.appFont(size: 20, weight: .semibold))
                    
                    Text("Bold: مرحباً بكم في التطبيق")
                        .font(.appFont(size: 20, weight: .bold))
                    
                    Text("Black: مرحباً بكم في التطبيق")
                        .font(.appFont(size: 20, weight: .black))
                }
                
                Divider()
                
                Text("If fonts look different, they're working! 🎉")
                    .font(.system(size: 14))
                    .foregroundStyle(.gray)
            }
            .padding()
        }
        .onAppear {
            FontDebugger.runAllChecks()
        }
    }
}

#Preview {
    FontDebugView()
}

