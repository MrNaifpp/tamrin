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

    // MARK: The other sports
    //
    // The three groups above all play football, and the photo a card wears
    // comes from its group's sport — so nothing on Home ever showed a
    // volleyball court or a padel cage, however many photos sat in those
    // folders. One group per remaining sport that has artwork fixes that.
    //
    // The event ids are not arbitrary. `SportArtLibrary` picks a photo by
    // walking the id's bytes, so these were chosen to land on different photos
    // within each sport: two volleyball exercises that wear the same picture
    // would defeat the point of adding the second one.
    static let volleyTeamID = UUID(uuidString: "D3B00000-0000-4000-8000-000000000004")!
    static let volleyOpenEventID = UUID(uuidString: "E3B00000-0000-4000-8000-000000000013")!
    static let volleyLeagueEventID = UUID(uuidString: "E3B00000-0000-4000-8000-000000000011")!
    private static let volleyOpenTemplateID = UUID(uuidString: "C3B00000-0000-4000-8000-000000000004")!
    private static let volleyLeagueTemplateID = UUID(uuidString: "C3B00000-0000-4000-8000-000000000005")!

    static let basketTeamID = UUID(uuidString: "D3B00000-0000-4000-8000-000000000005")!
    static let basketEventID = UUID(uuidString: "E3B00000-0000-4000-8000-000000000015")!
    private static let basketTemplateID = UUID(uuidString: "C3B00000-0000-4000-8000-000000000006")!

    static let padelTeamID = UUID(uuidString: "D3B00000-0000-4000-8000-000000000006")!
    static let padelEventID = UUID(uuidString: "E3B00000-0000-4000-8000-000000000010")!
    private static let padelTemplateID = UUID(uuidString: "C3B00000-0000-4000-8000-000000000007")!

    // Exercises that have already happened. Home can show either half of the
    // calendar now, and without these the past half is an empty page — the
    // fixture has to carry both or only one of them is testable.
    static let volleyPastEventID = UUID(uuidString: "E3B00000-0000-4000-8000-000000000021")!
    static let basketPastEventID = UUID(uuidString: "E3B00000-0000-4000-8000-000000000022")!
    static let padelPastEventID = UUID(uuidString: "E3B00000-0000-4000-8000-000000000023")!

    /// The exercises whose players all wear a photograph. Everywhere else the
    /// roster falls back to an initial in a disc, which is what a real group
    /// mostly looks like — these two exist to show the other end of it.
    static let photoEventIDs: Set<UUID> = [volleyOpenEventID, basketEventID]

    private static let stcBankMethodID = UUID(uuidString: "B3B00000-0000-4000-8000-000000000001")!
    private static let barqMethodID = UUID(uuidString: "B3B00000-0000-4000-8000-000000000002")!
    private static let alRajhiMethodID = UUID(uuidString: "B3B00000-0000-4000-8000-000000000003")!
    private static let snbMethodID = UUID(uuidString: "B3B00000-0000-4000-8000-000000000004")!

    static let team = FeedTeam(
        id: teamID,
        name: "عضو: قبول فوري وتقييم",
        symbol: "figure.soccer",
        color: .lime,
        avatarData: nil,
        memberCount: 18,
        inviteCode: "DEMO-USER"
    )

    static let paidMemberTeam = FeedTeam(
        id: paidMemberTeamID,
        name: "عضو: القطة والضيوف",
        // Football, like the group above and the one below. The symbol is the
        // sport, and the sport is what picks the photo — a generic icon here
        // meant this group fell back to the shipped artwork and the soccer
        // folder was never read for it.
        symbol: "figure.soccer",
        color: .orange,
        avatarData: nil,
        memberCount: 16,
        inviteCode: "DEMO-PAID"
    )

    static let ownerTeam = FeedTeam(
        id: ownerTeamID,
        name: "مشرف: كل الحالات",
        symbol: "figure.soccer",
        color: .purple,
        avatarData: nil,
        memberCount: 12,
        inviteCode: "DEMO-OWNER"
    )

    static let volleyTeam = FeedTeam(
        id: volleyTeamID,
        name: "طائرة الشاطئ",
        symbol: "figure.volleyball",
        color: .blue,
        avatarData: nil,
        memberCount: 14,
        inviteCode: "DEMO-VOLLEY"
    )

    static let basketTeam = FeedTeam(
        id: basketTeamID,
        name: "سلة الأربعاء",
        symbol: "figure.basketball",
        color: .red,
        avatarData: nil,
        memberCount: 12,
        inviteCode: "DEMO-BASKET"
    )

    static let padelTeam = FeedTeam(
        id: padelTeamID,
        name: "بادل نهاية الأسبوع",
        // SF Symbols has no padel figure; `Sport` stands pickleball in for it,
        // and `Sport.key` maps that symbol to the `padel` art folder.
        symbol: "figure.pickleball",
        color: .yellow,
        avatarData: nil,
        memberCount: 8,
        inviteCode: "DEMO-PADEL"
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
            title: "تمرين مجاني بقبول فوري",
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
            title: "تمرين مدفوع مع القطة والضيوف",
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
            title: "مراجعة اللاعبين والطلبات",
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

    /// Two volleyball exercises rather than one: the pair is what shows that
    /// the photo follows the exercise and not the sport — same court, same
    /// group, different picture.
    static func volleyOpenOccurrence(referenceDate: Date = .now) -> FeedOccurrence {
        FeedOccurrence(
            id: volleyOpenEventID,
            title: "طائرة مفتوحة على الرمل",
            startAt: nextTuesdayEvening(after: referenceDate).addingTimeInterval(3 * 24 * 60 * 60),
            locationName: "شاطئ نصف القمر",
            capacity: 12,
            price: 0,
            isCancelled: false,
            artIndex: 1,
            isRecurring: true,
            templateId: volleyOpenTemplateID,
            paymentMethodIds: [],
            publishedAt: referenceDate,
            memberResponse: .invited
        )
    }

    static func volleyLeagueOccurrence(referenceDate: Date = .now) -> FeedOccurrence {
        FeedOccurrence(
            id: volleyLeagueEventID,
            title: "دوري الطائرة، الجولة الثالثة",
            startAt: nextTuesdayEvening(after: referenceDate).addingTimeInterval(5 * 24 * 60 * 60),
            locationName: "صالة الأمير فيصل",
            capacity: 14,
            price: 25,
            isCancelled: false,
            artIndex: 2,
            isRecurring: true,
            templateId: volleyLeagueTemplateID,
            paymentMethodIds: paymentMethodIDs,
            publishedAt: referenceDate
        )
    }

    static func basketOccurrence(referenceDate: Date = .now) -> FeedOccurrence {
        FeedOccurrence(
            id: basketEventID,
            title: "سلة نص الأسبوع",
            startAt: nextTuesdayEvening(after: referenceDate).addingTimeInterval(4 * 24 * 60 * 60),
            locationName: "صالة الروابي",
            capacity: 10,
            price: 20,
            isCancelled: false,
            artIndex: 3,
            isRecurring: true,
            templateId: basketTemplateID,
            paymentMethodIds: paymentMethodIDs,
            publishedAt: referenceDate
        )
    }

    static func padelOccurrence(referenceDate: Date = .now) -> FeedOccurrence {
        FeedOccurrence(
            id: padelEventID,
            title: "بادل بملعبين محجوزين",
            startAt: nextTuesdayEvening(after: referenceDate).addingTimeInterval(6 * 24 * 60 * 60),
            locationName: "نادي الواحة للبادل",
            capacity: 8,
            price: 60,
            isCancelled: false,
            artIndex: 1,
            isRecurring: false,
            templateId: padelTemplateID,
            paymentMethodIds: paymentMethodIDs,
            publishedAt: referenceDate
        )
    }

    /// One that has already been played, `daysAgo` back.
    ///
    /// Counted from today, not from the next Tuesday the upcoming exercises
    /// hang off: that anchor is up to a week ahead, so subtracting a few days
    /// from it can still land in the future — which is how the first of these
    /// turned up on the upcoming shelf.
    private static func playedOccurrence(
        id: UUID,
        title: String,
        locationName: String,
        daysAgo: Int,
        price: Double,
        artIndex: Int,
        referenceDate: Date
    ) -> FeedOccurrence {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .tamrin
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: referenceDate) ?? referenceDate
        let startAt = calendar.date(bySettingHour: 20, minute: 30, second: 0, of: day) ?? day
        return FeedOccurrence(
            id: id,
            title: title,
            startAt: startAt,
            locationName: locationName,
            capacity: 12,
            price: price,
            isCancelled: false,
            artIndex: artIndex,
            isRecurring: false,
            templateId: nil,
            paymentMethodIds: [],
            publishedAt: startAt.addingTimeInterval(-3 * 24 * 60 * 60)
        )
    }

    static func volleyPastOccurrence(referenceDate: Date = .now) -> FeedOccurrence {
        playedOccurrence(
            id: volleyPastEventID,
            title: "طائرة الأسبوع الماضي",
            locationName: "شاطئ نصف القمر",
            daysAgo: 3,
            price: 0,
            artIndex: 2,
            referenceDate: referenceDate
        )
    }

    static func basketPastOccurrence(referenceDate: Date = .now) -> FeedOccurrence {
        playedOccurrence(
            id: basketPastEventID,
            title: "سلة، الجولة الثانية",
            locationName: "صالة الروابي",
            daysAgo: 10,
            price: 20,
            artIndex: 3,
            referenceDate: referenceDate
        )
    }

    static func padelPastOccurrence(referenceDate: Date = .now) -> FeedOccurrence {
        playedOccurrence(
            id: padelPastEventID,
            title: "بادل بملعب واحد",
            locationName: "نادي الواحة للبادل",
            // A previous month makes the archive's section transition and
            // backdrop change testable in the local fixture.
            daysAgo: 40,
            price: 45,
            artIndex: 1,
            referenceDate: referenceDate
        )
    }

    static func paidMemberRoster(
        currentUserID: UUID?,
        profileName: String,
        referenceDate: Date = .now
    ) -> [FeedMember] {
        let me = currentUserID ?? memberFallbackID
        let myName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        // The full ten from the shared seed, not seven: this exercise carries a
        // saved split, and a split wants two sides worth of players.
        var rows = Array(roster(referenceDate: referenceDate).prefix(10))
        rows.insert(
            FeedMember(
                id: me,
                name: myName.isEmpty ? "أنت" : myName,
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
                name: "ضيف سلمان القحطاني",
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
                name: "طلال المطيري",
                status: .paymentPending,
                userId: UUID(uuidString: "F3B00000-0000-4000-8000-000000000082")!,
                joinedAt: referenceDate.addingTimeInterval(-95 * 60),
                position: "وسط"
            )
        )
        rows.append(
            FeedMember(
                id: UUID(uuidString: "F3B00000-0000-4000-8000-000000000083")!,
                name: "زياد البقمي",
                status: .registered,
                userId: UUID(uuidString: "F3B00000-0000-4000-8000-000000000083")!,
                joinedAt: referenceDate.addingTimeInterval(-110 * 60),
                position: "دفاع"
            )
        )
        // Up to the exercise's full capacity of sixteen.
        rows += paidExtraSeed.enumerated().map { index, player in
            let id = UUID(uuidString: String(format: "F3B00000-0000-4000-8000-%012d", 300 + index))!
            return FeedMember(
                id: id,
                name: player.name,
                status: .registered,
                userId: id,
                joinedAt: referenceDate.addingTimeInterval(Double(-index) * 2400 - 7200),
                position: player.position
            )
        }
        return rows
    }

    /// Ten from the shared seed, me, a guest, two payment-state rows and these
    /// two make the exercise's full sixteen.
    private static let paidExtraSeed: [(name: String, position: String)] = [
        ("عبدالله الشثري", "هجوم"), ("مازن الدوسري", "وسط")
    ]

    /// The split this exercise ships with, so the lineup is there to read
    /// without anyone building one first — and so the signed-in tester is on
    /// the **second** side, which is the case the exercise page's own
    /// "open my team's card" rule exists for and the harder one to reach by
    /// hand.
    static func paidMemberPlan(currentUserID: UUID?, profileName: String) -> LineupPlan {
        let roster = paidMemberRoster(currentUserID: currentUserID, profileName: profileName)
        let me = currentUserID ?? memberFallbackID
        let others = roster.map(\.id).filter { $0 != me }
        let half = others.count / 2
        var plan = LineupPlan(teams: LineupTeams())
        plan.first = Array(others.prefix(half))
        plan.second = [me] + Array(others.dropFirst(half))
        return plan
    }

    /// The organizer group deliberately holds every row shape the production
    /// RPC can return. Shared `paymentOwnerId` values make member+guest payment
    /// batches render one confirm/reject action, while the standalone guest
    /// batch has no participant row for its registrar.
    ///
    /// Twelve people, all seated, all with a full name and a position: the
    /// exercise exists to be split into two sides, and a roster of half-named
    /// players without positions cannot exercise that. The guests carry
    /// positions too; production leaves theirs empty, and the lineup places
    /// those players in midfield until the organizer moves them for the night.
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
                name: "باسل العسكر",
                status: .paymentPending,
                addedBy: pendingMemberID,
                joinedAt: referenceDate.addingTimeInterval(-50 * 60),
                position: "هجوم"
            ),
            at: 2
        )
        rows.append(
            FeedMember(
                id: UUID(uuidString: "F3B00000-0000-4000-8000-000000000092")!,
                name: "عبدالمحسن أبومالح",
                status: .paymentPending,
                addedBy: guestOnlyRegistrarID,
                joinedAt: referenceDate.addingTimeInterval(-35 * 60),
                position: "وسط"
            )
        )
        rows.append(
            FeedMember(
                id: UUID(uuidString: "F3B00000-0000-4000-8000-000000000093")!,
                name: "محمد الشيخ",
                status: .registered,
                addedBy: salmanID,
                joinedAt: referenceDate.addingTimeInterval(-5 * 60 * 60),
                position: "دفاع"
            )
        )
        rows.append(
            FeedMember(
                id: UUID(uuidString: "F3B00000-0000-4000-8000-000000000094")!,
                name: "أحمد رشوان",
                status: .registered,
                addedBy: memberFallbackID,
                isManual: true,
                joinedAt: referenceDate.addingTimeInterval(-6 * 60 * 60),
                position: "دفاع"
            )
        )
        return rows
    }

    // MARK: Rosters for the other sports

    /// Positions belong to the sport, not to the app. A volleyball roster full
    /// of «حارس» and «وسط» would read as football with the picture swapped,
    /// which is the thing these groups exist to stop.
    private static let volleySeed: [(name: String, position: String)] = [
        ("فيصل الدوسري", "معد"), ("عبدالله القرني", "ضارب"), ("سعود المالكي", "ليبرو"),
        ("بندر الحارثي", "صد"), ("مشعل العنزي", "ضارب"), ("تركي الرشيد", "معد"),
        ("راكان الجهني", "صد"), ("عمر الصاعدي", "ليبرو"), ("نايف البلوي", "ضارب")
    ]

    private static let basketSeed: [(name: String, position: String)] = [
        ("سلطان الشهراني", "صانع ألعاب"), ("محمد الزهراني", "جناح"), ("أنس الغامدي", "ارتكاز"),
        ("وليد العسيري", "جناح"), ("هيثم القحطاني", "صانع ألعاب"), ("زياد الحربي", "ارتكاز"),
        ("خالد البقمي", "جناح"), ("إبراهيم السلمي", "جناح"), ("أحمد الشمراني", "ارتكاز")
    ]

    private static let padelSeed: [(name: String, position: String)] = [
        ("ياسر المطيري", "يمين"), ("معاذ العتيبي", "يسار"), ("صالح الخالدي", "يمين"),
        ("فهد السبيعي", "يسار"), ("عبدالإله النفيعي", "يمين"), ("طلال الرويلي", "يسار"),
        ("سامي الثقفي", "يمين"), ("منصور الأحمدي", "يسار")
    ]

    /// A roster for one of the sport groups. `wearsPhotos` is what makes every
    /// player carry a photograph instead of an initial; it is the exercise's
    /// property, not the group's, so one exercise in a group can show faces
    /// while the next one beside it does not.
    private static func sportRoster(
        seed: [(name: String, position: String)],
        idBase: Int,
        wearsPhotos: Bool,
        referenceDate: Date
    ) -> [FeedMember] {
        seed.enumerated().map { index, player in
            let id = UUID(uuidString: String(format: "F3B00000-0000-4000-8000-%012d", idBase + index))!
            return FeedMember(
                id: id,
                name: player.name,
                status: .registered,
                userId: id,
                joinedAt: referenceDate.addingTimeInterval(Double(-index) * 4200 - 5400),
                avatarUrl: wearsPhotos ? DemoFaces.photo(at: index) : nil,
                position: player.position
            )
        }
    }

    static func volleyOpenRoster(referenceDate: Date = .now) -> [FeedMember] {
        sportRoster(seed: volleySeed, idBase: 200, wearsPhotos: true, referenceDate: referenceDate)
    }

    static func volleyLeagueRoster(referenceDate: Date = .now) -> [FeedMember] {
        sportRoster(seed: volleySeed.reversed(), idBase: 220, wearsPhotos: false, referenceDate: referenceDate)
    }

    static func basketRoster(referenceDate: Date = .now) -> [FeedMember] {
        sportRoster(seed: basketSeed, idBase: 240, wearsPhotos: true, referenceDate: referenceDate)
    }

    static func padelRoster(referenceDate: Date = .now) -> [FeedMember] {
        sportRoster(seed: padelSeed, idBase: 260, wearsPhotos: false, referenceDate: referenceDate)
    }

    /// The photographs in `DemoFaces/`, read from the bundle at runtime.
    ///
    /// Same contract as `SportArtLibrary`: a folder reference, no naming rule,
    /// no list to keep in step. Empty folder — which is how the repository
    /// ships, since photographs of people are not something source control
    /// should be carrying by default — means every player falls back to an
    /// initial in a disc, exactly as before.
    enum DemoFaces {
        private static let root = "DemoFaces"
        private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]

        private static var cached: [String]?

        static var all: [String] {
            if let cached { return cached }
            let directory = Bundle.main.bundleURL.appendingPathComponent(root)
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted()
                .map { directory.appendingPathComponent($0).absoluteString }
            cached = files
            return files
        }

        /// The photo for the player in `index`. Wraps, so a folder holding
        /// fewer photos than the roster still dresses everyone — repeating a
        /// face reads better than half the group in discs.
        static func photo(at index: Int) -> String? {
            let files = all
            guard !files.isEmpty else { return nil }
            return files[index % files.count]
        }
    }

    static let guestOnlyRegistrarID = UUID(uuidString: "F3B00000-0000-4000-8000-000000000007")!

    /// The people who actually play in this group, each in the position he
    /// plays in — the positions are the organizer's own list, not something
    /// derived. The first rows keep the payment states the group exists to
    /// exercise: the second pays for himself and a guest, the third has
    /// already been nudged about his share.
    private static let ownerAccountSeed: [(name: String, position: String, status: FeedRegStatus)] = [
        ("خالد مسلمي", "دفاع", .registered),
        ("عبدالرحمن الخزيم", "وسط", .paymentPending),
        ("يحيى بن قحم", "دفاع", .registered),
        ("مراد الجهني", "وسط", .registered),
        ("لؤي الزهراني", "وسط", .registered),
        ("عماد العسيري", "وسط", .registered),
        ("بدر الشهري", "وسط", .registered),
        ("خالد الشهري", "وسط", .registered)
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
                displayName: myName.isEmpty ? "أنت" : myName,
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
                displayName: "وليد الغامدي",
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
        ("سلمان القحطاني", "وسط"),
        ("عبدالعزيز الشمري", "هجوم"),
        ("تركي العتيبي", "دفاع"),
        ("ماجد الغامدي", "حارس"),
        ("خالد الدوسري", "وسط"),
        ("نواف السبيعي", "دفاع"),
        ("ريان الحربي", "هجوم"),
        ("حمزة المطيري", "وسط"),
        ("ياسر الزهراني", "دفاع"),
        ("زياد الشهري", "هجوم")
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
        // Nobody in the organizer group has been rated yet: that group is for
        // running an exercise end to end, and a lineup built from unrated
        // players is the ordinary case it has to handle.
        guard let index = (0..<rosterSeed.count).first(where: { playerID(at: $0) == player })
        else { return [] }

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
