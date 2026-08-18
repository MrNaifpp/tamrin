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
    /// Explicit organizer invitation state. Nil means the exercise is still a
    /// draft visible only to its creator.
    let publishedAt: Date?
    /// A cancelled occurrence remains visible so members can read its reason.
    let cancelledAt: Date?
    let cancellationReasonCode: String?
    let cancellationReasonText: String?
    /// Set when the organizer has explicitly asked the registered players to
    /// pay their share. Members use it to keep the payment destination
    /// reachable after dismissing the reminder or payment sheet.
    let paymentReminderSentAt: Date?
    /// Current authenticated member's private response, computed by the list
    /// RPC. Organizers do not receive other members' reasons here.
    let myResponseStatus: String?

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
        case publishedAt = "published_at"
        case cancelledAt = "cancelled_at"
        case cancellationReasonCode = "cancellation_reason_code"
        case cancellationReasonText = "cancellation_reason_text"
        case paymentReminderSentAt = "payment_reminder_sent_at"
        case myResponseStatus = "my_response_status"
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
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        cancelledAt = try container.decodeIfPresent(Date.self, forKey: .cancelledAt)
        cancellationReasonCode = try container.decodeIfPresent(String.self, forKey: .cancellationReasonCode)
        cancellationReasonText = try container.decodeIfPresent(String.self, forKey: .cancellationReasonText)
        paymentReminderSentAt = try container.decodeIfPresent(Date.self, forKey: .paymentReminderSentAt)
        myResponseStatus = try container.decodeIfPresent(String.self, forKey: .myResponseStatus)
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
    /// Nil on a server that predates manual registration.
    let addedManually: Bool?
    /// Only the organizer receives this; it is what the payment-reminder
    /// cooldown is measured from. Nil on a server that predates reminders.
    let paymentReminderSentAt: String?

    var id: UUID { participantId }

    /// True if this row is a guest (no account) added by a paying joiner.
    var isGuest: Bool { userId == nil }

    /// True if the organizer seated this person by name rather than the person
    /// registering themselves. Only these rows are removable by the organizer.
    var isManual: Bool { addedManually == true }

    /// Postgres timestamps arrive as strings; the roster decoder keeps them raw
    /// so these fields can stay optional without a custom init.
    static func timestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ", "yyyy-MM-dd'T'HH:mm:ssZZZZZ"] {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    var joinedAtDate: Date? { Self.timestamp(joinedAt) }

    var paymentReminderSentAtDate: Date? { Self.timestamp(paymentReminderSentAt) }

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
        case addedManually = "added_manually"
        case paymentReminderSentAt = "payment_reminder_sent_at"
    }
}

/// Result of `add_manual_participant`. The RPC reports refusals as a status
/// string so the organizer gets a specific reason instead of a thrown error.
enum AddManualParticipantResult {
    case added(participantId: UUID, name: String)
    /// The seat cap is already reached (pending seats included).
    case seatsFull
    /// Someone with that exact name was already registered manually here.
    case duplicateName
    /// The organizer locked registration.
    case registrationClosed
    /// The exercise has not been sent to the group yet.
    case notPublished
    /// The occurrence was skipped.
    case cancelled
    /// The name was blank once trimmed.
    case emptyName
}

/// Result of `remove_event_participant`.
enum RemoveParticipantResult {
    case removed
    /// The organizer's own seat, which this operation refuses to free.
    case isCreator
    /// Already gone — someone else removed it, or the roster was stale.
    case notFound
}

/// Result of `remind_participant_payment`. The server owns the cooldown, so
/// every outcome carries whatever the organizer needs to be told.
enum PaymentReminderResult {
    /// Sent, and the next one may go out at this time.
    case sent(nextAllowedAt: Date)
    /// One went out recently; this is when the next is allowed.
    case tooSoon(nextAllowedAt: Date)
    /// A guest or a manually seated player: no account, so no device to reach.
    case noAccount
    /// The organizer's own seat.
    case isSelf
    /// The seat is gone, or the occurrence was skipped.
    case notFound
    case cancelled
}

/// What a group-wide reminder is about.
enum MemberReminderKind: String {
    /// Members who have not taken a seat yet.
    case register
    /// Everyone already on the list.
    case payment
}

/// Result of `remind_event_members`.
enum MemberReminderResult {
    case sent(recipients: Int, nextAllowedAt: Date)
    case tooSoon(nextAllowedAt: Date)
    /// Everyone is already registered, or nobody is on the list yet.
    case noRecipients
    case notPublished
    case cancelled
}

/// A member invitation response returned by `get_event_member_responses`.
/// The RPC only exposes the full list to the event organizer; regular members
/// receive their own row server-side.
struct EventMemberResponseRecord: Codable, Identifiable {
    let userId: UUID
    let displayName: String
    let avatarUrl: String?
    let status: String
    let reasonCode: String?
    let reasonText: String?
    let invitedBy: UUID?
    let invitedAt: Date?
    let respondedAt: Date?
    let updatedAt: Date?

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case status
        case reasonCode = "reason_code"
        case reasonText = "reason_text"
        case invitedBy = "invited_by"
        case invitedAt = "invited_at"
        case respondedAt = "responded_at"
        case updatedAt = "updated_at"
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

    /// Atomically updates one occurrence and, when requested, its active weekly
    /// template. The database owns authorization, price calculation, and the
    /// transaction so a partial series edit can never escape to the client.
    func updateEventWithScope(
        eventId: UUID,
        scope: String,
        name: String,
        location: String,
        startDate: Date,
        endDate: Date?,
        maxParticipants: Int?,
        totalPrice: Int,
        latitude: Double?,
        longitude: Double?,
        paymentMethodIds: [UUID]
    ) async throws {
        let iso = ISO8601DateFormatter()
        let params: [String: AnyJSON] = [
            "p_event_id": .string(eventId.uuidString),
            "p_scope": .string(scope),
            "p_name": .string(name),
            "p_location": .string(location),
            "p_start_date": .string(iso.string(from: startDate)),
            "p_end_date": endDate.map { .string(iso.string(from: $0)) } ?? .null,
            "p_max_participants": maxParticipants.map(AnyJSON.integer) ?? .null,
            "p_total_price": .integer(totalPrice),
            "p_latitude": latitude.map(AnyJSON.double) ?? .null,
            "p_longitude": longitude.map(AnyJSON.double) ?? .null,
            "p_payment_method_ids": .array(
                paymentMethodIds.map { .string($0.uuidString) }
            )
        ]

        do {
            try await client
                .rpc("update_event_with_scope", params: params)
                .execute()
        } catch {
            throw Self.translatedPaymentSchemaError(error)
        }
        eventLogger.info("API updateEventWithScope succeeded (id: \(eventId), scope: \(scope))")
    }

    private static func translatedPaymentSchemaError(_ error: Error) -> Error {
        let description = error.localizedDescription.lowercased()
        let postgrestCode = (error as? PostgrestError)?.code
        let isPaymentSchemaError = description.contains("payment_method")
            || description.contains("create_event")
            || description.contains("update_event_with_scope")
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

    /// Registers a person by name on behalf of the organizer. The seat is real:
    /// the server applies the same capacity and lifecycle rules a member's own
    /// registration goes through.
    func addManualParticipant(eventId: UUID, name: String) async throws -> AddManualParticipantResult {
        let params: [String: AnyJSON] = [
            "p_event_id": .string(eventId.uuidString),
            "p_name": .string(name)
        ]

        let response = try await client
            .rpc("add_manual_participant", params: params)
            .execute()

        guard
            let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
            let status = payload["status"] as? String
        else {
            throw NSError(
                domain: "EventService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة رد الخادم."]
            )
        }

        switch status {
        case "added":
            guard
                let idString = payload["participant_id"] as? String,
                let participantId = UUID(uuidString: idString)
            else {
                throw NSError(
                    domain: "EventService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة رد الخادم."]
                )
            }
            let storedName = (payload["name"] as? String) ?? name
            eventLogger.info("API addManualParticipant succeeded (eventId: \(eventId))")
            return .added(participantId: participantId, name: storedName)
        case "seats_full": return .seatsFull
        case "duplicate_name": return .duplicateName
        case "registration_closed": return .registrationClosed
        case "not_published": return .notPublished
        case "cancelled": return .cancelled
        case "empty_name": return .emptyName
        default:
            throw NSError(
                domain: "EventService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "رد غير متوقع من الخادم: \(status)"]
            )
        }
    }

    /// Nudges one player to pay their share. The RPC owns the one-hour
    /// cooldown and reports a refusal as a status rather than an error.
    func remindParticipantPayment(
        eventId: UUID,
        participantId: UUID
    ) async throws -> PaymentReminderResult {
        let params: [String: String] = [
            "p_event_id": eventId.uuidString,
            "p_participant_id": participantId.uuidString
        ]

        let response = try await client
            .rpc("remind_participant_payment", params: params)
            .execute()

        guard
            let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
            let status = payload["status"] as? String
        else {
            throw NSError(
                domain: "EventService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة رد الخادم."]
            )
        }

        // Falls back to a locally computed hour so a server that returns an
        // unparseable timestamp still leaves the button disabled.
        let nextAllowed = ParticipantRecord.timestamp(payload["next_allowed_at"] as? String)
            ?? Date().addingTimeInterval(3600)

        switch status {
        case "sent":
            eventLogger.info("API remindParticipantPayment sent (eventId: \(eventId))")
            return .sent(nextAllowedAt: nextAllowed)
        case "too_soon": return .tooSoon(nextAllowedAt: nextAllowed)
        case "no_account": return .noAccount
        case "is_self": return .isSelf
        case "not_found": return .notFound
        case "cancelled": return .cancelled
        default:
            throw NSError(
                domain: "EventService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "رد غير متوقع من الخادم: \(status)"]
            )
        }
    }

    /// Sends one reminder push to every member the kind applies to. The RPC
    /// picks the recipients and owns the one-hour cooldown.
    func remindEventMembers(
        eventId: UUID,
        kind: MemberReminderKind
    ) async throws -> MemberReminderResult {
        let params: [String: String] = [
            "p_event_id": eventId.uuidString,
            "p_kind": kind.rawValue
        ]

        let response = try await client
            .rpc("remind_event_members", params: params)
            .execute()

        guard
            let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
            let status = payload["status"] as? String
        else {
            throw NSError(
                domain: "EventService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة رد الخادم."]
            )
        }

        let nextAllowed = ParticipantRecord.timestamp(payload["next_allowed_at"] as? String)
            ?? Date().addingTimeInterval(3600)

        switch status {
        case "sent":
            let recipients = (payload["recipients"] as? Int) ?? 0
            eventLogger.info("API remindEventMembers sent (eventId: \(eventId), kind: \(kind.rawValue))")
            return .sent(recipients: recipients, nextAllowedAt: nextAllowed)
        case "too_soon": return .tooSoon(nextAllowedAt: nextAllowed)
        case "no_recipients": return .noRecipients
        case "not_published": return .notPublished
        case "cancelled": return .cancelled
        default:
            throw NSError(
                domain: "EventService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "رد غير متوقع من الخادم: \(status)"]
            )
        }
    }

    /// Frees a manually registered seat. Rows belonging to real accounts, and
    /// the guests a member paid for, are rejected server-side.
    func removeManualParticipant(participantId: UUID) async throws {
        let params: [String: String] = ["p_participant_id": participantId.uuidString]

        try await client
            .rpc("remove_manual_participant", params: params)
            .execute()

        eventLogger.info("API removeManualParticipant succeeded (participantId: \(participantId))")
    }

    /// Organizer removes anyone from one exercise. Removing a member takes the
    /// guests they paid for with them; the organizer's own seat is refused.
    func removeParticipant(participantId: UUID) async throws -> RemoveParticipantResult {
        let params: [String: String] = ["p_participant_id": participantId.uuidString]

        let response = try await client
            .rpc("remove_event_participant", params: params)
            .execute()

        guard
            let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
            let status = payload["status"] as? String
        else {
            throw NSError(
                domain: "EventService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة رد الخادم."]
            )
        }

        eventLogger.info("API removeParticipant: \(status)")
        switch status {
        case "removed": return .removed
        case "is_creator": return .isCreator
        case "not_found": return .notFound
        default:
            throw NSError(
                domain: "EventService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "رد غير متوقع من الخادم: \(status)"]
            )
        }
    }

    /// Fetches invitation responses for an event. The server limits organizers
    /// to their own events and regular members to their own response.
    func getEventMemberResponses(eventId: UUID) async throws -> [EventMemberResponseRecord] {
        let params: [String: String] = ["p_event_id": eventId.uuidString]

        let response = try await client
            .rpc("get_event_member_responses", params: params)
            .execute()

        let records = try Self.makePostgresDecoder().decode(
            [EventMemberResponseRecord].self,
            from: response.data
        )
        eventLogger.info("API getEventMemberResponses succeeded (eventId: \(eventId), count: \(records.count))")
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

    /// Publishes an organizer-owned event and invites all current workspace
    /// members. The RPC is idempotent and owns notification deduplication.
    func publishEvent(eventId: UUID) async throws {
        let params: [String: String] = ["p_event_id": eventId.uuidString]
        try await client
            .rpc("publish_event", params: params)
            .execute()
        eventLogger.info("API publishEvent succeeded (eventId: \(eventId))")
    }

    /// Declines an invitation with an optional structured reason. This server
    /// operation also releases any current registration or waitlist entry.
    func declineEvent(
        eventId: UUID,
        reasonCode: String?,
        reasonText: String?
    ) async throws {
        let params: [String: AnyJSON] = [
            "p_event_id": .string(eventId.uuidString),
            "p_reason_code": reasonCode.map(AnyJSON.string) ?? .null,
            "p_reason_text": reasonText.map(AnyJSON.string) ?? .null
        ]
        try await client
            .rpc("decline_event", params: params)
            .execute()
        eventLogger.info("API declineEvent succeeded (eventId: \(eventId))")
    }

    /// Cancels only this concrete occurrence, preserving its weekly template.
    /// The event remains queryable and the RPC notifies workspace members.
    func cancelEventOccurrence(
        eventId: UUID,
        reasonCode: String?,
        reasonText: String?
    ) async throws {
        let params: [String: AnyJSON] = [
            "p_event_id": .string(eventId.uuidString),
            "p_reason_code": reasonCode.map(AnyJSON.string) ?? .null,
            "p_reason_text": reasonText.map(AnyJSON.string) ?? .null
        ]
        try await client
            .rpc("cancel_event_occurrence", params: params)
            .execute()
        eventLogger.info("API cancelEventOccurrence succeeded (eventId: \(eventId))")
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
