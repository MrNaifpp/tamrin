//
//  FontDebugger.swift
//  Sirr
//
//  Use this to verify font installation
//

import SwiftUI
import UIKit

struct FontDebugger {
    /// Print all available fonts in the console
    static func printAllFonts() {
        print("\n========== AVAILABLE FONTS ==========")
        for family in UIFont.familyNames.sorted() {
            print("📦 Font Family: \(family)")
            let names = UIFont.fontNames(forFamilyName: family)
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
            if UIFont(name: fontName, size: 18) != nil {
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


