//
//  FontExtensionAlt.swift
//  Sirr
//
//  Alternative font names to try
//

import SwiftUI

// Alternative font configurations to try if main one doesn't work
extension Font {
    // Try different possible names for TheYearofHandicrafts
    static func tryCustomFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // Possible font family names (the actual name might be different from file name)
        let possibleNames = [
            // Original names
            "TheYearofHandicrafts-Regular",
            "TheYearofHandicrafts-Medium", 
            "TheYearofHandicrafts-SemiBold",
            "TheYearofHandicrafts-Bold",
            "TheYearofHandicrafts-Black",
            
            // Without hyphens
            "TheYearofHandicrafts Regular",
            "TheYearofHandicrafts Medium",
            "TheYearofHandicrafts SemiBold", 
            "TheYearofHandicrafts Bold",
            "TheYearofHandicrafts Black",
            
            // Family name only
            "TheYearofHandicrafts",
            
            // Arabic name
            "عام الحرف",
            "عام الحرف Regular",
            
            // Common variations
            "YearofHandicrafts-Regular",
            "Year of Handicrafts"
        ]
        
        // Test each possible name
        for fontName in possibleNames {
            if UIFont(name: fontName, size: size) != nil {
                return Font.custom(fontName, size: size)
            }
        }
        
        // Fallback to system
        print("⚠️ Custom font not found, using system font")
        return Font.system(size: size, weight: weight)
    }
}


