//
//  STCPay.swift
//  Sirr
//
//  STC Pay number normalization + validation.
//

import Foundation

enum STCPay {
    /// Normalize a user-entered Saudi mobile number to canonical +9665XXXXXXXX form.
    /// Returns nil if the input doesn't parse as a Saudi mobile.
    ///
    /// Accepts: `05XXXXXXXX`, `5XXXXXXXX`, `+9665XXXXXXXX`, `009665XXXXXXXX`,
    /// with or without spaces/dashes.
    static func normalize(_ raw: String) -> String? {
        let digitsOnly = raw.unicodeScalars
            .filter { CharacterSet.decimalDigits.contains($0) }
            .map(String.init)
            .joined()

        var body = digitsOnly

        if body.hasPrefix("00966") {
            body = String(body.dropFirst(5))
        } else if body.hasPrefix("966") {
            body = String(body.dropFirst(3))
        } else if body.hasPrefix("0") {
            body = String(body.dropFirst())
        }

        // body should now be exactly 9 digits starting with 5
        guard body.count == 9, body.hasPrefix("5"), body.allSatisfy(\.isNumber) else {
            return nil
        }

        return "+966" + body
    }

    /// True if the input parses as a Saudi mobile.
    static func isValid(_ raw: String) -> Bool {
        normalize(raw) != nil
    }

    /// Pretty-print a stored canonical number for the joiner sheet:
    /// `+966 5XX XXX XXX`.
    static func displayForm(_ canonical: String) -> String {
        guard canonical.hasPrefix("+9665"), canonical.count == 13 else { return canonical }
        let start = canonical.index(canonical.startIndex, offsetBy: 4)
        let tail = String(canonical[start...])
        let s1 = tail.prefix(3)
        let s2 = tail.dropFirst(3).prefix(3)
        let s3 = tail.dropFirst(6).prefix(3)
        return "+966 \(s1) \(s2) \(s3)"
    }
}
