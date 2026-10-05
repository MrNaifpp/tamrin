#if DEBUG
import Foundation

extension HomeDebugMemberFixture {
    static let matchAwardEventID = UUID(uuidString: "E3B00000-0000-4000-8000-000000000025")!
    static let matchAwardStateKey = "demo.matchAward.journey.v1"

    static func matchAwardOccurrence(referenceDate: Date = .now) -> FeedOccurrence {
        FeedOccurrence(id: matchAwardEventID, title: "تمرين رجل المباراة",
            startAt: referenceDate.addingTimeInterval(-7800),
            endAt: referenceDate.addingTimeInterval(-600),
            locationName: "ملعب الرواد", capacity: 16, price: 0,
            isCancelled: false, artIndex: 1, isRecurring: false,
            publishedAt: referenceDate.addingTimeInterval(-86400))
    }

    static func matchAwardRoster() -> [FeedMember] {
        let names = ["لؤي الزهراني", "أحمد رشوان", "مراد الجهني", "خالد مسلمي",
                     "عبدالرحمن الخزيم", "عماد العسيري", "عبدالله الشثري", "مازن الدوسري",
                     "سلمان الحربي", "محمد القحطاني", "عمر العتيبي", "فهد الغامدي",
                     "ناصر الشهري", "بدر السبيعي", "علي الدوسري", "يوسف الزهراني"]
        let positions = ["حارس", "دفاع", "وسط", "هجوم", "دفاع", "وسط", "وسط", "هجوم"]
        return names.enumerated().map { index, name in
            let id = ownerPlayerID(at: 200 + index)
            return FeedMember(id: id, name: name, status: .registered, userId: id,
                              joinedAt: .now.addingTimeInterval(-86400),
                              avatarUrl: DemoFaces.photo(at: index), position: positions[index % 8])
        }
    }

    static func matchAwardInitialState() -> MatchAward {
        MatchAward(eventId: matchAwardEventID, title: "تمرين رجل المباراة", status: .nomination,
                   canNominate: true, canVote: false, players: matchAwardRoster().map {
            MatchAwardPlayer(id: $0.id, userId: $0.userId, name: $0.name,
                             position: $0.position, avatarURL: $0.avatarUrl)
        })
    }
}
#endif
