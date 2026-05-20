//
//  QuickFontTest.swift
//  Sirr
//
//  Quick test to see actual font names
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct QuickFontTest: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Font Test - اختبار الخط")
                    .font(.system(size: 24, weight: .bold))
                    .padding(.bottom, 10)
                
                Group {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("System Font (Default):")
                            .font(.system(size: 14))
                            .foregroundStyle(.gray)
                        Text("مرحباً بكم في التطبيق - Welcome")
                            .font(.system(size: 20))
                    }
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom Font (appFont Regular):")
                            .font(.system(size: 14))
                            .foregroundStyle(.gray)
                        Text("مرحباً بكم في التطبيق - Welcome")
                            .font(.appFont(size: 20, weight: .regular))
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom Font (appFont Bold):")
                            .font(.system(size: 14))
                            .foregroundStyle(.gray)
                        Text("مرحباً بكم في التطبيق - Welcome")
                            .font(.appFont(size: 20, weight: .bold))
                    }
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Direct Font Name Test:")
                            .font(.system(size: 14))
                            .foregroundStyle(.gray)
                        Text("مرحباً بكم في التطبيق - Welcome")
                            .font(.custom("TheYearofHandicrafts-Regular", size: 20))
                    }
                }
            }
            .padding()
        }
        .onAppear {
            // Print all available fonts
            print("\n============ ALL FONTS ============")
            for family in availableFamilies() {
                let fonts = availableFontNames(for: family)
                if !fonts.isEmpty {
                    print("Family: \(family)")
                    for font in fonts {
                        print("  - \(font)")
                    }
                }
            }
            print("===================================\n")
        }
    }

    private func availableFamilies() -> [String] {
        #if canImport(UIKit)
        return UIFont.familyNames.sorted()
        #elseif canImport(AppKit)
        return NSFontManager.shared.availableFontFamilies.sorted()
        #else
        return []
        #endif
    }

    private func availableFontNames(for family: String) -> [String] {
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

#Preview {
    QuickFontTest()
}

