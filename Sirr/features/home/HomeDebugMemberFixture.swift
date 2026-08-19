#if DEBUG
import Foundation

/// A deterministic, device-testable member journey that exists only in Debug
/// builds. It deliberately has no matching Supabase rows; `HomeStore` handles
/// every interaction with these ids locally so testing it can never mutate
/// production data.
enum HomeDebugMemberFixture {
    /// Opt-in, because the fixture used to appear in every Debug run: a brand
    /// new account landed on a workspace full of events it had never joined,
    /// which reads as a data leak rather than a test aid. Enable it from the
    /// scheme — Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments ▸ Arguments
    /// Passed On Launch — with `-demoMemberFixture`.
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-demoMemberFixture")
    /// Starts the member already registered after the organizer requested the
    /// contribution, so the persistent T-40 entry point can be checked on a
    /// simulator without touching Supabase data.
    static let isPaymentRequestEnabled = ProcessInfo.processInfo.arguments.contains("-demoPaymentRequest")

    static let teamID = UUID(uuidString: "D3B00000-0000-4000-8000-000000000001")!
    static let organizerID = UUID(uuidString: "A3B00000-0000-4000-8000-000000000001")!
    static let memberFallbackID = UUID(uuidString: "F3B00000-0000-4000-8000-000000000001")!
    static let salmanID = UUID(uuidString: "F3B00000-0000-4000-8000-000000000002")!
    static let eventID = UUID(uuidString: "E3B00000-0000-4000-8000-000000000001")!
    static let templateID = UUID(uuidString: "C3B00000-0000-4000-8000-000000000001")!

    /// A second group, owned by whoever is signed in, so the organizer's half
    /// of every screen is testable too: the money tiles, payment review, the
    /// reminder button, manual registration. The member-side group above
    /// deliberately cannot show any of that.
    static let ownerTeamID = UUID(uuidString: "D3B00000-0000-4000-8000-000000000002")!
    static let ownerEventID = UUID(uuidString: "E3B00000-0000-4000-8000-000000000002")!
    static let ownerTemplateID = UUID(uuidString: "C3B00000-0000-4000-8000-000000000002")!

    private static let stcBankMethodID = UUID(uuidString: "B3B00000-0000-4000-8000-000000000001")!
    private static let barqMethodID = UUID(uuidString: "B3B00000-0000-4000-8000-000000000002")!
    private static let alRajhiMethodID = UUID(uuidString: "B3B00000-0000-4000-8000-000000000003")!
    private static let snbMethodID = UUID(uuidString: "B3B00000-0000-4000-8000-000000000004")!

    static let team = FeedTeam(
        id: teamID,
        name: "تجربة المستخدم",
        symbol: "figure.soccer",
        avatarData: nil,
        memberCount: 14,
        inviteCode: "DEMO-USER"
    )

    static let ownerTeam = FeedTeam(
        id: ownerTeamID,
        name: "تجربة المشرف",
        symbol: "figure.soccer",
        avatarData: nil,
        memberCount: 9,
        inviteCode: "DEMO-OWNER"
    )

    static let paymentMethods: [PaymentDestinationMethod] = [
        PaymentDestinationMethod(
            paymentMethodId: stcBankMethodID,
            provider: .stcBank,
            mobileNumber: "966501234567",
            iban: nil,
            accountNumber: nil
        ),
        PaymentDestinationMethod(
            paymentMethodId: barqMethodID,
            provider: .barq,
            mobileNumber: "966509876543",
            iban: nil,
            accountNumber: nil
        ),
        PaymentDestinationMethod(
            paymentMethodId: alRajhiMethodID,
            provider: .alRajhi,
            mobileNumber: nil,
            iban: "SA0380000000608010167519",
            accountNumber: "608010167519"
        ),
        PaymentDestinationMethod(
            paymentMethodId: snbMethodID,
            provider: .snb,
            mobileNumber: nil,
            iban: "SA4410000001234567891234",
            accountNumber: "1234567891234"
        ),
    ]

    static var paymentMethodIDs: [UUID] {
        paymentMethods.map(\.paymentMethodId)
    }

    static func occurrence(referenceDate: Date = .now) -> FeedOccurrence {
        FeedOccurrence(
            id: eventID,
            title: "تمرين تجربة المستخدم",
            startAt: nextTuesdayEvening(after: referenceDate),
            locationName: "ملعب النخيل",
            capacity: 16,
            price: 30,
            isCancelled: false,
            artIndex: 2,
            isRecurring: true,
            templateId: templateID,
            paymentMethodIds: paymentMethodIDs,
            publishedAt: referenceDate,
            paymentReminderSentAt: isPaymentRequestEnabled ? referenceDate : nil,
            memberResponse: .invited
        )
    }

    static func ownerOccurrence(referenceDate: Date = .now) -> FeedOccurrence {
        FeedOccurrence(
            id: ownerEventID,
            title: "تمرين تجربة المشرف",
            startAt: nextTuesdayEvening(after: referenceDate),
            locationName: "ملعب الرواد",
            capacity: 14,
            price: 45,
            isCancelled: false,
            artIndex: 1,
            isRecurring: false,
            templateId: ownerTemplateID,
            paymentMethodIds: paymentMethodIDs,
            publishedAt: referenceDate
        )
    }

    /// Mixed states on purpose: two seats still awaiting confirmation so the
    /// payment review, the reminder cooldown and the waiting badge all have
    /// something to act on.
    static func ownerRoster(referenceDate: Date = .now) -> [FeedMember] {
        ownerRosterSeed.enumerated().map { index, seed in
            let id = ownerPlayerID(at: index)
            return FeedMember(
                id: id,
                name: seed.name,
                status: seed.status,
                userId: id,
                joinedAt: referenceDate.addingTimeInterval(Double(-index) * 5400 - 3600),
                position: seed.position
            )
        }
    }

    private static let ownerRosterSeed: [(name: String, position: String, status: FeedRegStatus)] = [
        ("بندر", "هجوم", .registered),
        ("مشعل", "دفاع", .paymentPending),
        ("سعود", "وسط", .registered),
        ("راكان", "حارس", .registered),
        ("فهد", "هجوم", .paymentPending),
        ("عمر", "وسط", .waitlisted)
    ]

    static func ownerPlayerID(at index: Int) -> UUID {
        UUID(uuidString: String(format: "F3B00000-0000-4000-8000-%012d", index + 30))!
    }

    static func plan(for occurrence: FeedOccurrence) -> FeedPlan {
        let calendar = Calendar(identifier: .gregorian)
        let endTime = calendar.date(byAdding: .minute, value: 90, to: occurrence.startAt)
            ?? occurrence.startAt
        return FeedPlan(
            id: templateID,
            name: occurrence.title,
            weekdays: [3],
            startTime: occurrence.startAt,
            endTime: endTime,
            startDate: occurrence.startAt,
            endDate: nil,
            price: occurrence.price,
            totalVenueCost: 480,
            currency: "ر.س",
            capacity: occurrence.capacity,
            capacityPolicy: .waitlist,
            latitude: 24.7743,
            longitude: 46.7386,
            locationName: occurrence.locationName,
            locationAddress: "حي النخيل، الرياض",
            sourceEventID: eventID,
            sourceTemplateID: templateID
        )
    }

    static func members(currentUserID: UUID?, profileName: String) -> [FeedTeamMember] {
        let me = currentUserID ?? memberFallbackID
        let myName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            FeedTeamMember(
                id: organizerID,
                displayName: "مشرف التجربة",
                role: .admin,
                isPending: false
            ),
            FeedTeamMember(
                id: me,
                displayName: myName.isEmpty ? "أنا" : myName,
                role: .member,
                isPending: false
            ),
            FeedTeamMember(
                id: salmanID,
                displayName: "سلمان",
                role: .member,
                isPending: false
            ),
            FeedTeamMember(
                id: UUID(uuidString: "F3B00000-0000-4000-8000-000000000003")!,
                displayName: "عبدالعزيز",
                role: .member,
                isPending: false
            ),
        ]
    }

    /// One player per position the Overall weights differently, so the rating
    /// can be tried against every branch of the weighting table without
    /// editing anyone's profile.
    private static let rosterSeed: [(name: String, position: String)] = [
        ("سلمان", "وسط"),
        ("عبدالعزيز", "هجوم"),
        ("تركي", "دفاع"),
        ("ماجد", "حارس"),
        ("خالد", "وسط"),
        ("نواف", "دفاع")
    ]

    static func roster(referenceDate: Date = .now) -> [FeedMember] {
        rosterSeed.enumerated().map { index, seed in
            let id = playerID(at: index)
            return FeedMember(
                id: id,
                name: seed.name,
                status: .registered,
                // A rating hangs on an account, so these carry one. They are
                // fixture ids: HomeStore answers for them locally and never
                // sends them anywhere.
                userId: id,
                joinedAt: referenceDate.addingTimeInterval(Double(-index) * 3600 - 7200),
                position: seed.position
            )
        }
    }

    static func playerID(at index: Int) -> UUID {
        UUID(uuidString: String(format: "F3B00000-0000-4000-8000-%012d", index + 10))!
    }

    static func isFixturePlayer(_ id: UUID) -> Bool {
        guard isEnabled else { return false }
        return (0..<rosterSeed.count).contains { playerID(at: $0) == id }
            || (0..<ownerRosterSeed.count).contains { ownerPlayerID(at: $0) == id }
    }

    /// My own rating of each fixture player, for the life of the session. It
    /// sits beside the seeded ratings rather than on `HomeStore` because it is
    /// fixture data, not app state, and nothing observes it.
    nonisolated(unsafe) static var submittedRatings: [UUID: PlayerRatingScores] = [:]

    /// Ratings other people already left, so the average the flow reveals is a
    /// crowd's rather than an echo of the one rating just submitted. Two per
    /// player, deterministic, spread wide enough that the six bars differ.
    static func seededRatings(for player: UUID) -> [PlayerRatingScores] {
        let index: Int
        if let i = (0..<rosterSeed.count).first(where: { playerID(at: $0) == player }) {
            index = i
        } else if let i = (0..<ownerRosterSeed.count).first(where: { ownerPlayerID(at: $0) == player }) {
            index = i + rosterSeed.count
        } else {
            return []
        }

        return (0..<2).map { rater in
            var scores = PlayerRatingScores.neutral
            for (offset, attribute) in PlayerAttribute.allCases.enumerated() {
                // A fixed spiral through the range: no randomness, so the same
                // player shows the same numbers on every launch.
                let base = 52 + ((index * 13) + (offset * 17) + (rater * 9)) % 44
                scores[attribute] = base
            }
            return scores
        }
    }

    static func destination(for occurrence: FeedOccurrence) -> PaymentDestination {
        PaymentDestination(
            status: .available,
            eventId: occurrence.id,
            paymentMethodId: nil,
            provider: nil,
            mobileNumber: nil,
            iban: nil,
            accountNumber: nil,
            paymentMethods: paymentMethods,
            totalPrice: 480,
            pricePerPerson: occurrence.price,
            groupSize: nil
        )
    }

    private static func nextTuesdayEvening(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .tamrin
        var components = DateComponents()
        components.weekday = 3
        components.hour = 20
        components.minute = 30
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTimePreservingSmallerComponents
        ) ?? date.addingTimeInterval(7 * 24 * 60 * 60)
    }
}
#endif
