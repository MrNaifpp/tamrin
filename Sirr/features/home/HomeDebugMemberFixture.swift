#if DEBUG
import Foundation

/// A deterministic, device-testable member journey that exists only in Debug
/// builds. It deliberately has no matching Supabase rows; `HomeStore` handles
/// every interaction with these ids locally so testing it can never mutate
/// production data.
enum HomeDebugMemberFixture {
    static let teamID = UUID(uuidString: "D3B00000-0000-4000-8000-000000000001")!
    static let organizerID = UUID(uuidString: "A3B00000-0000-4000-8000-000000000001")!
    static let memberFallbackID = UUID(uuidString: "F3B00000-0000-4000-8000-000000000001")!
    static let eventID = UUID(uuidString: "E3B00000-0000-4000-8000-000000000001")!
    static let templateID = UUID(uuidString: "C3B00000-0000-4000-8000-000000000001")!

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
            memberResponse: .invited
        )
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
                id: UUID(uuidString: "F3B00000-0000-4000-8000-000000000002")!,
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

    static func roster() -> [FeedMember] {
        ["سلمان", "عبدالعزيز", "تركي", "ماجد", "خالد", "نواف"].enumerated().map { index, name in
            FeedMember(
                id: UUID(uuidString: String(format: "F3B00000-0000-4000-8000-%012d", index + 10))!,
                name: name,
                status: .registered
            )
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
