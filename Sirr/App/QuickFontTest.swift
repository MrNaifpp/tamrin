//
//  QuickFontTest.swift
//  Sirr
//
//  Quick test to see actual font names
//

import SwiftUI

struct QuickFontTest: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Font Test - اختبار الخط")
                    .font(TamrinFont.font(size: 24, weight: .bold))
                    .padding(.bottom, 10)
                
                Group {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Thmanyah Regular + ss01:")
                            .font(TamrinFont.font(size: 14, weight: .medium))
                            .foregroundStyle(.gray)
                        Text("مرحباً بكم في التطبيق - Welcome")
                            .font(TamrinFont.font(size: 20))
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom Font (appFont Regular):")
                            .font(TamrinFont.font(size: 14, weight: .medium))
                            .foregroundStyle(.gray)
                        Text("مرحباً بكم في التطبيق - Welcome")
                            .font(.appFont(size: 20, weight: .regular))
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom Font (appFont Bold):")
                            .font(TamrinFont.font(size: 14, weight: .medium))
                            .foregroundStyle(.gray)
                        Text("مرحباً بكم في التطبيق - Welcome")
                            .font(.appFont(size: 20, weight: .bold))
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Direct Font Name Test:")
                            .font(TamrinFont.font(size: 14, weight: .medium))
                            .foregroundStyle(.gray)
                        Text("مرحباً بكم في التطبيق - Welcome")
                            .font(TamrinFont.font(size: 20))
                    }
                }
            }
            .padding()
        }
        .onAppear {
            // Print all available fonts
            print("\n============ ALL FONTS ============")
            for family in UIFont.familyNames.sorted() {
                let fonts = UIFont.fontNames(forFamilyName: family)
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
}

#Preview {
    QuickFontTest()
}

