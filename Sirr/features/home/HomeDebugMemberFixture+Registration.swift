#if DEBUG
import Foundation

/// Registration-settings scenarios for the local fixture: two member-side
/// groups (registration not open yet, manual approval) and the organizer-side
/// cases on two of the tester's own sport groups.
extension HomeDebugMemberFixture {
    static let opensLaterTeamID = UUID(uuidString: "D3B00000-0000-4000-8000-000000000007")!
    static let opensLaterEventID = UUID(uuidString: "E3B00000-0000-4000-8000-000000000030")!
    static let manualTeamID = UUID(uuidString: "D3B00000-0000-4000-8000-000000000008")!
    static let manualEventID = UUID(uuidString: "E3B00000-0000-4000-8000-000000000031")!

    /// A photo tried on one fixture exercise (its card and its group) without
    /// touching how real exercises draw from the library. Debug only, and keyed
    /// by fixture ids, so it can never reach a real group.
    static let pinnedArt: [UUID: String] = [
        opensLaterEventID: "SportArt/soccer/soccer-dirt-pitch.jpg",
        opensLaterTeamID: "SportArt/soccer/soccer-dirt-pitch.jpg"
    ]

    static let opensLaterTeam = FeedTeam(
        id: opensLaterTeamID,
        name: "عضو: التسجيل يفتح لاحقًا",
        symbol: "figure.soccer",
        color: .blue,
        avatarData: nil,
        memberCount: 14,
        inviteCode: "DEMO-LATER"
    )

    static let manualTeam = FeedTeam(
        id: manualTeamID,
        name: "عضو: قبول المشرف",
        symbol: "figure.soccer",
        color: .red,
        avatarData: nil,
        memberCount: 14,
        inviteCode: "DEMO-MANUAL"
    )

    /// Two days before at 12:00, on a session far enough ahead that the
    /// opening is always still to come when the fixture loads.
    static let laterOpening = RegistrationOpeningRule(daysBefore: 2, minuteOfDay: 12 * 60)

    static func opensLaterOccurrence(referenceDate: Date = .now) -> FeedOccurrence {
        var start = nextEvening(weekday: 3, hour: 19, after: referenceDate)
        while laterOpening.opensAt(for: start) <= referenceDate.addingTimeInterval(3 * 3600) {
            start = start.addingTimeInterval(7 * 24 * 3600)
        }
        return FeedOccurrence(
            id: opensLaterEventID,
            title: "التمرين الأسبوعي",
            startAt: start,
            endAt: start.addingTimeInterval(90 * 60),
            locationName: "ملاعب الرواد",
            capacity: 16,
            price: 0,
            isCancelled: false,
            artIndex: 1,
            isRecurring: true,
            paymentMethodIds: [],
            publishedAt: referenceDate,
            memberResponse: .invited,
            registrationOpensAt: laterOpening.opensAt(for: start),
            registrationSettings: RegistrationSettings(opening: laterOpening)
        )
    }

    static func manualOccurrence(referenceDate: Date = .now) -> FeedOccurrence {
        let start = nextEvening(weekday: 5, hour: 20, after: referenceDate)
        return FeedOccurrence(
            id: manualEventID,
            title: "تمرين الخميس",
            startAt: start,
            endAt: start.addingTimeInterval(90 * 60),
            locationName: "ملعب النخيل",
            capacity: 14,
            price: 0,
            isCancelled: false,
            artIndex: 2,
            isRecurring: true,
            paymentMethodIds: [],
            publishedAt: referenceDate,
            memberResponse: .invited,
            registrationSettings: RegistrationSettings(approvalMode: .manual)
        )
    }

    /// Seats already given out on the two member-side exercises.
    static func registrationRoster(count: Int, referenceDate: Date = .now) -> [FeedMember] {
        Array(roster(referenceDate: referenceDate).prefix(count))
    }

    /// The organizer's side of manual approval: requests waiting on the
    /// padel exercise the tester runs.
    static let organizerRequests: [FeedRegistrationRequest] = {
        func member(_ index: Int, _ name: String, _ position: String) -> FeedRegistrationRequest {
            FeedRegistrationRequest(id: UUID(), userId: playerID(at: index), requestedBy: playerID(at: index),
                                    name: name, position: position)
        }
        func guest(_ name: String, of index: Int, _ requester: String) -> FeedRegistrationRequest {
            FeedRegistrationRequest(id: UUID(), requestedBy: playerID(at: index), name: name,
                                    requesterName: requester)
        }
        return [
            member(4, "خالد الدوسري", "وسط"),
            member(6, "ريان الحربي", "هجوم"),
            guest("أبو سعد", of: 6, "ريان الحربي"),
            member(1, "عبدالعزيز الشمري", "هجوم"),
            member(8, "ياسر الزهراني", "دفاع")
        ]
    }()

    /// The basket exercise the tester runs opens later, so the organizer side
    /// of the countdown and «افتح التسجيل الآن» can be tried.
    static func withOrganizerOpening(_ occurrence: FeedOccurrence) -> FeedOccurrence {
        var occurrence = occurrence
        let rule = RegistrationOpeningRule(daysBefore: 1, minuteOfDay: 18 * 60)
        occurrence.registrationSettings.opening = rule
        occurrence.registrationOpensAt = rule.opensAt(for: occurrence.startAt)
        return occurrence
    }

    static func withManualApproval(_ occurrence: FeedOccurrence) -> FeedOccurrence {
        var occurrence = occurrence
        occurrence.registrationSettings.approvalMode = .manual
        return occurrence
    }

    /// Members who declined the organizer's exercise, one per reason the
    /// decline sheet offers, plus one in their own words and one with none.
    static func ownerDeclines(referenceDate: Date = .now) -> [EventMemberResponseRecord] {
        let seed: [(name: String, code: String?, text: String?)] = [
            ("بندر العنزي", "traveling", nil),
            ("عمر القرني", "injured", nil),
            ("سعود المالكي", "commitment", nil),
            ("مشاري الجهني", "other", "عندي اختبار بكرة الصبح"),
            ("حسن البقمي", nil, nil)
        ]
        return seed.enumerated().map { index, member in
            EventMemberResponseRecord(
                userId: UUID(uuidString: String(format: "F3B00000-0000-4000-8000-%012d", 300 + index))!,
                displayName: member.name,
                avatarUrl: nil,
                status: FeedMemberResponse.declined.rawValue,
                reasonCode: member.code,
                reasonText: member.text,
                invitedBy: organizerID,
                invitedAt: referenceDate.addingTimeInterval(-2 * 86_400),
                respondedAt: referenceDate.addingTimeInterval(Double(-index) * 5_400 - 3_600),
                updatedAt: referenceDate.addingTimeInterval(Double(-index) * 5_400 - 3_600)
            )
        }
    }

    private static func nextEvening(weekday: Int, hour: Int, after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RegistrationOpeningRule.timeZone
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTimePreservingSmallerComponents
        ) ?? date.addingTimeInterval(7 * 24 * 3600)
    }
}
#endif
