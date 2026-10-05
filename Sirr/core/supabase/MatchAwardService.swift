import Foundation
import Supabase

struct MatchAwardPlayer: Codable, Identifiable, Equatable {
    let id: UUID
    var userId: UUID?
    let name: String
    var position: String = ""
    var portraitURL: String?
    var avatarURL: String?
    var votes: Int?
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
    var id: UUID { eventId }
    var winners: [MatchAwardPlayer] {
        guard status == .closed, let highest = players.compactMap(\.votes).max(), highest > 0 else { return [] }
        return players.filter { $0.votes == highest }
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
    func nominate(_ eventID: UUID, players: [UUID]) async throws -> MatchAward {
        try await call("nominate_match_award", params: [
            "p_event_id": .string(eventID.uuidString),
            "p_participant_ids": .array(players.map { .string($0.uuidString) })
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
