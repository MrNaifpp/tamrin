import SwiftUI

struct EventData: Identifiable, Hashable {
    let id: UUID
    let creatorId: UUID
    let name: String
    let date: String
    /// Real start/end timestamps (the `date` string above is for display only).
    let startDate: Date
    let endDate: Date?
    /// When nil, UI uses a default placeholder image (e.g. card1).
    let imageUrl: String?
    let registrationLocked: Bool
    let totalPrice: Int
    let pricePerPerson: Double
    let maxParticipants: Int?
    /// Free-text place name; empty when the creator didn't set one.
    let location: String
    let latitude: Double?
    let longitude: Double?
    /// Non-nil when this event belongs to a recurring series.
    let templateId: UUID?
    /// True when the linked series is live (template exists and not ended).
    let isRecurring: Bool
    /// What happens once every seat is taken.
    let capacityPolicy: CapacityPolicy

    init(id: UUID, creatorId: UUID = UUID(), name: String, date: String, startDate: Date = Date(), endDate: Date? = nil, imageUrl: String? = nil, registrationLocked: Bool = false, totalPrice: Int = 0, pricePerPerson: Double = 0, maxParticipants: Int? = nil, location: String = "", latitude: Double? = nil, longitude: Double? = nil, templateId: UUID? = nil, isRecurring: Bool = false, capacityPolicy: CapacityPolicy = .waitlist) {
        self.id = id
        self.creatorId = creatorId
        self.name = name
        self.date = date
        self.startDate = startDate
        self.endDate = endDate
        self.imageUrl = imageUrl
        self.registrationLocked = registrationLocked
        self.totalPrice = totalPrice
        self.pricePerPerson = pricePerPerson
        self.maxParticipants = maxParticipants
        self.location = location
        self.latitude = latitude
        self.longitude = longitude
        self.templateId = templateId
        self.isRecurring = isRecurring
        self.capacityPolicy = capacityPolicy
    }
}

// MARK: - From API
extension EventData {
    /// Build EventData from EventRecord (e.g. for list and navigation).
    static func from(record: EventRecord) -> EventData {
        EventData(
            id: record.id,
            creatorId: record.creatorId,
            name: record.name,
            date: EventData.formatEventDate(record.startDate, endDate: record.endDate),
            startDate: record.startDate,
            endDate: record.endDate,
            imageUrl: record.imageUrl,
            registrationLocked: record.registrationLocked ?? false,
            totalPrice: record.totalPrice ?? 0,
            pricePerPerson: record.pricePerPerson ?? 0,
            maxParticipants: record.maxParticipants,
            location: record.location,
            latitude: record.latitude,
            longitude: record.longitude,
            templateId: record.templateId,
            isRecurring: record.isRecurring ?? false,
            // A server without the column is one that predates the choice
            // being storable, and back then every event queued.
            capacityPolicy: record.capacityPolicy ?? .waitlist
        )
    }

    private static let eventDateFormatter: DateFormatter = {
        let f = DateFormatter()
        // Gregorian calendar, Arabic display (not Hijri).
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = .tamrin
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func formatEventDate(_ start: Date, endDate: Date?) -> String {
        eventDateFormatter.string(from: start)
    }

    /// Known asset names stored in image_url (no upload). Used for create + display.
    static func imageResource(for imageUrl: String?) -> ImageResource? {
        guard let s = imageUrl else { return nil }
        switch s {
        case "card1": return .card1
        case "card2": return .card2
        case "card3": return .card3
        case "card4": return .card4
        default: return nil
        }
    }
}

