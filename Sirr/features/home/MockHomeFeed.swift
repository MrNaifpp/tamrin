import SwiftUI

/// Value types the reskinned Home feed reads. This whole file is the
/// integration seam: a later increment replaces the mock body of
/// `MockHomeFeed` with EventService/WorkspaceService calls that map records
/// into these types, leaving every view unchanged.
struct FeedTeam: Identifiable {
    let id: UUID
    let name: String
    let symbol: String
    let avatarData: Data?
    let memberCount: Int
}

enum FeedRegStatus {
    case registered
    case waitlisted
}

struct FeedMember: Identifiable {
    let id: UUID
    let name: String
    var status: FeedRegStatus
}

struct FeedOccurrence: Identifiable {
    let id: UUID
    let title: String
    let startAt: Date
    let locationName: String
    let capacity: Int
    let price: Double        // 0 == free
    let isCancelled: Bool
    let artIndex: Int        // cycles ExerciseArt1..3
}

@MainActor
@Observable
final class MockHomeFeed {
    var teams: [FeedTeam]
    var selectedTeamID: UUID
    var occurrencesByTeam: [UUID: [FeedOccurrence]]
    var rosters: [UUID: [FeedMember]]
    var profileName: String
    let currentUserName = "نايف"

    var currentTeam: FeedTeam { teams.first { $0.id == selectedTeamID } ?? teams[0] }
    var occurrences: [FeedOccurrence] { occurrencesByTeam[selectedTeamID] ?? [] }

    init() {
        profileName = "نايف"

        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        func at(_ days: Int, _ hour: Int) -> Date {
            let base = cal.date(byAdding: .day, value: days, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        }

        let teamA = FeedTeam(id: UUID(), name: "رفاق الملعب", symbol: "figure.run", avatarData: nil, memberCount: 12)
        let teamB = FeedTeam(id: UUID(), name: "نادي الفجر", symbol: "figure.cooldown", avatarData: nil, memberCount: 8)
        let teamC = FeedTeam(id: UUID(), name: "الصقور", symbol: "bird", avatarData: nil, memberCount: 5)
        teams = [teamA, teamB, teamC]
        selectedTeamID = teamA.id

        let a1 = FeedOccurrence(id: UUID(), title: "كورة الثلاثاء", startAt: at(2, 20),
                                locationName: "ملعب النخيل", capacity: 14, price: 25, isCancelled: false, artIndex: 0)
        let a2 = FeedOccurrence(id: UUID(), title: "تمرين الجري", startAt: at(4, 6),
                                locationName: "كورنيش الرياض", capacity: 20, price: 0, isCancelled: false, artIndex: 1)
        let a3 = FeedOccurrence(id: UUID(), title: "كورة نهاية الأسبوع", startAt: at(6, 18),
                                locationName: "ملعب الروضة", capacity: 12, price: 30, isCancelled: false, artIndex: 2)
        let b1 = FeedOccurrence(id: UUID(), title: "تمرين الصباح", startAt: at(1, 7),
                                locationName: "منتزه السلام", capacity: 16, price: 0, isCancelled: false, artIndex: 1)
        let b2 = FeedOccurrence(id: UUID(), title: "مباراة ودية", startAt: at(3, 21),
                                locationName: "ملعب الأمير", capacity: 22, price: 20, isCancelled: false, artIndex: 2)

        occurrencesByTeam = [
            teamA.id: [a1, a2, a3],
            teamB.id: [b1, b2],
            teamC.id: [],
        ]

        func members(_ names: [String], _ status: FeedRegStatus = .registered) -> [FeedMember] {
            names.map { FeedMember(id: UUID(), name: $0, status: status) }
        }
        let pool = ["سلطان", "عبدالله", "فهد", "تركي", "ماجد", "خالد", "نواف",
                    "سعود", "بندر", "ريان", "عمر", "يزيد", "راكان", "مشعل"]

        rosters = [
            a1.id: members(Array(pool.prefix(9))),
            a2.id: members(Array(pool.prefix(12))),
            a3.id: members(Array(pool.prefix(12))) + members(["زياد"], .waitlisted),
            b1.id: members(Array(pool.prefix(5))),
            b2.id: members(Array(pool.prefix(7))),
        ]
    }

    func roster(for occurrence: FeedOccurrence) -> [FeedMember] {
        rosters[occurrence.id] ?? []
    }

    func registeredCount(for occurrence: FeedOccurrence) -> Int {
        roster(for: occurrence).filter { $0.status == .registered }.count
    }

    func waitlistCount(for occurrence: FeedOccurrence) -> Int {
        roster(for: occurrence).filter { $0.status == .waitlisted }.count
    }

    func myRegistration(for occurrence: FeedOccurrence) -> FeedMember? {
        roster(for: occurrence).first { $0.name == currentUserName }
    }

    /// Local mock join: no-op if already on the list; registers when there is
    /// room, otherwise waitlists.
    func register(for occurrence: FeedOccurrence) {
        var list = rosters[occurrence.id] ?? []
        guard !list.contains(where: { $0.name == currentUserName }) else { return }
        let registered = list.filter { $0.status == .registered }.count
        let status: FeedRegStatus = registered >= occurrence.capacity ? .waitlisted : .registered
        list.append(FeedMember(id: UUID(), name: currentUserName, status: status))
        rosters[occurrence.id] = list
    }

    /// Local mock leave: removes the current user; if they held a registered
    /// seat, promotes the first waitlisted member.
    func withdraw(from occurrence: FeedOccurrence) {
        var list = rosters[occurrence.id] ?? []
        guard let mine = list.firstIndex(where: { $0.name == currentUserName }) else { return }
        let freedSeat = list[mine].status == .registered
        list.remove(at: mine)
        if freedSeat, let promote = list.firstIndex(where: { $0.status == .waitlisted }) {
            list[promote].status = .registered
        }
        rosters[occurrence.id] = list
    }

    func selectTeam(_ id: UUID) {
        selectedTeamID = id
    }
}
