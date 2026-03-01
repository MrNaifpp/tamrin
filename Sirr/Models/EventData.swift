import SwiftUI

struct EventData: Identifiable, Hashable {
    let id: UUID
    let creatorId: UUID
    let name: String
    let date: String
    /// When nil, UI uses a default placeholder image (e.g. card1).
    let imageUrl: String?
    let registrationLocked: Bool
    let totalPrice: Int
    let pricePerPerson: Double
    let maxParticipants: Int?

    init(id: UUID, creatorId: UUID = UUID(), name: String, date: String, imageUrl: String? = nil, registrationLocked: Bool = false, totalPrice: Int = 0, pricePerPerson: Double = 0, maxParticipants: Int? = nil) {
        self.id = id
        self.creatorId = creatorId
        self.name = name
        self.date = date
        self.imageUrl = imageUrl
        self.registrationLocked = registrationLocked
        self.totalPrice = totalPrice
        self.pricePerPerson = pricePerPerson
        self.maxParticipants = maxParticipants
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
            imageUrl: record.imageUrl,
            registrationLocked: record.registrationLocked ?? false,
            totalPrice: record.totalPrice ?? 0,
            pricePerPerson: record.pricePerPerson ?? 0,
            maxParticipants: record.maxParticipants
        )
    }

    private static let eventDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar_SA")
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

