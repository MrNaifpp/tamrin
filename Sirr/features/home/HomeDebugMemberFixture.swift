#if DEBUG
import Foundation

/// A deterministic, device-testable member journey that exists only in Debug
/// builds. It deliberately has no matching Supabase rows; `HomeStore` handles
/// every interaction with these ids locally so testing it can never mutate
/// production data.
enum HomeDebugMemberFixture {
    /// The launch argument keeps the fixture opt-in for ordinary Debug builds.
    /// The dedicated `.local` bundle is the installable QA copy, so it also
    /// enables the fixture when opened directly from the iPhone home screen.
    /// Neither path exists in a Release build because this whole file is DEBUG-only.
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-demoMemberFixture")
        || Bundle.main.bundleIdentifier?.hasSuffix(".tamrin.local") == true
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

    /// A paid member-side scenario. It is separate from the free scenario so
    /// instant confirmation, contribution access, and post-registration guest
    /// registration can all be tried without resetting fixture state.
    static let paidMemberTeamID = UUID(uuidString: "D3B00000-0000-4000-8000-000000000003")!
    static let paidMemberEventID = UUID(uuidString: "E3B00000-0000-4000-8000-000000000003")!
    static let paidMemberTemplateID = UUID(uuidString: "C3B00000-0000-4000-8000-000000000003")!

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
        name: "١ — عضو: قبول فوري وتقييم",
        symbol: "figure.soccer",
        color: .lime,
        avatarData: nil,
        memberCount: 18,
        inviteCode: "DEMO-USER"
    )

    static let paidMemberTeam = FeedTeam(
        id: paidMemberTeamID,
        name: "٢ — عضو: القطة والضيوف",
        symbol: "person.3.fill",
        color: .orange,
        avatarData: nil,
        memberCount: 16,
        inviteCode: "DEMO-PAID"
    )

    static let ownerTeam = FeedTeam(
        id: ownerTeamID,
        name: "٣ — مشرف: كل الحالات",
        symbol: "shield.checkered",
        color: .purple,
        avatarData: nil,
        memberCount: 16,
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
            title: "مجاني — سجّل ويتأكد فورًا",
            startAt: nextTuesdayEvening(after: referenceDate),
            locationName: "ملعب النخيل",
            capacity: 18,
            price: 0,
            isCancelled: false,
            artIndex: 2,
            isRecurring: true,
            templateId: templateID,
            paymentMethodIds: [],
            publishedAt: referenceDate,
            memberResponse: .invited
        )
    }

    static func paidMemberOccurrence(referenceDate: Date = .now) -> FeedOccurrence {
        FeedOccurrence(
            id: paidMemberEventID,
            title: "مدفوع — جرّب القطة وإضافة ضيف",
            startAt: nextTuesdayEvening(after: referenceDate).addingTimeInterval(24 * 60 * 60),
            locationName: "ملعب الندى",
            capacity: 16,
            price: 30,
            isCancelled: false,
            artIndex: 3,
            isRecurring: true,
            templateId: paidMemberTemplateID,
            paymentMethodIds: paymentMethodIDs,
            publishedAt: referenceDate,
            paymentReminderSentAt: referenceDate.addingTimeInterval(-15 * 60)
        )
    }

    static func ownerOccurrence(referenceDate: Date = .now) -> FeedOccurrence {
        FeedOccurrence(
            id: ownerEventID,
            title: "كل الحالات — راجع اللاعبين والطلبات",
            startAt: nextTuesdayEvening(after: referenceDate).addingTimeInterval(2 * 24 * 60 * 60),
            locationName: "ملعب الرواد",
            capacity: 16,
            price: 45,
            isCancelled: false,
            artIndex: 1,
            isRecurring: false,
            templateId: ownerTemplateID,
            paymentMethodIds: paymentMethodIDs,
            publishedAt: referenceDate
        )
    }

    static func paidMemberRoster(
        currentUserID: UUID?,
        profileName: String,
        referenceDate: Date = .now
    ) -> [FeedMember] {
        let me = currentUserID ?? memberFallbackID
        let myName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = Array(roster(referenceDate: referenceDate).prefix(7))
        rows.insert(
            FeedMember(
                id: me,
                name: myName.isEmpty ? "أنا — مسجل وباقي القطة" : myName,
                status: .awaitingPayment,
                userId: me,
                joinedAt: referenceDate.addingTimeInterval(-3 * 60 * 60),
                position: "وسط"
            ),
            at: 0
        )
        rows.append(
            FeedMember(
                id: UUID(uuidString: "F3B00000-0000-4000-8000-000000000081")!,
                name: "ضيف سلمان — جرّب خانة سجّله",
                status: .registered,
                addedBy: salmanID,
                joinedAt: referenceDate.addingTimeInterval(-75 * 60)
            )
        )
        // The two states my own seat is not in, so the three are visible at
        // once: held and unpaid, declared and waiting, and confirmed.
        rows.append(
            FeedMember(
                id: UUID(uuidString: "F3B00000-0000-4000-8000-000000000082")!,
                name: "طلال — حوّل وينتظر تأكيد المشرف",
                status: .paymentPending,
                userId: UUID(uuidString: "F3B00000-0000-4000-8000-000000000082")!,
                joinedAt: referenceDate.addingTimeInterval(-95 * 60),
                position: "وسط"
            )
        )
        rows.append(
            FeedMember(
                id: UUID(uuidString: "F3B00000-0000-4000-8000-000000000083")!,
                name: "زياد — قطته مؤكدة",
                status: .registered,
                userId: UUID(uuidString: "F3B00000-0000-4000-8000-000000000083")!,
                joinedAt: referenceDate.addingTimeInterval(-110 * 60),
                position: "دفاع"
            )
        )
        return rows
    }

    /// The organizer group deliberately holds every row shape the production
    /// RPC can return. Shared `paymentOwnerId` values make member+guest payment
    /// batches render one confirm/reject action, while the standalone guest
    /// batch has no participant row for its registrar.
    static func ownerRoster(referenceDate: Date = .now) -> [FeedMember] {
        var rows = ownerAccountSeed.enumerated().map { index, seed in
            let id = ownerPlayerID(at: index)
            return FeedMember(
                id: id,
                name: seed.name,
                status: seed.status,
                userId: id,
                joinedAt: referenceDate.addingTimeInterval(Double(-index) * 5400 - 3600),
                position: seed.position,
                paymentReminderSentAt: index == 2
                    ? referenceDate.addingTimeInterval(-20 * 60)
                    : nil
            )
        }
        let pendingMemberID = ownerPlayerID(at: 1)
        rows.insert(
            FeedMember(
                id: UUID(uuidString: "F3B00000-0000-4000-8000-000000000091")!,
                name: "ضيف مشعل — ضمن نفس طلب الدفع",
                status: .paymentPending,
                addedBy: pendingMemberID,
                joinedAt: referenceDate.addingTimeInterval(-50 * 60)
            ),
            at: 2
        )
        rows.append(
            FeedMember(
                id: UUID(uuidString: "F3B00000-0000-4000-8000-000000000092")!,
                name: "ضيف مستقل — صاحبه غير مسجل",
                status: .paymentPending,
                addedBy: guestOnlyRegistrarID,
                joinedAt: referenceDate.addingTimeInterval(-35 * 60)
            )
        )
        rows.append(
            FeedMember(
                id: UUID(uuidString: "F3B00000-0000-4000-8000-000000000093")!,
                name: "ضيف سلمان — مؤكد",
                status: .registered,
                addedBy: salmanID,
                joinedAt: referenceDate.addingTimeInterval(-5 * 60 * 60)
            )
        )
        rows.append(
            FeedMember(
                id: UUID(uuidString: "F3B00000-0000-4000-8000-000000000094")!,
                name: "لاعب يدوي — سجّله المشرف",
                status: .registered,
                addedBy: memberFallbackID,
                isManual: true,
                joinedAt: referenceDate.addingTimeInterval(-6 * 60 * 60)
            )
        )
        return rows
    }

    static let guestOnlyRegistrarID = UUID(uuidString: "F3B00000-0000-4000-8000-000000000007")!

    private static let ownerAccountSeed: [(name: String, position: String, status: FeedRegStatus)] = [
        ("بندر — مسجل", "هجوم", .registered),
        ("مشعل — طلب دفع مع ضيف", "دفاع", .paymentPending),
        ("سعود — مسجل وتذكيره متاح", "وسط", .registered),
        ("راكان — حارس", "حارس", .registered),
        ("فهد — في الانتظار", "هجوم", .waitlisted)
    ]

    static func ownerPlayerID(at index: Int) -> UUID {
        UUID(uuidString: String(format: "F3B00000-0000-4000-8000-%012d", index + 30))!
    }

    static func plan(for occurrence: FeedOccurrence) -> FeedPlan {
        let calendar = Calendar(identifier: .gregorian)
        let endTime = calendar.date(byAdding: .minute, value: 90, to: occurrence.startAt)
            ?? occurrence.startAt
        let occurrenceTemplateID = occurrence.templateId ?? occurrence.id
        return FeedPlan(
            id: occurrenceTemplateID,
            name: occurrence.title,
            weekdays: [3],
            startTime: occurrence.startAt,
            endTime: endTime,
            startDate: occurrence.startAt,
            endDate: nil,
            price: occurrence.price,
            totalVenueCost: occurrence.price * Double(max(occurrence.capacity, 1)),
            currency: "ر.س",
            capacity: occurrence.capacity,
            capacityPolicy: .waitlist,
            latitude: 24.7743,
            longitude: 46.7386,
            locationName: occurrence.locationName,
            locationAddress: "حي النخيل، الرياض",
            sourceEventID: occurrence.id,
            sourceTemplateID: occurrenceTemplateID
        )
    }

    static func memberTeamMembers(currentUserID: UUID?, profileName: String) -> [FeedTeamMember] {
        let me = currentUserID ?? memberFallbackID
        let myName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = [
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
        ]
        result.append(contentsOf: rosterSeed.enumerated().map { index, seed in
            FeedTeamMember(
                id: playerID(at: index),
                displayName: seed.name,
                role: .member,
                isPending: false,
                position: seed.position
            )
        })
        return result
    }

    /// Kept as the shared preview helper used by focused debug screens.
    static func members(currentUserID: UUID?, profileName: String) -> [FeedTeamMember] {
        memberTeamMembers(currentUserID: currentUserID, profileName: profileName)
    }

    static func ownerTeamMembers(currentUserID: UUID?, profileName: String) -> [FeedTeamMember] {
        let me = currentUserID ?? memberFallbackID
        let myName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = [
            FeedTeamMember(
                id: me,
                displayName: myName.isEmpty ? "أنا — مشرف التجربة" : myName,
                role: .admin,
                isPending: false
            ),
            FeedTeamMember(
                id: salmanID,
                displayName: "سلمان",
                role: .member,
                isPending: false
            ),
            FeedTeamMember(
                id: guestOnlyRegistrarID,
                displayName: "وليد — سجّل ضيفًا فقط",
                role: .member,
                isPending: false
            ),
        ]
        result.append(contentsOf: ownerAccountSeed.enumerated().map { index, seed in
            FeedTeamMember(
                id: ownerPlayerID(at: index),
                displayName: seed.name,
                role: .member,
                isPending: false
            )
        })
        return result
    }

    /// One player per position the Overall weights differently, so the rating
    /// can be tried against every branch of the weighting table without
    /// editing anyone's profile.
    private static let rosterSeed: [(name: String, position: String)] = [
        ("سلمان — بلا تقييم حتى الآن", "وسط"),
        ("عبدالعزيز — سبق وقيّمته", "هجوم"),
        ("تركي — مدافع", "دفاع"),
        ("ماجد — حارس", "حارس"),
        ("خالد — وسط", "وسط"),
        ("نواف — مدافع", "دفاع"),
        ("ريان — مهاجم", "هجوم"),
        ("حمزة — وسط", "وسط"),
        ("ياسر — مدافع", "دفاع"),
        ("زياد — مهاجم", "هجوم")
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
        if index == 0 { return salmanID }
        return UUID(uuidString: String(format: "F3B00000-0000-4000-8000-%012d", index + 10))!
    }

    static func isFixturePlayer(_ id: UUID) -> Bool {
        guard isEnabled else { return false }
        return (0..<rosterSeed.count).contains { playerID(at: $0) == id }
            || (0..<ownerAccountSeed.count).contains { ownerPlayerID(at: $0) == id }
    }

    /// My own rating of each fixture player, for the life of the session. It
    /// sits beside the seeded ratings rather than on `HomeStore` because it is
    /// fixture data, not app state, and nothing observes it.
    nonisolated(unsafe) static var submittedRatings: [UUID: PlayerRatingScores] = [
        playerID(at: 1): PlayerRatingScores(
            pace: 82,
            passing: 76,
            shooting: 91,
            stamina: 79,
            defending: 54,
            awareness: 87
        )
    ]

    /// Ratings other people already left, so the average the flow reveals is a
    /// crowd's rather than an echo of the one rating just submitted. Two per
    /// player, deterministic, spread wide enough that the six bars differ.
    static func seededRatings(for player: UUID) -> [PlayerRatingScores] {
        let index: Int
        if let i = (0..<rosterSeed.count).first(where: { playerID(at: $0) == player }) {
            index = i
        } else if let i = (0..<ownerAccountSeed.count).first(where: { ownerPlayerID(at: $0) == player }) {
            index = i + rosterSeed.count
        } else {
            return []
        }

        // The first player's empty aggregate exercises the exact
        // "باقي ما قُيم" state. Every other account starts with a crowd average.
        if player == playerID(at: 0) { return [] }

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
        let isFree = occurrence.price <= 0
        return PaymentDestination(
            status: isFree ? .free : .available,
            eventId: occurrence.id,
            paymentMethodId: nil,
            provider: nil,
            mobileNumber: nil,
            iban: nil,
            accountNumber: nil,
            paymentMethods: isFree ? [] : paymentMethods,
            totalPrice: occurrence.price * Double(max(occurrence.capacity, 1)),
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
