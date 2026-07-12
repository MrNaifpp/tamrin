import SwiftUI

/// Value types the reskinned Home feed reads. This whole file is the
/// integration seam: a later increment replaces the mock body of
/// `MockHomeFeed` with EventService/WorkspaceService calls that map records
/// into `FeedOccurrence`, leaving every view unchanged.
struct FeedTeam {
    let name: String
    let symbol: String
    let avatarData: Data?
}

struct FeedOccurrence: Identifiable {
    let id: UUID
    let title: String
    let startAt: Date
    let locationName: String
    let capacity: Int
    let registeredCount: Int
    let price: Double        // 0 == free
    let isCancelled: Bool
    let artIndex: Int        // cycles ExerciseArt1..3
}

@MainActor
@Observable
final class MockHomeFeed {
    var team: FeedTeam
    var profileName: String
    var occurrences: [FeedOccurrence]

    init() {
        team = FeedTeam(name: "رفاق الملعب", symbol: "figure.run", avatarData: nil)
        profileName = "نايف"

        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        func at(_ days: Int, _ hour: Int) -> Date {
            let base = cal.date(byAdding: .day, value: days, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        }

        occurrences = [
            FeedOccurrence(id: UUID(), title: "كورة الثلاثاء", startAt: at(2, 20),
                           locationName: "ملعب النخيل", capacity: 14, registeredCount: 9,
                           price: 25, isCancelled: false, artIndex: 0),
            FeedOccurrence(id: UUID(), title: "تمرين الجري", startAt: at(4, 6),
                           locationName: "كورنيش الرياض", capacity: 20, registeredCount: 12,
                           price: 0, isCancelled: false, artIndex: 1),
            FeedOccurrence(id: UUID(), title: "كورة نهاية الأسبوع", startAt: at(6, 18),
                           locationName: "ملعب الروضة", capacity: 12, registeredCount: 12,
                           price: 30, isCancelled: false, artIndex: 2),
        ]
    }
}
