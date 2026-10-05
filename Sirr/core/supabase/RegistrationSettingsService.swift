//
//  RegistrationSettingsService.swift
//  Sirr
//
//  The organizer's registration settings and the manual-approval requests
//  behind them. See supabase/migrations/20261002100000_registration_settings.sql.
//

import Foundation
import Supabase

private struct RegistrationRequestRecord: Decodable {
    let id: UUID
    let userId: UUID?
    let requestedBy: UUID
    let displayName: String?
    let requesterName: String?
    let avatarUrl: String?
    let playerPosition: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case requestedBy = "requested_by"
        case displayName = "display_name"
        case requesterName = "requester_name"
        case avatarUrl = "avatar_url"
        case playerPosition = "player_position"
    }
}

enum RegistrationRequestResponse: String {
    case accepted
    case declined
    case seatsFull = "seats_full"
    case notFound = "not_found"
    case cancelled
}

@MainActor
final class RegistrationSettingsService {
    static let shared = RegistrationSettingsService()
    private var client: SupabaseClient { SupabaseClientManager.shared.client }

    /// Returns the exercise as saved, so the page redraws from the server's
    /// own reading of the rule.
    func update(eventID: UUID, settings: RegistrationSettings) async throws -> EventRecord {
        let params: [String: AnyJSON] = [
            "p_event_id": .string(eventID.uuidString),
            "p_open_days_before": settings.opening.map { .integer($0.daysBefore) } ?? .null,
            "p_open_minute": settings.opening.map { .integer($0.minuteOfDay) } ?? .null,
            "p_approval_mode": .string(settings.approvalMode.rawValue),
            "p_guests_allowed": .bool(settings.guestsAllowed)
        ]
        let response = try await client
            .rpc("update_event_registration_settings", params: params)
            .execute()
        return try EventService.makePostgresDecoder().decode(EventRecord.self, from: response.data)
    }

    func openNow(eventID: UUID) async throws -> EventRecord {
        let response = try await client
            .rpc("open_event_registration_now", params: ["p_event_id": AnyJSON.string(eventID.uuidString)])
            .execute()
        return try EventService.makePostgresDecoder().decode(EventRecord.self, from: response.data)
    }

    func requests(eventID: UUID) async throws -> [FeedRegistrationRequest] {
        let response = try await client
            .rpc("get_event_registration_requests", params: ["p_event_id": AnyJSON.string(eventID.uuidString)])
            .execute()
        return try JSONDecoder().decode([RegistrationRequestRecord].self, from: response.data).map {
            FeedRegistrationRequest(
                id: $0.id,
                userId: $0.userId,
                requestedBy: $0.requestedBy,
                name: $0.displayName ?? String(localized: "عضو"),
                requesterName: $0.requesterName ?? "",
                avatarUrl: $0.avatarUrl,
                position: $0.playerPosition ?? ""
            )
        }
    }

    func myRequest(eventID: UUID) async throws -> MyRegistrationRequestStatus? {
        let response = try await client
            .rpc("get_my_registration_request", params: ["p_event_id": AnyJSON.string(eventID.uuidString)])
            .execute()
        let payload = try? JSONSerialization.jsonObject(with: response.data, options: .fragmentsAllowed)
        guard let status = (payload as? [String: Any])?["status"] as? String else { return nil }
        return MyRegistrationRequestStatus(rawValue: status)
    }

    func respond(requestID: UUID, accept: Bool) async throws -> RegistrationRequestResponse {
        let params: [String: AnyJSON] = [
            "p_request_id": .string(requestID.uuidString),
            "p_accept": .bool(accept)
        ]
        let response = try await client
            .rpc("respond_registration_request", params: params)
            .execute()
        let status = (try? JSONSerialization.jsonObject(with: response.data) as? [String: Any])?["status"] as? String
        return status.flatMap(RegistrationRequestResponse.init(rawValue:)) ?? .notFound
    }

    func withdraw(eventID: UUID) async throws {
        try await client
            .rpc("withdraw_registration_request", params: ["p_event_id": AnyJSON.string(eventID.uuidString)])
            .execute()
    }
}
