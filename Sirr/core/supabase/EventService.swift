//
//  EventService.swift
//  Sirr
//
//  Events and event_participants: create event, list events for current user.
//

import Supabase
import Foundation
import os

private let eventLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "EventService")

/// Row from public.events table.
struct EventRecord: Codable {
    let id: UUID
    let creatorId: UUID
    let name: String
    let location: String
    let description: String
    let startDate: Date
    let endDate: Date?
    let imageUrl: String?
    let maxParticipants: Int?
    let registrationLocked: Bool?
    let totalPrice: Int?
    let pricePerPerson: Double?
    let latitude: Double?
    let longitude: Double?
    let createdAt: Date?
    let workspaceId: UUID?
    let templateId: UUID?
    /// Organizer-selected reusable payment destination for this event.
    let paymentMethodId: UUID?
    /// All organizer-selected destinations, in the order shown to players.
    /// The scalar field above remains as a compatibility alias for the first.
    let paymentMethodIds: [UUID]
    /// Computed by get_workspace_events: template linked AND not ended.
    let isRecurring: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case creatorId = "creator_id"
        case name
        case location
        case description
        case startDate = "start_date"
        case endDate = "end_date"
        case imageUrl = "image_url"
        case maxParticipants = "max_participants"
        case registrationLocked = "registration_locked"
        case totalPrice = "total_price"
        case pricePerPerson = "price_per_person"
        case latitude
        case longitude
        case createdAt = "created_at"
        case workspaceId = "workspace_id"
        case templateId = "template_id"
        case paymentMethodId = "payment_method_id"
        case paymentMethodIds = "payment_method_ids"
        case isRecurring = "is_recurring"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        creatorId = try container.decode(UUID.self, forKey: .creatorId)
        name = try container.decode(String.self, forKey: .name)
        location = try container.decode(String.self, forKey: .location)
        description = try container.decode(String.self, forKey: .description)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
        maxParticipants = try container.decodeIfPresent(Int.self, forKey: .maxParticipants)
        registrationLocked = try container.decodeIfPresent(Bool.self, forKey: .registrationLocked)
        totalPrice = try container.decodeIfPresent(Int.self, forKey: .totalPrice)
        pricePerPerson = try container.decodeIfPresent(Double.self, forKey: .pricePerPerson)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        workspaceId = try container.decodeIfPresent(UUID.self, forKey: .workspaceId)
        templateId = try container.decodeIfPresent(UUID.self, forKey: .templateId)
        paymentMethodId = try container.decodeIfPresent(UUID.self, forKey: .paymentMethodId)
        paymentMethodIds = try container.decodeIfPresent([UUID].self, forKey: .paymentMethodIds)
            ?? paymentMethodId.map { [$0] }
            ?? []
        isRecurring = try container.decodeIfPresent(Bool.self, forKey: .isRecurring)
    }
}

/// A distinct location the current user has used before (name + coordinates), for quick re-selection.
struct SavedLocation: Identifiable, Hashable {
    let name: String
    let latitude: Double
    let longitude: Double
    var id: String { "\(name)|\(latitude)|\(longitude)" }
}


/// Row from get_event_participants RPC.
struct ParticipantRecord: Codable, Identifiable {
    let participantId: UUID
    let userId: UUID?
    let joinedAt: String?
    let displayName: String?
    let avatarUrl: String?
    let paymentStatus: PaymentStatus?
    let paidToNumber: String?
    let guestName: String?
    let addedBy: UUID?

    var id: UUID { participantId }

    /// True if this row is a guest (no account) added by a paying joiner.
    var isGuest: Bool { userId == nil }

    /// True if the row represents a confirmed seat.
    var isConfirmed: Bool { (paymentStatus ?? .confirmed) == .confirmed }

    /// True if the row is awaiting creator confirmation.
    var isPending: Bool { paymentStatus == .pending }

    enum CodingKeys: String, CodingKey {
        case participantId = "participant_id"
        case userId = "user_id"
        case joinedAt = "joined_at"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case paymentStatus = "payment_status"
        case paidToNumber = "paid_to_number"
        case guestName = "guest_name"
        case addedBy = "added_by"
    }
}

/// Row from public.event_templates (via get_event_template RPC).
struct EventTemplateRecord: Codable {
    let id: UUID
    let workspaceId: UUID
    let creatorId: UUID
    let recurrence: String
    let nextOccurrenceAt: Date
    let skipNext: Bool
    let endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceId = "workspace_id"
        case creatorId = "creator_id"
        case recurrence
        case nextOccurrenceAt = "next_occurrence_at"
        case skipNext = "skip_next"
        case endedAt = "ended_at"
    }
}

/// Result of skip_next_occurrence: skipped now, or the next occurrence was
/// already generated (the creator deletes that event instead).
enum SkipNextResult {
    case skipped(Date?)
    case alreadyOpen(UUID?)
}

final class EventService {
    static let shared = EventService()
    private let client = SupabaseClientManager.shared.client

    /// Decoder handling Postgres timestamp formats (same strategy the RPC
    /// decoders in this file use inline).
    private static func makePostgresDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let d = ISO8601DateFormatter().date(from: str) { return d }
            let pg = DateFormatter()
            pg.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"
            pg.locale = Locale(identifier: "en_US_POSIX")
            if let d = pg.date(from: str) { return d }
            let pg2 = DateFormatter()
            pg2.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            pg2.locale = Locale(identifier: "en_US_POSIX")
            if let d = pg2.date(from: str) { return d }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(str)")
        }
        return decoder
    }

    /// Upcoming events of one workspace (member-gated server-side).
    /// Ordered by start_date ascending.
    func getWorkspaceEvents(workspaceId: UUID) async throws -> [EventRecord] {
        let params: [String: String] = ["p_workspace_id": workspaceId.uuidString]
        let response = try await client
            .rpc("get_workspace_events", params: params)
            .execute()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let d = ISO8601DateFormatter().date(from: str) { return d }
            let pg = DateFormatter()
            pg.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"
            pg.locale = Locale(identifier: "en_US_POSIX")
            if let d = pg.date(from: str) { return d }
            let pg2 = DateFormatter()
            pg2.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            pg2.locale = Locale(identifier: "en_US_POSIX")
            if let d = pg2.date(from: str) { return d }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(str)")
        }
        let events = try decoder.decode([EventRecord].self, from: response.data)
        eventLogger.info("API getWorkspaceEvents succeeded (count: \(events.count))")
        return events
    }

    /// Create a new event and add the current user as first participant.
    /// Uses a server-side RPC (SECURITY DEFINER) to bypass RLS for inserts.
    func createEvent(
        workspaceId: UUID,
        name: String,
        location: String,
        description: String,
        startDate: Date,
        endDate: Date?,
        imageUrl: String?,
        maxParticipants: Int?,
        totalPrice: Int = 0,
        pricePerPerson: Double = 0,
        latitude: Double? = nil,
        longitude: Double? = nil,
        recurrence: String = "none",
        paymentMethodId: UUID? = nil,
        paymentMethodIds: [UUID] = []
    ) async throws -> EventRecord {
        let session: Session
        do {
            session = try await client.auth.session
        } catch {
            eventLogger.error("API createEvent: no session — \(error.localizedDescription)")
            throw NSError(domain: "EventService", code: -2, userInfo: [NSLocalizedDescriptionKey: "يجب تسجيل الدخول أولاً"])
        }
        let userId = session.user.id

        let iso = ISO8601DateFormatter()
        let selectedPaymentMethodIds = paymentMethodIds.isEmpty
            ? paymentMethodId.map { [$0] } ?? []
            : paymentMethodIds
        var params: [String: AnyJSON] = [
            "p_creator_id": .string(userId.uuidString),
            "p_workspace_id": .string(workspaceId.uuidString),
            "p_name": .string(name),
            "p_location": .string(location),
            "p_description": .string(description),
            "p_start_date": .string(iso.string(from: startDate)),
            "p_total_price": .integer(totalPrice),
            "p_price_per_person": .double(pricePerPerson),
            "p_recurrence": .string(recurrence),
            "p_payment_method_id": selectedPaymentMethodIds.first.map {
                .string($0.uuidString)
            } ?? .null,
            "p_payment_method_ids": .array(
                selectedPaymentMethodIds.map { .string($0.uuidString) }
            )
        ]
        if let endDate { params["p_end_date"] = .string(iso.string(from: endDate)) }
        if let imageUrl { params["p_image_url"] = .string(imageUrl) }
        if let maxParticipants { params["p_max_participants"] = .integer(maxParticipants) }
        if let latitude { params["p_latitude"] = .double(latitude) }
        if let longitude { params["p_longitude"] = .double(longitude) }

        let response: PostgrestResponse<Void>
        do {
            response = try await client
                .rpc("create_event", params: params)
                .execute()
        } catch {
            throw Self.translatedPaymentSchemaError(error)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let d = ISO8601DateFormatter().date(from: str) { return d }
            let pg = DateFormatter()
            pg.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"
            pg.locale = Locale(identifier: "en_US_POSIX")
            if let d = pg.date(from: str) { return d }
            let pg2 = DateFormatter()
            pg2.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            pg2.locale = Locale(identifier: "en_US_POSIX")
            if let d = pg2.date(from: str) { return d }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(str)")
        }
        let event = try decoder.decode(EventRecord.self, from: response.data)

        eventLogger.info("API createEvent succeeded (id: \(event.id))")
        return event
    }

    /// Editable event fields, updated via the events table directly — the
    /// baseline RLS policy ("Creators can update own events") gates it to the
    /// creator, so no RPC is needed.
    private struct UpdateEventPayload: Encodable {
        let name: String
        let location: String
        let startDate: String
        let endDate: String?
        let maxParticipants: Int?
        let totalPrice: Int
        let pricePerPerson: Double
        let latitude: Double?
        let longitude: Double?
        let paymentMethodId: UUID?
        let paymentMethodIds: [UUID]

        enum CodingKeys: String, CodingKey {
            case name, location, latitude, longitude
            case startDate = "start_date"
            case endDate = "end_date"
            case maxParticipants = "max_participants"
            case totalPrice = "total_price"
            case pricePerPerson = "price_per_person"
            case paymentMethodId = "payment_method_id"
            case paymentMethodIds = "payment_method_ids"
        }
    }

    /// Update an existing event's editable fields (creator-only via RLS; a
    /// non-creator's update simply matches zero rows).
    func updateEvent(
        eventId: UUID,
        name: String,
        location: String,
        startDate: Date,
        endDate: Date?,
        maxParticipants: Int?,
        totalPrice: Int,
        pricePerPerson: Double,
        latitude: Double?,
        longitude: Double?,
        paymentMethodId: UUID? = nil,
        paymentMethodIds: [UUID] = []
    ) async throws {
        let iso = ISO8601DateFormatter()
        let selectedPaymentMethodIds = paymentMethodIds.isEmpty
            ? paymentMethodId.map { [$0] } ?? []
            : paymentMethodIds
        let payload = UpdateEventPayload(
            name: name,
            location: location,
            startDate: iso.string(from: startDate),
            endDate: endDate.map { iso.string(from: $0) },
            maxParticipants: maxParticipants,
            totalPrice: totalPrice,
            pricePerPerson: pricePerPerson,
            latitude: latitude,
            longitude: longitude,
            paymentMethodId: selectedPaymentMethodIds.first,
            paymentMethodIds: selectedPaymentMethodIds
        )
        do {
            try await client
                .from("events")
                .update(payload)
                .eq("id", value: eventId.uuidString)
                .execute()
        } catch {
            throw Self.translatedPaymentSchemaError(error)
        }
        eventLogger.info("API updateEvent succeeded (id: \(eventId))")
    }

    private static func translatedPaymentSchemaError(_ error: Error) -> Error {
        let description = error.localizedDescription.lowercased()
        let postgrestCode = (error as? PostgrestError)?.code
        let isPaymentSchemaError = description.contains("payment_method")
            || description.contains("create_event")
        let isMissingSchemaEntry = postgrestCode == "PGRST202"
            || postgrestCode == "PGRST203"
            || postgrestCode == "PGRST204"
            || description.contains("schema cache")

        if isPaymentSchemaError && isMissingSchemaEntry {
            eventLogger.error(
                "Payment schema unavailable while saving an event (code: \(postgrestCode ?? "unknown", privacy: .public))"
            )
            return ManualPaymentServiceError.featureUnavailable
        }
        return error
    }

    /// Detaches an event from its series template (creator-only via the same
    /// RLS policy). Used before enable_recurrence to force a fresh template
    /// snapshot from the updated event — reactivation alone never re-snapshots.
    func clearTemplateLink(eventId: UUID) async throws {
        try await client
            .from("events")
            .update(["template_id": AnyJSON.null])
            .eq("id", value: eventId.uuidString)
            .execute()
        eventLogger.info("API clearTemplateLink succeeded (id: \(eventId))")
    }

    /// Distinct locations (name + coordinates) the current user has used in their own events.
    /// Used to let creators quick-pick a previously-entered place. Only rows with coordinates are returned.
    func getPreviousLocations() async throws -> [SavedLocation] {
        let session = try await client.auth.session
        let userId = session.user.id

        struct LocationRow: Decodable {
            let location: String
            let latitude: Double?
            let longitude: Double?
        }
        let rows: [LocationRow] = try await client
            .from("events")
            .select("location, latitude, longitude")
            .eq("creator_id", value: userId)
            .order("created_at", ascending: false)
            .execute()
            .value

        var seen = Set<String>()
        var result: [SavedLocation] = []
        for row in rows {
            let name = row.location.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let lat = row.latitude, let lon = row.longitude else { continue }
            let key = name.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(SavedLocation(name: name, latitude: lat, longitude: lon))
        }
        eventLogger.info("API getPreviousLocations succeeded (count: \(result.count))")
        return result
    }

    /// Fetch a single event by ID. Uses SECURITY DEFINER RPC so anyone with the link can view.
    func getEventById(_ id: UUID) async throws -> EventRecord {
        let params: [String: String] = ["p_event_id": id.uuidString]

        let response = try await client
            .rpc("get_event_by_id", params: params)
            .execute()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let d = ISO8601DateFormatter().date(from: str) { return d }
            let pg = DateFormatter()
            pg.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"
            pg.locale = Locale(identifier: "en_US_POSIX")
            if let d = pg.date(from: str) { return d }
            let pg2 = DateFormatter()
            pg2.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            pg2.locale = Locale(identifier: "en_US_POSIX")
            if let d = pg2.date(from: str) { return d }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(str)")
        }
        let event = try decoder.decode(EventRecord.self, from: response.data)
        eventLogger.info("API getEventById succeeded (id: \(event.id))")
        return event
    }

    /// Join an event as the current user. Checks registration_locked server-side.
    func joinEvent(eventId: UUID) async throws {
        let session = try await client.auth.session
        let userId = session.user.id

        let params: [String: String] = [
            "p_event_id": eventId.uuidString,
            "p_user_id": userId.uuidString
        ]

        try await client
            .rpc("join_event", params: params)
            .execute()

        eventLogger.info("API joinEvent succeeded (eventId: \(eventId))")
    }

    /// Fetch participants for an event.
    func getEventParticipants(eventId: UUID) async throws -> [ParticipantRecord] {
        let params: [String: String] = ["p_event_id": eventId.uuidString]

        let response = try await client
            .rpc("get_event_participants", params: params)
            .execute()

        let records = try JSONDecoder().decode([ParticipantRecord].self, from: response.data)
        eventLogger.info("API getEventParticipants succeeded (eventId: \(eventId), count: \(records.count))")
        return records
    }

    /// Check if the current user is enrolled in an event.
    func isCurrentUserEnrolled(eventId: UUID) async throws -> Bool {
        let session = try await client.auth.session
        let userId = session.user.id
        let participants = try await getEventParticipants(eventId: eventId)
        return participants.contains { $0.userId == userId && !$0.isGuest }
    }

    /// Leave an event as the current user.
    func leaveEvent(eventId: UUID) async throws {
        let session = try await client.auth.session
        let userId = session.user.id

        let params: [String: String] = [
            "p_event_id": eventId.uuidString,
            "p_user_id": userId.uuidString
        ]

        try await client
            .rpc("leave_event", params: params)
            .execute()

        eventLogger.info("API leaveEvent succeeded (eventId: \(eventId))")
    }

    /// Toggle registration lock for an event. Only the creator can call this.
    /// Returns the new `registration_locked` value.
    func toggleRegistrationLock(eventId: UUID) async throws -> Bool {
        let session = try await client.auth.session
        let userId = session.user.id

        let params: [String: String] = [
            "p_event_id": eventId.uuidString,
            "p_user_id": userId.uuidString
        ]

        let response = try await client
            .rpc("toggle_event_registration_lock", params: params)
            .execute()

        guard let newValue = try? JSONDecoder().decode(Bool.self, from: response.data) else {
            throw NSError(domain: "EventService", code: -1, userInfo: [NSLocalizedDescriptionKey: "فشل في تحديث حالة التسجيل"])
        }

        eventLogger.info("API toggleRegistrationLock succeeded (eventId: \(eventId), locked: \(newValue))")
        return newValue
    }

    /// Delete an event. Only the creator can call this (enforced server-side).
    /// Cascades remove event_participants & event_waitlist rows automatically.
    func deleteEvent(eventId: UUID) async throws {
        let session = try await client.auth.session
        let userId = session.user.id

        let params: [String: String] = [
            "p_event_id": eventId.uuidString,
            "p_user_id": userId.uuidString
        ]

        try await client
            .rpc("delete_event", params: params)
            .execute()

        eventLogger.info("API deleteEvent succeeded (eventId: \(eventId))")
    }

    /// Recurrence template backing a series-linked event.
    func getEventTemplate(templateId: UUID) async throws -> EventTemplateRecord {
        let params: [String: String] = ["p_template_id": templateId.uuidString]
        let response = try await client
            .rpc("get_event_template", params: params)
            .execute()
        let template = try Self.makePostgresDecoder().decode(EventTemplateRecord.self, from: response.data)
        eventLogger.info("API getEventTemplate succeeded (id: \(template.id))")
        return template
    }

    /// Skip the series' next occurrence. `fromEventId` is the event whose page
    /// hosted the button (the server excludes it when checking whether the
    /// next occurrence is already open).
    func skipNextOccurrence(templateId: UUID, fromEventId: UUID) async throws -> SkipNextResult {
        struct SkipResponse: Decodable {
            let status: String
            let skippedDate: Date?
            let eventId: UUID?
            enum CodingKeys: String, CodingKey {
                case status
                case skippedDate = "skipped_date"
                case eventId = "event_id"
            }
        }
        let params: [String: String] = [
            "p_template_id": templateId.uuidString,
            "p_event_id": fromEventId.uuidString
        ]
        let response = try await client
            .rpc("skip_next_occurrence", params: params)
            .execute()
        let result = try Self.makePostgresDecoder().decode(SkipResponse.self, from: response.data)
        eventLogger.info("API skipNextOccurrence: \(result.status)")
        return result.status == "already_open"
            ? .alreadyOpen(result.eventId)
            : .skipped(result.skippedDate)
    }

    /// Enable weekly recurrence on an existing event (from its settings sheet).
    /// Creates the template or reactivates an ended one; returns it.
    func enableRecurrence(eventId: UUID) async throws -> EventTemplateRecord {
        let params: [String: String] = ["p_event_id": eventId.uuidString]
        let response = try await client
            .rpc("enable_recurrence", params: params)
            .execute()
        let template = try Self.makePostgresDecoder().decode(EventTemplateRecord.self, from: response.data)
        eventLogger.info("API enableRecurrence succeeded (templateId: \(template.id))")
        return template
    }

    /// End the series. Existing events are untouched.
    func endRecurrence(templateId: UUID) async throws {
        let params: [String: String] = ["p_template_id": templateId.uuidString]
        try await client
            .rpc("end_recurrence", params: params)
            .execute()
        eventLogger.info("API endRecurrence succeeded (templateId: \(templateId))")
    }
}
