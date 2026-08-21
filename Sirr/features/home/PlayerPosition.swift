import SwiftUI

/// A player's position. These four are the only ones the app offers, so the
/// fallback below is only ever reached by a profile saved before that was true
/// — or one that never picked a position at all.
enum PlayerPosition: String, CaseIterable {
    case goalkeeper = "حارس"
    case defender = "دفاع"
    case midfielder = "وسط"
    case forward = "هجوم"

    /// Exact stored choice, for callers that must not silently read a missing
    /// or legacy position as something else.
    static func exact(from raw: String?) -> PlayerPosition? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return PlayerPosition(rawValue: trimmed)
    }

    static func resolved(from raw: String?) -> PlayerPosition {
        exact(from: raw) ?? .defender
    }

    /// The colour that identifies the position at a glance: forward green,
    /// midfield amber, defence red, keeper blue.
    var tint: Color {
        switch self {
        case .forward: return Color(red: 0.42, green: 0.78, blue: 0.35)
        case .midfielder: return Color(red: 0.95, green: 0.72, blue: 0.20)
        case .defender: return Color(red: 0.87, green: 0.32, blue: 0.27)
        case .goalkeeper: return Color(red: 0.29, green: 0.55, blue: 0.90)
        }
    }
}
