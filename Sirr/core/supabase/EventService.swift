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
    let createdAt: Date?

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
        case createdAt = "created_at"
    }
}


/// Row from get_event_participants RPC.
struct ParticipantRecord: Codable, Identifiable {
    let userId: UUID
    let joinedAt: String?
    let displayName: String?
    let avatarUrl: String?

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case joinedAt = "joined_at"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
    }
}

final class EventService {
    static let shared = EventService()
    private let client = SupabaseClientManager.shared.client

    /// Fetch events where the current user is creator or participant. Ordered by start_date ascending.
    func getEventsForCurrentUser() async throws -> [EventRecord] {
        let session = try await client.auth.session
        let userId = session.user.id

        // Events created by user
        let created: [EventRecord] = try await client
            .from("events")
            .select()
            .eq("creator_id", value: userId)
            .order("start_date", ascending: true)
            .execute()
            .value

        // Event IDs where user is participant (not creator)
        struct ParticipantRow: Decodable {
            let eventId: UUID
            enum CodingKeys: String, CodingKey { case eventId = "event_id" }
        }
        let participantRows: [ParticipantRow] = try await client
            .from("event_participants")
            .select("event_id")
            .eq("user_id", value: userId)
            .execute()
            .value
        let participantEventIds = Set(participantRows.map(\.eventId))
        let createdIds = Set(created.map(\.id))
        let otherIds = participantEventIds.subtracting(createdIds)

        if otherIds.isEmpty {
            eventLogger.info("API getEventsForCurrentUser succeeded (count: \(created.count))")
            return created
        }

        // Events where user participates but did not create (fetch by ids)
        let others: [EventRecord] = try await client
            .from("events")
            .select()
            .in("id", values: Array(otherIds))
            .order("start_date", ascending: true)
            .execute()
            .value

        var combined = created + others
        combined.sort { $0.startDate < $1.startDate }
        eventLogger.info("API getEventsForCurrentUser succeeded (count: \(combined.count))")
        return combined
    }

    /// Create a new event and add the current user as first participant.
    /// Uses a server-side RPC (SECURITY DEFINER) to bypass RLS for inserts.
    func createEvent(
        name: String,
        location: String,
        description: String,
        startDate: Date,
        endDate: Date?,
        imageUrl: String?,
        maxParticipants: Int?,
        totalPrice: Int = 0,
        pricePerPerson: Double = 0
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
        var params: [String: String] = [
            "p_creator_id": userId.uuidString,
            "p_name": name,
            "p_location": location,
            "p_description": description,
            "p_start_date": iso.string(from: startDate)
        ]
        if let endDate { params["p_end_date"] = iso.string(from: endDate) }
        if let imageUrl { params["p_image_url"] = imageUrl }
        if let maxParticipants { params["p_max_participants"] = "\(maxParticipants)" }
        if totalPrice > 0 { params["p_total_price"] = "\(totalPrice)" }
        if pricePerPerson > 0 { params["p_price_per_person"] = "\(pricePerPerson)" }

        let response = try await client
            .rpc("create_event", params: params)
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

        eventLogger.info("API createEvent succeeded (id: \(event.id))")
        return event
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
        return participants.contains { $0.userId == userId }
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
}
