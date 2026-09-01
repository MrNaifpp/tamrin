//
//  LineupService.swift
//  Sirr
//
//  The split, read and written where the whole group can see it.
//
//  The three calls mirror the three functions LineupStore used to answer from
//  UserDefaults, so the views above them did not have to learn anything new.
//

import Foundation
import Supabase

struct LineupRecord: Decodable {
    let status: String
    let publishedAt: Date?
    let first: [UUID]
    let second: [UUID]
    let positions: [String: String]

    var isPublished: Bool { status == "published" }

    enum CodingKeys: String, CodingKey {
        case status, first, second, positions
        case publishedAt = "published_at"
    }
}

@MainActor
final class LineupService {
    static let shared = LineupService()
    private var client: SupabaseClient { SupabaseClientManager.shared.client }

    /// Nil when there is no lineup, and also when there is one the caller may
    /// not see yet. The RPC draws that line, not the app: a draft belongs to
    /// the organizer until he publishes it.
    func get(eventID: UUID) async throws -> LineupRecord? {
        let response = try await client
            .rpc("get_event_lineup", params: ["p_event_id": AnyJSON.string(eventID.uuidString)])
            .execute()
        return try? EventService.makePostgresDecoder().decode(LineupRecord.self, from: response.data)
    }

    @discardableResult
    func save(
        eventID: UUID,
        first: [UUID],
        second: [UUID],
        positions: [String: String]
    ) async throws -> LineupRecord {
        let params: [String: AnyJSON] = [
            "p_event_id": .string(eventID.uuidString),
            "p_first": .array(first.map { .string($0.uuidString) }),
            "p_second": .array(second.map { .string($0.uuidString) }),
            "p_positions": .object(positions.mapValues { AnyJSON.string($0) })
        ]
        let response = try await client
            .rpc("save_event_lineup", params: params)
            .execute()
        return try EventService.makePostgresDecoder().decode(LineupRecord.self, from: response.data)
    }

    @discardableResult
    func publish(eventID: UUID) async throws -> LineupRecord {
        let response = try await client
            .rpc("publish_event_lineup", params: ["p_event_id": AnyJSON.string(eventID.uuidString)])
            .execute()
        return try EventService.makePostgresDecoder().decode(LineupRecord.self, from: response.data)
    }
}
