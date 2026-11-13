import Foundation
import Supabase

struct MatchAwardPlayer: Codable, Identifiable, Equatable {
    let id: UUID
    var userId: UUID?
    let name: String
    var position: String = ""
    var portraitURL: String?
    var avatarURL: String?
    /// One of the thirteen Saudi regions (`sa-01`…); the walkout opens on it.
    var regionId: String?
    var votes: Int?
}

/// One per teammate: an emoji, a short note, or both.
struct MatchAwardCheer: Codable, Identifiable, Equatable {
    let userId: UUID
    let name: String
    var avatarURL: String?
    var emoji: String?
    var note: String?
    var updatedAt: Date?
    var id: UUID { userId }

    static let emoji = ["👏", "🔥", "🐐", "💪", "😂", "❤️"]
    static let maximumLength = 60
}

struct MatchAward: Codable, Identifiable {
    enum Status: String, Codable { case unavailable, nomination, open, closed }
    let eventId: UUID
    let title: String
    var status: Status
    var canNominate: Bool
    var canVote: Bool
    var players: [MatchAwardPlayer]
    var closesAt: Date?
    var totalVotes: Int?
    var myVoteId: UUID?
    var votedCount: Int?
    var voterCount: Int?
    /// Decided on the server: most votes, and a tie goes to whoever got there first.
    var winnerId: UUID?
    var canCheer: Bool?
    var cheers: [MatchAwardCheer]?
    var myCheer: MyCheer?
    struct MyCheer: Codable, Equatable { var emoji: String?; var note: String? }
    var id: UUID { eventId }
    var winner: MatchAwardPlayer? {
        guard status == .closed, let winnerId else { return nil }
        return players.first { $0.id == winnerId }
    }
    var actionTitle: String {
        switch status {
        case .nomination: return String(localized: "رشّح نجوم المباراة")
        case .open: return myVoteId == nil ? String(localized: "صوّت لرجل المباراة") : String(localized: "صوتك محفوظ")
        case .closed: return String(localized: "نتيجة رجل المباراة")
        case .unavailable: return String(localized: "رجل المباراة")
        }
    }
}

@MainActor
final class MatchAwardService {
    static let shared = MatchAwardService()
    private var client: SupabaseClient { SupabaseClientManager.shared.client }

    func get(_ eventID: UUID) async throws -> MatchAward {
        #if DEBUG
        if HomeDebugMemberFixture.isEnabled, eventID == HomeDebugMemberFixture.matchAwardEventID,
           let award = MatchAwardModel.scenarioModel.award { return award }
        #endif
        return try await call("get_match_award", params: ["p_event_id": .string(eventID.uuidString)])
    }
    func inbox() async throws -> [MatchAward] {
        let response = try await client.rpc("get_my_match_awards").execute()
        return try EventService.makePostgresDecoder().decode([MatchAward].self, from: response.data)
    }
    func nominate(_ eventID: UUID, players: [UUID], regions: [String?]) async throws -> MatchAward {
        try await call("nominate_match_award", params: [
            "p_event_id": .string(eventID.uuidString),
            "p_participant_ids": .array(players.map { .string($0.uuidString) }),
            "p_region_ids": .array(regions.map { $0.map(AnyJSON.string) ?? .null })
        ])
    }
    func cheer(_ eventID: UUID, emoji: String?, note: String?) async throws -> MatchAward {
        try await call("cheer_match_award", params: [
            "p_event_id": .string(eventID.uuidString),
            "p_emoji": emoji.map(AnyJSON.string) ?? .null,
            "p_note": note.map(AnyJSON.string) ?? .null
        ])
    }
    func vote(_ eventID: UUID, player: UUID) async throws -> MatchAward {
        try await call("vote_match_award", params: [
            "p_event_id": .string(eventID.uuidString), "p_participant_id": .string(player.uuidString)
        ])
    }
    private func call(_ name: String, params: [String: AnyJSON]) async throws -> MatchAward {
        let response = try await client.rpc(name, params: params).execute()
        return try EventService.makePostgresDecoder().decode(MatchAward.self, from: response.data)
    }
}
