//
//  LineupTalkService.swift
//  Sirr
//
//  «خواطر التشكيلة»: one short thought per player on the published lineup,
//  one emoji reaction per person on each thought, short replies, and a verdict
//  on the split as a whole. Every call returns the whole conversation, so the
//  screen never has to merge a partial answer into what it is showing.
//

import Foundation
import Supabase

/// What a player makes of the split as a whole.
enum LineupVerdict: String, CaseIterable, Codable, Identifiable {
    case balanced, fire, unfair

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .balanced: "⚖️"
        case .fire: "🔥"
        case .unfair: "😬"
        }
    }

    var title: String {
        switch self {
        case .balanced: String(localized: "متوازنة")
        case .fire: String(localized: "نار")
        case .unfair: String(localized: "ظالمة")
        }
    }
}

struct LineupThoughtReaction: Codable, Equatable {
    let userID: UUID
    let name: String
    let emoji: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id", name, emoji
    }
}

struct LineupThoughtReply: Codable, Equatable, Identifiable {
    let id: UUID
    let userID: UUID
    let name: String
    let body: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, userID = "user_id", name, body, createdAt = "created_at"
    }
}

/// One player's thought. A player has at most one per exercise, so the author
/// is the identity.
struct LineupThought: Codable, Equatable, Identifiable {
    let userID: UUID
    let name: String
    var body: String
    var updatedAt: Date
    var reactions: [LineupThoughtReaction]
    var replies: [LineupThoughtReply]

    var id: UUID { userID }

    /// Emoji with how many chose each, most chosen first.
    var reactionSummary: [(emoji: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for reaction in reactions {
            if counts[reaction.emoji] == nil { order.append(reaction.emoji) }
            counts[reaction.emoji, default: 0] += 1
        }
        return order
            .map { (emoji: $0, count: counts[$0] ?? 0) }
            .sorted { $0.count > $1.count }
    }

    func reaction(by userID: UUID?) -> String? {
        guard let userID else { return nil }
        return reactions.first { $0.userID == userID }?.emoji
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id", name, body, updatedAt = "updated_at", reactions, replies
    }
}

struct LineupTalk: Codable, Equatable {
    /// False a day after the exercise ends: thoughts are gone and nothing new
    /// can be written, though the verdict counts remain.
    var isOpen: Bool
    var thoughts: [LineupThought]
    var verdicts: [LineupVerdict: Int]
    var myVerdict: LineupVerdict?

    static let reactionEmoji = ["👍", "😂", "🔥", "💪", "😤", "❤️"]
    static let maximumLength = 60

    var verdictTotal: Int { verdicts.values.reduce(0, +) }

    /// The verdict most people gave, and how many gave it. Nil until someone
    /// has said anything, and on a tie, where there is no leading opinion.
    var leadingVerdict: (verdict: LineupVerdict, count: Int)? {
        let ranked = LineupVerdict.allCases
            .map { (verdict: $0, count: verdicts[$0] ?? 0) }
            .sorted { $0.count > $1.count }
        guard let first = ranked.first, first.count > 0 else { return nil }
        if ranked.count > 1, ranked[1].count == first.count { return nil }
        return first
    }

    func thought(by userID: UUID?) -> LineupThought? {
        guard let userID else { return nil }
        return thoughts.first { $0.userID == userID }
    }

    init(isOpen: Bool, thoughts: [LineupThought], verdicts: [LineupVerdict: Int], myVerdict: LineupVerdict?) {
        self.isOpen = isOpen
        self.thoughts = thoughts
        self.verdicts = verdicts
        self.myVerdict = myVerdict
    }

    private struct VerdictCounts: Codable {
        var balanced: Int
        var fire: Int
        var unfair: Int
    }

    enum CodingKeys: String, CodingKey {
        case isOpen = "is_open", thoughts, verdicts, myVerdict = "my_verdict"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isOpen = try container.decode(Bool.self, forKey: .isOpen)
        thoughts = try container.decode([LineupThought].self, forKey: .thoughts)
        let counts = try container.decode(VerdictCounts.self, forKey: .verdicts)
        verdicts = [.balanced: counts.balanced, .fire: counts.fire, .unfair: counts.unfair]
        myVerdict = try container.decodeIfPresent(LineupVerdict.self, forKey: .myVerdict)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isOpen, forKey: .isOpen)
        try container.encode(thoughts, forKey: .thoughts)
        try container.encode(VerdictCounts(
            balanced: verdicts[.balanced] ?? 0,
            fire: verdicts[.fire] ?? 0,
            unfair: verdicts[.unfair] ?? 0
        ), forKey: .verdicts)
        try container.encodeIfPresent(myVerdict, forKey: .myVerdict)
    }
}

final class LineupTalkService {
    static let shared = LineupTalkService()
    private var client: SupabaseClient { SupabaseClientManager.shared.client }

    /// Nil when the caller may not take part: no published lineup, or no seat.
    func get(eventID: UUID) async throws -> LineupTalk? {
        try await call("get_lineup_talk", ["p_event_id": .string(eventID.uuidString)])
    }

    func setThought(_ body: String?, eventID: UUID) async throws -> LineupTalk? {
        try await call("set_lineup_thought", [
            "p_event_id": .string(eventID.uuidString),
            "p_body": body.map { .string($0) } ?? .null
        ])
    }

    func react(_ emoji: String?, to authorID: UUID, eventID: UUID) async throws -> LineupTalk? {
        try await call("react_to_lineup_thought", [
            "p_event_id": .string(eventID.uuidString),
            "p_author_id": .string(authorID.uuidString),
            "p_emoji": emoji.map { .string($0) } ?? .null
        ])
    }

    func reply(_ body: String, to authorID: UUID, eventID: UUID) async throws -> LineupTalk? {
        try await call("reply_to_lineup_thought", [
            "p_event_id": .string(eventID.uuidString),
            "p_author_id": .string(authorID.uuidString),
            "p_body": .string(body)
        ])
    }

    func deleteReply(_ replyID: UUID) async throws -> LineupTalk? {
        try await call("delete_lineup_thought_reply", ["p_reply_id": .string(replyID.uuidString)])
    }

    func setVerdict(_ verdict: LineupVerdict?, eventID: UUID) async throws -> LineupTalk? {
        try await call("set_lineup_verdict", [
            "p_event_id": .string(eventID.uuidString),
            "p_verdict": verdict.map { .string($0.rawValue) } ?? .null
        ])
    }

    private func call(_ function: String, _ params: [String: AnyJSON]) async throws -> LineupTalk? {
        let response = try await client.rpc(function, params: params).execute()
        // The RPC answers null for someone who may not take part.
        if let text = String(data: response.data, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return nil
        }
        return try EventService.makePostgresDecoder().decode(LineupTalk.self, from: response.data)
    }
}
