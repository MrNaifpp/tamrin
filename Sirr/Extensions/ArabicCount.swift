import Foundation

/// A noun in the three forms Arabic needs to agree with a number.
///
/// Arabic does not simply append a plural: the form depends on the count, and
/// for one and two the numeral itself is dropped because the word already
/// carries it. Say `2.counted(.player)` and you get «لاعبين», never «2 لاعبين».
struct ArabicNoun {
    /// لاعب — used alone for one, and after the numeral from eleven up.
    let singular: String
    /// لاعبين — the dual, which replaces the numeral entirely.
    let dual: String
    /// لاعبين — the plural, used with the numeral for three through ten.
    let plural: String

    static let player = ArabicNoun(singular: "لاعب", dual: "لاعبين", plural: "لاعبين")
    static let member = ArabicNoun(singular: "عضو", dual: "عضوان", plural: "أعضاء")
    static let seat = ArabicNoun(singular: "مقعد", dual: "مقعدين", plural: "مقاعد")
    static let session = ArabicNoun(singular: "موعد", dual: "موعدين", plural: "مواعيد")
}

extension Int {
    /// This number written the way Arabic counts it:
    ///
    /// | العدد | النص |
    /// |---|---|
    /// | 1 | لاعب واحد |
    /// | 2 | لاعبين |
    /// | 3–10 | 3 لاعبين |
    /// | 11+ | 11 لاعب |
    ///
    /// Past a hundred the same rule applies to the last two digits, so 103 is
    /// «103 لاعبين» while 102 is «102 لاعب».
    ///
    /// Digits come from `Locale.tamrin`: Arabic wording, Western numerals.
    func counted(_ noun: ArabicNoun) -> String {
        let digits = formatted(.number.locale(.tamrin).grouping(.never))

        switch self {
        case 1:
            return "\(noun.singular) واحد"
        case 2:
            return noun.dual
        default:
            let lastTwoDigits = abs(self) % 100
            return (3...10).contains(lastTwoDigits)
                ? "\(digits) \(noun.plural)"
                : "\(digits) \(noun.singular)"
        }
    }
}
