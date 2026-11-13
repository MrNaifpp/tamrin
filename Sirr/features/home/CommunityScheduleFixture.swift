#if DEBUG
import Foundation

/// Isolated local scenarios, including 300 actual membership rows (not just a
/// count on a card). No fixture UUID is ever sent to the backend.
enum CommunityScheduleFixture {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-demoCommunitySchedules")
    static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "C0917000-0000-4000-8000-%012d", value))!
    }
    static let teamIDs = Set((1...4).map(id))
    static func isPlayer(_ value: UUID) -> Bool {
        value.uuidString.hasPrefix("C0917000-") && !teamIDs.contains(value)
    }
    static func members(count: Int, ownerID: UUID, currentUserID: UUID, football: Bool = false) -> [FeedTeamMember] {
        let firstNames = ["خالد", "عبدالله", "محمد", "بدر", "سلمان", "أحمد", "فهد", "عمر", "وليد", "ماجد"]
        let lastNames = ["العتيبي", "الشهري", "القحطاني", "الغامدي", "الدوسري", "العنزي", "الحربي", "المطيري", "الزهراني", "السبيعي"]
        return (0..<count).map { index in
            let userID = index == 0 ? ownerID : (index == 1 && ownerID != currentUserID ? currentUserID : id(1000 + index))
            return FeedTeamMember(id: userID,
                                  displayName: index == 0 ? "مشرف التجربة" : firstNames[index % 10] + " " + lastNames[(index / 10) % 10] + (index >= 100 ? " \(index + 1)" : ""),
                                  role: index == 0 ? .admin : .member,
                                  isPending: false,
                                  position: football ? PlayerPosition.football[index % 4].rawValue : "")
        }
    }

    static func scores(_ value: Int) -> PlayerRatingScores {
        PlayerRatingScores(pace: value, passing: value, shooting: value,
                           stamina: value, defending: value, awareness: value)
    }
}
#endif
