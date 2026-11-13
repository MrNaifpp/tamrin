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
    /// As the server stores them: `goalkeeper`, `defender`, … Read through
    /// `appPositions`, which speaks the app's Arabic values.
    let positions: [String: String]

    var isPublished: Bool { status == "published" }

    var appPositions: [String: String] { positions.mapValues(PlayerPosition.fromLineupKey) }

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
            // The app keeps positions in Arabic; the lineup table takes the
            // English keys. Sending Arabic made every save with a position
            // override fail, silently.
            "p_positions": .object(positions.mapValues { AnyJSON.string(PlayerPosition.lineupKey(for: $0)) })
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

extension PlayerPosition {
    /// The key `save_event_lineup` accepts for a football position.
    static func lineupKey(for raw: String) -> String {
        switch PlayerPosition(rawValue: raw) {
        case .goalkeeper: "goalkeeper"
        case .defender: "defender"
        case .forward: "forward"
        default: "midfielder"
        }
    }

    static func fromLineupKey(_ key: String) -> String {
        switch key {
        case "goalkeeper": PlayerPosition.goalkeeper.rawValue
        case "defender": PlayerPosition.defender.rawValue
        case "forward": PlayerPosition.forward.rawValue
        case "midfielder": PlayerPosition.midfielder.rawValue
        // A value saved before the keys were mapped is already Arabic.
        default: key
        }
    }
}
