import SwiftUI

/// The sports that have positions and ratings. A workspace has one sport,
/// stored as the database key (`soccer`, `volleyball`, …); everything else is
/// rated nowhere.
enum RatingSport: String, CaseIterable, Identifiable {
    case football = "soccer"
    case volleyball

    var id: String { rawValue }

    init?(sport: String?) {
        guard let sport, let value = RatingSport(rawValue: sport) else { return nil }
        self = value
    }

    var title: String {
        switch self {
        case .football: String(localized: "كرة القدم")
        case .volleyball: String(localized: "الكرة الطائرة")
        }
    }

    var symbol: String {
        switch self {
        case .football: "figure.soccer"
        case .volleyball: "figure.volleyball"
        }
    }

    /// The six this sport is judged on, in the order the flow walks them.
    var attributes: [PlayerAttribute] {
        switch self {
        case .football: [.pace, .passing, .shooting, .stamina, .defending, .awareness]
        case .volleyball: [.receiving, .setting, .attacking, .blocking, .serving, .courtAwareness]
        }
    }

    var positions: [PlayerPosition] {
        PlayerPosition.allCases.filter { $0.sport == self }
    }

    /// Where the profile asks for it.
    var positionPrompt: String {
        switch self {
        case .football: String(localized: "مركزك في الملعب")
        case .volleyball: String(localized: "مركزك في الطائرة")
        }
    }
}

/// The six things one player judges another on, per sport. The order of each
/// sport's six is the order the rating flow walks them in, and the order they
/// are drawn in.
enum PlayerAttribute: String, CaseIterable, Identifiable {
    case pace
    case passing
    case shooting
    case stamina
    case defending
    case awareness

    case receiving
    case setting
    case attacking
    case blocking
    case serving
    /// Volleyball's awareness. A case of its own rather than a shared one, so
    /// a volleyball rating can never be read into a football field.
    case courtAwareness

    var id: String { rawValue }

    var sport: RatingSport {
        switch self {
        case .pace, .passing, .shooting, .stamina, .defending, .awareness: .football
        default: .volleyball
        }
    }

    /// The key the server uses for this attribute within its sport.
    var serverKey: String { self == .courtAwareness ? "awareness" : rawValue }

    var title: String {
        switch self {
        case .pace: return String(localized: "السرعة")
        case .passing: return String(localized: "التمرير")
        case .shooting: return String(localized: "التسديد")
        case .stamina: return String(localized: "اللياقة")
        case .defending: return String(localized: "الدفاع")
        case .awareness: return String(localized: "الوعي الكروي")
        case .receiving: return String(localized: "الاستقبال")
        case .setting: return String(localized: "الإعداد")
        case .attacking: return String(localized: "الهجوم")
        case .blocking: return String(localized: "الصد")
        case .serving: return String(localized: "الإرسال")
        case .courtAwareness: return String(localized: "الوعي")
        }
    }

    /// Three letters, the way a player card labels the same six.
    var shortTitle: String {
        switch self {
        case .pace: return String(localized: "سرع")
        case .passing: return String(localized: "تمر")
        case .shooting: return String(localized: "تسد")
        case .stamina: return String(localized: "ليا")
        case .defending: return String(localized: "دفع")
        case .awareness: return String(localized: "وعي")
        case .receiving: return String(localized: "استق")
        case .setting: return String(localized: "إعد")
        case .attacking: return String(localized: "هجم")
        case .blocking: return String(localized: "صد")
        case .serving: return String(localized: "إرس")
        case .courtAwareness: return String(localized: "وعي")
        }
    }

    var symbol: String {
        switch self {
        case .pace: return "hare.fill"
        case .passing: return "arrow.triangle.branch"
        case .shooting: return "target"
        case .stamina: return "bolt.heart.fill"
        case .defending: return "shield.lefthalf.filled"
        case .awareness, .courtAwareness: return "eye.fill"
        case .receiving: return "hand.raised.fill"
        case .setting: return "hands.sparkles.fill"
        case .attacking: return "bolt.fill"
        case .blocking: return "hand.raised.square.fill"
        case .serving: return "figure.volleyball"
        }
    }

    /// What the rater is being asked, so a number between 0 and 100 means the
    /// same thing to everyone filling it in.
    var prompt: String {
        switch self {
        case .pace: return String(localized: "كم ينطلق ويسبق اللي حوله؟")
        case .passing: return String(localized: "كم تمريراته توصل وتفتح اللعب؟")
        case .shooting: return String(localized: "كم تسديداته تصير أهداف؟")
        case .stamina: return String(localized: "كم يكمّل التمرين بنفس المستوى؟")
        case .defending: return String(localized: "كم يقطع الكرة ويغلق الفراغات؟")
        case .awareness: return String(localized: "كم يقرأ اللعب ويختار القرار الصح؟")
        case .receiving: return String(localized: "كم يستقبل الإرسال والضربات ويرفعها نظيفة؟")
        case .setting: return String(localized: "كم إعداده يوصل للضارب في المكان الصح؟")
        case .attacking: return String(localized: "كم ضرباته تنهي النقطة؟")
        case .blocking: return String(localized: "كم يقفل الشبكة ويرد الضربات؟")
        case .serving: return String(localized: "كم إرساله يدخل ويصعّب الاستقبال؟")
        case .courtAwareness: return String(localized: "كم يقرأ الملعب ويختار القرار الصح؟")
        }
    }
}

/// A player's position in one sport. Football's four are the only ones the
/// app offers there, so the fallback below is only ever reached by a profile
/// saved before that was true — or one that never picked a position at all.
enum PlayerPosition: String, CaseIterable {
    case goalkeeper = "حارس"
    case defender = "دفاع"
    case midfielder = "وسط"
    case forward = "هجوم"

    case setter = "معدّ"
    case receiver = "مستقبل"
    case leftHitter = "ضارب يسار"
    case rightHitter = "ضارب يمين"
    case middleBlocker = "صادّ"
    case libero = "ليبرو"

    var sport: RatingSport {
        switch self {
        case .goalkeeper, .defender, .midfielder, .forward: .football
        default: .volleyball
        }
    }

    /// Football's four, for the pitch and the lineup.
    static var football: [PlayerPosition] { RatingSport.football.positions }

    /// The raw value is what the profile and the server store, in Arabic in
    /// every language. This is what the screen says.
    var title: String {
        switch self {
        case .goalkeeper: return String(localized: "حارس")
        case .defender: return String(localized: "دفاع")
        case .midfielder: return String(localized: "وسط")
        case .forward: return String(localized: "هجوم")
        case .setter: return String(localized: "معدّ")
        case .receiver: return String(localized: "مستقبل")
        case .leftHitter: return String(localized: "ضارب يسار")
        case .rightHitter: return String(localized: "ضارب يمين")
        case .middleBlocker: return String(localized: "صادّ")
        case .libero: return String(localized: "ليبرو")
        }
    }

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

    /// The same, inside one sport: a football position never weighs a
    /// volleyball rating. Volleyball's fallback mirrors `volleyball_rating_overall`.
    static func resolved(from raw: String?, in sport: RatingSport) -> PlayerPosition {
        if let exact = exact(from: raw), exact.sport == sport { return exact }
        return sport == .football ? .defender : .leftHitter
    }

    /// The zone of the pitch this position holds, from own goal (0) to the
    /// opponent's (1). The pitch badge places the pill inside this band.
    var pitchZone: ClosedRange<Double> {
        switch self {
        case .goalkeeper: return 0.00...0.16
        case .defender: return 0.10...0.40
        case .midfielder: return 0.36...0.64
        case .forward: return 0.62...0.94
        default: return 0.36...0.64
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
        case .setter: return Color(red: 0.95, green: 0.72, blue: 0.20)
        case .receiver: return Color(red: 0.29, green: 0.55, blue: 0.90)
        case .leftHitter, .rightHitter: return Color(red: 0.42, green: 0.78, blue: 0.35)
        case .middleBlocker: return Color(red: 0.87, green: 0.32, blue: 0.27)
        case .libero: return Color(red: 0.62, green: 0.45, blue: 0.88)
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

        // Volleyball, in the same shape: the position's skill, awareness, two
        // supporting skills, then the rest. Mirrors `volleyball_rating_overall`.
        case .setter:
            // Weighted like the keeper: the whole game runs through him.
            return [.setting: 35, .courtAwareness: 25, .serving: 15,
                    .receiving: 10, .blocking: 10, .attacking: 5]
        case .receiver:
            return [.receiving: 30, .courtAwareness: 20, .attacking: 15,
                    .serving: 15, .blocking: 10, .setting: 10]
        case .leftHitter:
            return [.attacking: 30, .courtAwareness: 20, .receiving: 15,
                    .serving: 15, .blocking: 10, .setting: 10]
        case .rightHitter:
            return [.attacking: 30, .courtAwareness: 20, .blocking: 15,
                    .serving: 15, .receiving: 10, .setting: 10]
        case .middleBlocker:
            return [.blocking: 30, .courtAwareness: 20, .attacking: 15,
                    .serving: 15, .receiving: 10, .setting: 10]
        case .libero:
            // The rules keep him from attacking, blocking and serving, so those
            // are token weights and reception carries the most of anyone.
            return [.receiving: 40, .courtAwareness: 25, .setting: 20,
                    .attacking: 5, .blocking: 5, .serving: 5]
        }
    }
}

/// One rating: the six numbers of its sport, and the Overall they blend into.
/// Football's six and volleyball's six sit side by side; a rating only ever
/// fills its own sport's.
///
/// Stored properties rather than a `[PlayerAttribute: Int]` dictionary.
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

    var receiving: Int = 50
    var setting: Int = 50
    var attacking: Int = 50
    var blocking: Int = 50
    var serving: Int = 50
    var courtAwareness: Int = 50

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
            case .receiving: receiving
            case .setting: setting
            case .attacking: attacking
            case .blocking: blocking
            case .serving: serving
            case .courtAwareness: courtAwareness
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
            case .receiving: receiving = clamped
            case .setting: setting = clamped
            case .attacking: attacking = clamped
            case .blocking: blocking = clamped
            case .serving: serving = clamped
            case .courtAwareness: courtAwareness = clamped
            }
        }
    }

    /// The weighted blend, rounded the same way the server rounds it.
    func overall(for position: PlayerPosition) -> Int {
        let weights = position.weightPercent
        let weightedHundredths = position.sport.attributes.reduce(0) { total, attribute in
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
        case 85...: return TamrinTheme.success
        case 70..<85: return TamrinTheme.mint
        case 50..<70: return TamrinTheme.peach
        default: return Color(red: 0.85, green: 0.62, blue: 0.55)
        }
    }

    static func label(for value: Int) -> String {
        switch value {
        case 90...: return String(localized: "استثنائي")
        case 80..<90: return String(localized: "ممتاز")
        case 70..<80: return String(localized: "جيد جدًا")
        case 60..<70: return String(localized: "جيد")
        case 45..<60: return String(localized: "مقبول")
        default: return String(localized: "يحتاج تطوير")
        }
    }
}
