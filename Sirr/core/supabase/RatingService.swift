//
//  RatingService.swift
//  Sirr
//
//  Peer player ratings: read one player's rating in a workspace, and submit
//  or revise your own. See migration 20260818100000_player_ratings.sql — the
//  anonymity and membership rules live there, not here.
//

import Foundation
import Supabase
import os

private let ratingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Sirr",
    category: "RatingService"
)

/// What one member is allowed to know about another's rating.
struct PlayerRatingSummary {
    /// The position stored on the player's own profile, verbatim — including a
    /// custom one, which the Overall still weights as a defender.
    let position: String
    /// True once the caller has rated this player. This controls whether the
    /// action says rate or edit; it does not gate the anonymous group average.
    let hasRated: Bool
    /// How many people have rated this player, whoever they are.
    let ratingsCount: Int
    /// The caller's own numbers, for the flow to reopen on.
    let mine: PlayerRatingScores?
    /// Everyone's numbers, averaged per attribute. Nil only when nobody has
    /// rated the player yet.
    let average: PlayerRatingScores?
    /// The player's rating as the sheet shows it: the crowd's, not the
    /// caller's. Taken from the server rather than recomputed from `average`,
    /// which is rounded per attribute and would blend to a slightly different
    /// number.
    let averageOverall: Int?
    /// The Overall of the caller's own rating.
    let myOverall: Int?

    var resolvedPosition: PlayerPosition { PlayerPosition.resolved(from: position) }

    /// Nobody has rated this player yet — a different state from "you have
    /// not rated him", and worded differently in the sheet.
    var isUnrated: Bool { ratingsCount == 0 }
}

enum SubmitRatingResult {
    case saved(PlayerRatingSummary)
    /// Nobody rates themselves.
    case isSelf
    /// The player left the group between opening the sheet and submitting.
    case notAMember
    /// The player must choose one of the app's positions before an Overall can
    /// be calculated with the correct weighting profile.
    case positionRequired
    case outOfRange
}

final class RatingService {
    static let shared = RatingService()
    private let client = SupabaseClientManager.shared.client

    /// One player's rating inside one workspace.
    func getPlayerRating(workspaceId: UUID, userId: UUID) async throws -> PlayerRatingSummary {
        let params: [String: String] = [
            "p_workspace_id": workspaceId.uuidString,
            "p_user_id": userId.uuidString
        ]

        let response = try await client
            .rpc("get_player_rating", params: params)
            .execute()

        let summary = try Self.decodeSummary(response.data)
        ratingLogger.info(
            "API getPlayerRating succeeded (user: \(userId), rated: \(summary.hasRated), raters: \(summary.ratingsCount))"
        )
        return summary
    }

    /// Stores the caller's rating of one player, replacing their previous one.
    func submitPlayerRating(
        workspaceId: UUID,
        userId: UUID,
        scores: PlayerRatingScores
    ) async throws -> SubmitRatingResult {
        var params: [String: AnyJSON] = [
            "p_workspace_id": .string(workspaceId.uuidString),
            "p_user_id": .string(userId.uuidString)
        ]
        for attribute in PlayerAttribute.allCases {
            params["p_\(attribute.rawValue)"] = .integer(scores[attribute])
        }

        let response = try await client
            .rpc("submit_player_rating", params: params)
            .execute()

        guard
            let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
            let status = payload["status"] as? String
        else {
            throw NSError(
                domain: "RatingService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة رد الخادم."]
            )
        }

        switch status {
        case "saved":
            // The RPC returns the refreshed aggregate with the write, so the
            // sheet shows the new average without a second round trip.
            guard let rating = payload["rating"] as? [String: Any] else {
                throw NSError(
                    domain: "RatingService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة التقييم بعد حفظه."]
                )
            }
            return .saved(Self.summary(from: rating))
        case "is_self": return .isSelf
        case "not_a_member": return .notAMember
        case "position_required": return .positionRequired
        case "out_of_range": return .outOfRange
        default:
            throw NSError(
                domain: "RatingService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "رد غير متوقع من الخادم: \(status)"]
            )
        }
    }

    // MARK: - Decoding

    private static func decodeSummary(_ data: Data) throws -> PlayerRatingSummary {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "RatingService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "تعذر قراءة التقييم."]
            )
        }
        return summary(from: payload)
    }

    private static func summary(from payload: [String: Any]) -> PlayerRatingSummary {
        PlayerRatingSummary(
            position: payload["position"] as? String ?? "",
            hasRated: payload["has_rated"] as? Bool ?? false,
            ratingsCount: (payload["ratings_count"] as? NSNumber)?.intValue ?? 0,
            mine: scores(from: payload["mine"]),
            average: scores(from: payload["average"]),
            averageOverall: overall(from: payload["average"]),
            myOverall: overall(from: payload["mine"])
        )
    }

    private static func overall(from raw: Any?) -> Int? {
        guard
            let dictionary = raw as? [String: Any],
            let number = dictionary["overall"] as? NSNumber
        else { return nil }
        return number.intValue
    }

    /// The averages arrive as numbers Postgres already rounded, but they cross
    /// as JSON numbers rather than integers, so both are accepted.
    private static func scores(from raw: Any?) -> PlayerRatingScores? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        var scores = PlayerRatingScores.neutral
        for attribute in PlayerAttribute.allCases {
            guard let number = dictionary[attribute.rawValue] as? NSNumber else { return nil }
            scores[attribute] = Int(number.doubleValue.rounded())
        }
        return scores
    }
}
