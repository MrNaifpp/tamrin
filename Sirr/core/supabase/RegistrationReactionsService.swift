//
//  RegistrationReactionsService.swift
//  Sirr
//
//  Reactions on a registration, the way a WhatsApp group answers "I'm in":
//  one emoji per person per seat. The server also says what stood out about
//  each registration, so the fitting emoji can come first.
//

import Foundation
import Supabase

/// What stood out about one registration. Decided by the server, which is the
/// only side that knows a player's history with the group.
enum RegistrationContext: String, Codable {
    case first
    case lastSeat = "last_seat"
    case newcomer
    case returning
    case withGuests = "with_guests"

    var emoji: String {
        switch self {
        case .first: "🥇"
        case .lastSeat: "🔒"
        case .newcomer: "🎉"
        case .returning: "👋"
        case .withGuests: "🤝"
        }
    }

    var label: String {
        switch self {
        case .first: String(localized: "أول واحد سجّل")
        case .lastSeat: String(localized: "أخذ آخر مقعد")
        case .newcomer: String(localized: "أول تمرين له معكم")
        case .returning: String(localized: "رجع بعد غياب")
        case .withGuests: String(localized: "سجّل ومعه ضيوف")
        }
    }
}

struct SeatReactions: Codable, Equatable {
    let participantID: UUID
    var context: RegistrationContext?
    var reactions: [LineupThoughtReaction]

    static let baseEmoji = ["👏", "🔥", "💪", "😂", "❤️"]

    /// The context's own emoji first, then the usual five.
    var offeredEmoji: [String] {
        guard let context else { return Self.baseEmoji }
        return [context.emoji] + Self.baseEmoji.filter { $0 != context.emoji }
    }

    /// Distinct emoji, most chosen first.
    var topEmoji: [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for reaction in reactions {
            if counts[reaction.emoji] == nil { order.append(reaction.emoji) }
            counts[reaction.emoji, default: 0] += 1
        }
        return order.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
    }

    func reaction(by userID: UUID?) -> String? {
        guard let userID else { return nil }
        return reactions.first { $0.userID == userID }?.emoji
    }

    enum CodingKeys: String, CodingKey {
        case participantID = "participant_id", context, reactions
    }

    init(participantID: UUID, context: RegistrationContext?, reactions: [LineupThoughtReaction]) {
        self.participantID = participantID
        self.context = context
        self.reactions = reactions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        participantID = try container.decode(UUID.self, forKey: .participantID)
        // A context added on the server before the app knows it is ignored.
        context = (try? container.decodeIfPresent(String.self, forKey: .context))
            .flatMap { $0 }
            .flatMap(RegistrationContext.init(rawValue:))
        reactions = try container.decode([LineupThoughtReaction].self, forKey: .reactions)
    }
}

final class RegistrationReactionsService {
    static let shared = RegistrationReactionsService()
    private var client: SupabaseClient { SupabaseClientManager.shared.client }

    /// Nil for someone outside the group.
    func get(eventID: UUID) async throws -> [SeatReactions]? {
        try await call("get_registration_reactions", ["p_event_id": .string(eventID.uuidString)])
    }

    func react(_ emoji: String?, to participantID: UUID) async throws -> [SeatReactions]? {
        try await call("react_to_registration", [
            "p_participant_id": .string(participantID.uuidString),
            "p_emoji": emoji.map { .string($0) } ?? .null
        ])
    }

    private func call(_ function: String, _ params: [String: AnyJSON]) async throws -> [SeatReactions]? {
        let response = try await client.rpc(function, params: params).execute()
        if let text = String(data: response.data, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return nil
        }
        return try JSONDecoder().decode([SeatReactions].self, from: response.data)
    }
}
