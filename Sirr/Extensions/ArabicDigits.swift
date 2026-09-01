import Foundation

extension String {
    /// This string's digits folded to ASCII, with everything else dropped.
    ///
    /// An Arabic number pad emits ٠١٢…٩, and a Persian one ۰۱۲…۹. They read
    /// identically to a person and not at all to a server: a one-time code
    /// typed on the Arabic pad comes back "Token has expired or is invalid",
    /// because ٠٧٧ is not 077 to anything downstream.
    ///
    /// Fold at the edge — the moment the text is captured — so everything past
    /// that point, the display included, is dealing in one alphabet of digits.
    var asciiDigits: String {
        String(unicodeScalars.compactMap(Self.asciiDigit))
    }

    private static func asciiDigit(_ scalar: UnicodeScalar) -> Character? {
        let ascii: UInt32
        switch scalar.value {
        case 48 ... 57: ascii = scalar.value
        case 0x0660 ... 0x0669: ascii = scalar.value - 0x0660 + 48   // ٠–٩
        case 0x06F0 ... 0x06F9: ascii = scalar.value - 0x06F0 + 48   // ۰–۹
        default: return nil
        }
        return UnicodeScalar(ascii).map(Character.init)
    }
}
