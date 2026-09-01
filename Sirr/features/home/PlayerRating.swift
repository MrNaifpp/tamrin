import SwiftUI

/// The six things one player judges another on. The order is the order the
/// rating flow walks them in, and the order they are drawn in.
enum PlayerAttribute: String, CaseIterable, Identifiable {
    case pace
    case passing
    case shooting
    case stamina
    case defending
    case awareness

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pace: return "السرعة"
        case .passing: return "التمرير"
        case .shooting: return "التسديد"
        case .stamina: return "اللياقة"
        case .defending: return "الدفاع"
        case .awareness: return "الوعي الكروي"
        }
    }

    /// Three letters, the way a player card labels the same six.
    var shortTitle: String {
        switch self {
        case .pace: return "سرع"
        case .passing: return "تمر"
        case .shooting: return "تسد"
        case .stamina: return "ليا"
        case .defending: return "دفع"
        case .awareness: return "وعي"
        }
    }

    var symbol: String {
        switch self {
        case .pace: return "hare.fill"
        case .passing: return "arrow.triangle.branch"
        case .shooting: return "target"
        case .stamina: return "bolt.heart.fill"
        case .defending: return "shield.lefthalf.filled"
        case .awareness: return "eye.fill"
        }
    }

    /// What the rater is being asked, so a number between 0 and 100 means the
    /// same thing to everyone filling it in.
    var prompt: String {
        switch self {
        case .pace: return "كم ينطلق ويسبق اللي حوله؟"
        case .passing: return "كم تمريراته توصل وتفتح اللعب؟"
        case .shooting: return "كم تسديداته تصير أهداف؟"
        case .stamina: return "كم يكمّل التمرين بنفس المستوى؟"
        case .defending: return "كم يقطع الكرة ويغلق الفراغات؟"
        case .awareness: return "كم يقرأ اللعب ويختار القرار الصح؟"
        }
    }
}

/// A player's position. These four are the only ones the app offers, so the
/// fallback below is only ever reached by a profile saved before that was true
/// — or one that never picked a position at all.
enum PlayerPosition: String, CaseIterable {
    case goalkeeper = "حارس"
    case defender = "دفاع"
    case midfielder = "وسط"
    case forward = "هجوم"

    /// Exact stored choice. Callers that are about to submit use this rather
    /// than silently judging a missing/legacy position as something else.
    static func exact(from raw: String?) -> PlayerPosition? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return PlayerPosition(rawValue: trimmed)
    }

    /// Mirrors `player_rating_overall`'s defensive fallback in the migration.
    /// Read-only legacy summaries can still be rendered; new submissions are
    /// gated on `exact(from:)` by the sheet and the RPC.
    static func resolved(from raw: String?) -> PlayerPosition {
        exact(from: raw) ?? .defender
    }

    /// The zone of the pitch this position holds, from own goal (0) to the
    /// opponent's (1). The pitch badge places the pill inside this band.
    var pitchZone: ClosedRange<Double> {
        switch self {
        case .goalkeeper: return 0.00...0.16
        case .defender: return 0.10...0.40
        case .midfielder: return 0.36...0.64
        case .forward: return 0.62...0.94
        }
    }

    /// The colour that identifies the position at a glance: forward green,
    /// midfield amber, defence red, keeper blue — he has his own weights, so
    /// he gets his own colour rather than borrowing the defender's.
    var tint: Color {
        switch self {
        case .forward: return Color(red: 0.42, green: 0.78, blue: 0.35)
        case .midfielder: return Color(red: 0.95, green: 0.72, blue: 0.20)
        case .defender: return Color(red: 0.87, green: 0.32, blue: 0.27)
        case .goalkeeper: return Color(red: 0.29, green: 0.55, blue: 0.90)
        }
    }

    /// Integer percentages summing to 100. Integer arithmetic is intentional:
    /// `Double` can represent an exact 62.5 as 62.499999… and round it down,
    /// while the product rule and PostgreSQL both require half-up rounding.
    /// Mirrors `public.player_rating_overall`; the two must change together.
    var weightPercent: [PlayerAttribute: Int] {
        switch self {
        case .midfielder:
            return [.passing: 30, .awareness: 20, .shooting: 15,
                    .stamina: 15, .defending: 10, .pace: 10]
        case .forward:
            return [.shooting: 30, .awareness: 20, .passing: 15,
                    .stamina: 15, .defending: 10, .pace: 10]
        case .goalkeeper:
            // A keeper is judged on the two things that decide his game —
            // stopping the ball and reading it — so defending and awareness
            // carry more than they do for an outfield defender, and shooting
            // is left as the token weight it deserves.
            return [.defending: 35, .awareness: 25, .stamina: 15,
                    .passing: 10, .pace: 10, .shooting: 5]
        case .defender:
            return [.defending: 30, .awareness: 20, .passing: 15,
                    .stamina: 15, .shooting: 10, .pace: 10]
        }
    }
}

/// One rating: the six numbers, and the Overall they blend into.
///
/// Six stored properties rather than a `[PlayerAttribute: Int]` dictionary.
/// The dictionary version corrupted its own storage once these were held in
/// another dictionary — writes silently did nothing and reading `count` later
/// segfaulted — and nothing here needed a dictionary in the first place: the
/// six attributes are fixed, so they are fields.
struct PlayerRatingScores: Equatable {
    var pace: Int = 50
    var passing: Int = 50
    var shooting: Int = 50
    var stamina: Int = 50
    var defending: Int = 50
    var awareness: Int = 50

    /// The midpoint is where an unrated attribute starts, so the rater moves
    /// away from "average" in whichever direction they mean.
    static let neutral = PlayerRatingScores()

    subscript(attribute: PlayerAttribute) -> Int {
        get {
            switch attribute {
            case .pace: pace
            case .passing: passing
            case .shooting: shooting
            case .stamina: stamina
            case .defending: defending
            case .awareness: awareness
            }
        }
        set {
            let clamped = min(max(newValue, 0), 100)
            switch attribute {
            case .pace: pace = clamped
            case .passing: passing = clamped
            case .shooting: shooting = clamped
            case .stamina: stamina = clamped
            case .defending: defending = clamped
            case .awareness: awareness = clamped
            }
        }
    }

    /// The weighted blend, rounded the same way the server rounds it.
    func overall(for position: PlayerPosition) -> Int {
        let weights = position.weightPercent
        let weightedHundredths = PlayerAttribute.allCases.reduce(0) { total, attribute in
            total + self[attribute] * (weights[attribute] ?? 0)
        }
        // Scores are non-negative, so adding half a unit implements the same
        // rounding as Math.round() for every possible 0...100 input.
        return (weightedHundredths + 50) / 100
    }
}

/// How a rating reads at a glance: the colour band a number falls into.
enum RatingBand {
    /// Deliberately few bands, and none of them red — this is a pickup game
    /// among friends, not a scouting report.
    static func tint(for value: Int) -> Color {
        switch value {
        case 85...: return TamrinTheme.lime
        case 70..<85: return TamrinTheme.mint
        case 50..<70: return TamrinTheme.peach
        default: return Color(red: 0.85, green: 0.62, blue: 0.55)
        }
    }

    static func label(for value: Int) -> String {
        switch value {
        case 90...: return "استثنائي"
        case 80..<90: return "ممتاز"
        case 70..<80: return "جيد جدًا"
        case 60..<70: return "جيد"
        case 45..<60: return "مقبول"
        default: return "يحتاج تطوير"
        }
    }
}
