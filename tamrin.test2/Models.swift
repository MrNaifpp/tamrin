import Foundation
import SwiftData

enum MemberRole: String, Codable { case admin, member }
enum CapacityPolicy: String, Codable { case waitlist, closed }
enum RegistrationStatus: String, Codable { case registered, waitlisted }
enum PaymentKind: String, Codable { case bank, cash }
enum PaymentStatus: String, Codable { case unpaid, declared, confirmed }
enum ScheduleKind: String, Codable { case recurring, oneOff }
enum PublicationStatus: String, Codable { case draft, ready, published, cancelled }

@Model final class UserProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var playerPosition: String = ""
    @Attribute(.externalStorage) var avatarData: Data?

    init(id: UUID = UUID(), name: String, avatarData: Data? = nil, playerPosition: String = "", createdAt: Date = .now) {
        self.id = id; self.name = name; self.avatarData = avatarData; self.playerPosition = playerPosition; self.createdAt = createdAt
    }
}

@Model final class Team {
    @Attribute(.unique) var id: UUID
    var name: String
    var inviteCode: String
    var createdAt: Date
    var symbol: String = "figure.run"
    @Attribute(.externalStorage) var avatarData: Data?

    init(id: UUID = UUID(), name: String, inviteCode: String, symbol: String = "figure.run", avatarData: Data? = nil, createdAt: Date = .now) {
        self.id = id; self.name = name; self.inviteCode = inviteCode; self.symbol = symbol; self.avatarData = avatarData; self.createdAt = createdAt
    }
}

@Model final class Membership {
    @Attribute(.unique) var id: UUID
    var teamID: UUID
    var userID: UUID?
    var displayName: String
    var roleRaw: String
    var isPending: Bool

    var role: MemberRole { MemberRole(rawValue: roleRaw) ?? .member }

    init(teamID: UUID, userID: UUID? = nil, displayName: String, role: MemberRole, isPending: Bool = false) {
        self.id = UUID(); self.teamID = teamID; self.userID = userID
        self.displayName = displayName; self.roleRaw = role.rawValue; self.isPending = isPending
    }
}

@Model final class TrainingPlan {
    @Attribute(.unique) var id: UUID
    var teamID: UUID
    var name: String
    var weekdays: [Int]
    var startTime: Date
    var endTime: Date
    var startDate: Date
    var endDate: Date?
    var locationName: String
    var locationAddress: String
    var latitude: Double
    var longitude: Double
    var capacity: Int
    var capacityPolicyRaw: String
    var price: Double
    var currency: String
    var scheduleKindRaw: String = ScheduleKind.recurring.rawValue
    var publishLeadDays: Int = 2
    var publishTime: Date = Calendar.current.date(from: DateComponents(hour: 12)) ?? .now

    var capacityPolicy: CapacityPolicy { CapacityPolicy(rawValue: capacityPolicyRaw) ?? .waitlist }
    var scheduleKind: ScheduleKind { ScheduleKind(rawValue: scheduleKindRaw) ?? .recurring }

    init(teamID: UUID, name: String, weekdays: [Int], startTime: Date, endTime: Date,
         startDate: Date, endDate: Date?, locationName: String, locationAddress: String,
         latitude: Double = 24.7136, longitude: Double = 46.6753, capacity: Int,
         capacityPolicy: CapacityPolicy, price: Double, currency: String = "ر.س",
         scheduleKind: ScheduleKind = .recurring, publishLeadDays: Int = 2,
         publishTime: Date = Calendar.current.date(from: DateComponents(hour: 12)) ?? .now) {
        self.id = UUID(); self.teamID = teamID; self.name = name; self.weekdays = weekdays
        self.startTime = startTime; self.endTime = endTime; self.startDate = startDate; self.endDate = endDate
        self.locationName = locationName; self.locationAddress = locationAddress
        self.latitude = latitude; self.longitude = longitude; self.capacity = capacity
        self.capacityPolicyRaw = capacityPolicy.rawValue; self.price = price; self.currency = currency
        self.scheduleKindRaw = scheduleKind.rawValue; self.publishLeadDays = publishLeadDays; self.publishTime = publishTime
    }
}

@Model final class Occurrence {
    @Attribute(.unique) var id: UUID
    var teamID: UUID
    var planID: UUID
    var startAt: Date
    var endAt: Date
    var locationName: String
    var locationAddress: String
    var capacity: Int
    var capacityPolicyRaw: String
    var price: Double
    var isCancelled: Bool
    var isOverride: Bool
    var publicationStatusRaw: String = PublicationStatus.draft.rawValue
    var publishedAt: Date?
    var cancellationReason: String = ""

    var capacityPolicy: CapacityPolicy { CapacityPolicy(rawValue: capacityPolicyRaw) ?? .waitlist }
    var publicationStatus: PublicationStatus { PublicationStatus(rawValue: publicationStatusRaw) ?? .draft }

    init(teamID: UUID, planID: UUID, startAt: Date, endAt: Date, locationName: String,
         locationAddress: String, capacity: Int, capacityPolicy: CapacityPolicy, price: Double,
         publicationStatus: PublicationStatus = .draft) {
        self.id = UUID(); self.teamID = teamID; self.planID = planID; self.startAt = startAt; self.endAt = endAt
        self.locationName = locationName; self.locationAddress = locationAddress; self.capacity = capacity
        self.capacityPolicyRaw = capacityPolicy.rawValue; self.price = price
        self.isCancelled = false; self.isOverride = false
        self.publicationStatusRaw = publicationStatus.rawValue; self.publishedAt = nil; self.cancellationReason = ""
    }
}

@Model final class Registration {
    @Attribute(.unique) var id: UUID
    var occurrenceID: UUID
    var userID: UUID
    var displayName: String
    var statusRaw: String
    var createdAt: Date

    var status: RegistrationStatus { RegistrationStatus(rawValue: statusRaw) ?? .registered }

    init(occurrenceID: UUID, userID: UUID, displayName: String, status: RegistrationStatus, createdAt: Date = .now) {
        self.id = UUID(); self.occurrenceID = occurrenceID; self.userID = userID
        self.displayName = displayName; self.statusRaw = status.rawValue; self.createdAt = createdAt
    }
}

@Model final class PaymentMethod {
    @Attribute(.unique) var id: UUID
    var teamID: UUID
    var kindRaw: String
    var title: String
    var accountHolder: String
    var iban: String
    var accountNumber: String
    var appURL: String

    var kind: PaymentKind { PaymentKind(rawValue: kindRaw) ?? .bank }

    init(teamID: UUID, kind: PaymentKind, title: String, accountHolder: String = "",
         iban: String = "", accountNumber: String = "", appURL: String = "") {
        self.id = UUID(); self.teamID = teamID; self.kindRaw = kind.rawValue; self.title = title
        self.accountHolder = accountHolder; self.iban = iban; self.accountNumber = accountNumber; self.appURL = appURL
    }
}

@Model final class PaymentRecord {
    @Attribute(.unique) var id: UUID
    var occurrenceID: UUID
    var userID: UUID
    var statusRaw: String
    var updatedAt: Date

    var status: PaymentStatus { PaymentStatus(rawValue: statusRaw) ?? .unpaid }

    init(occurrenceID: UUID, userID: UUID, status: PaymentStatus = .unpaid) {
        self.id = UUID(); self.occurrenceID = occurrenceID; self.userID = userID
        self.statusRaw = status.rawValue; self.updatedAt = .now
    }
}

@Model final class Invite {
    @Attribute(.unique) var id: UUID
    var teamID: UUID
    var code: String
    var createdAt: Date

    init(teamID: UUID, code: String) { self.id = UUID(); self.teamID = teamID; self.code = code; self.createdAt = .now }
}

@Model final class AppNotification {
    @Attribute(.unique) var id: UUID
    var userID: UUID
    var title: String
    var message: String
    var createdAt: Date
    var isRead: Bool
    var occurrenceID: UUID?

    init(userID: UUID, title: String, message: String, occurrenceID: UUID? = nil) {
        self.id = UUID(); self.userID = userID; self.title = title; self.message = message
        self.createdAt = .now; self.isRead = false; self.occurrenceID = occurrenceID
    }
}

struct PaymentMethodDraft: Identifiable, Hashable {
    var id = UUID()
    var kind: PaymentKind = .bank
    var title = ""
    var accountHolder = ""
    var iban = ""
    var accountNumber = ""
    var appURL = ""
}

struct PlanDraft: Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var weekdays: Set<Int> = []
    var startTime = Calendar.current.date(from: DateComponents(hour: 20)) ?? .now
    var endTime = Calendar.current.date(from: DateComponents(hour: 21, minute: 30)) ?? .now
    var locationName = ""
    var locationAddress = ""
    var latitude = 24.7136
    var longitude = 46.6753
    var capacity = 12
    var capacityPolicy: CapacityPolicy = .waitlist
    var price = 0.0
    var scheduleKind: ScheduleKind = .recurring
    var oneOffDate = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    var publishLeadDays = 2
    var publishTime = Calendar.current.date(from: DateComponents(hour: 12)) ?? .now
}

struct TeamDraft {
    var teamName = ""
    var teamSymbol = "figure.soccer"
    var avatarData: Data?
    var invitedNames: [String] = []
    var plans: [PlanDraft] = []
    var paymentMethods: [PaymentMethodDraft] = []
    var startDate = Date.now
}
