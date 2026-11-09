//
//  PickPlayersService.swift
//  Sirr
//
//  What an organizer can pick players from when creating an event: their own
//  groups and everyone who played in one of their events. Spec:
//  docs/superpowers/specs/2026-11-09-new-event-pick-players-design.md
//

import Supabase
import Foundation
import os

private let pickLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "PickPlayersService")

/// An app user the organizer can pick. Name-only guests never appear.
struct PickPerson: Decodable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id = "user_id"
        case name
        case avatarUrl = "avatar_url"
    }
}

/// One of the organizer's own groups, without the organizer in `members`.
struct PickGroup: Decodable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let lastPlayedAt: Date?
    let members: [PickPerson]

    enum CodingKeys: String, CodingKey {
        case id = "workspace_id"
        case name
        case lastPlayedAt = "last_played_at"
        case members
    }
}

struct PickSources: Decodable {
    let groups: [PickGroup]
    let pastPlayers: [PickPerson]

    /// Nothing to pick from: the new step is skipped and the flow is as before.
    var isEmpty: Bool { groups.isEmpty && pastPlayers.isEmpty }

    static let empty = PickSources(groups: [], pastPlayers: [])

    enum CodingKeys: String, CodingKey {
        case groups
        case pastPlayers = "past_players"
    }
}

/// What the organizer chose on the last step.
struct PlayerPick: Equatable {
    /// The group they started from; nil when they tapped "مجموعة جديدة".
    var sourceGroup: PickGroup?
    var selected: Set<UUID>
}

enum PlayerPickDestination: Equatable {
    case existing(workspaceId: UUID)
    case newWorkspace
}

extension PlayerPick {
    /// The whole group picked → that group. The exact members of another of
    /// the organizer's groups → that group, so the same people never make a
    /// second copy. Anything else → a new group.
    func destination(ownedGroups: [PickGroup]) -> PlayerPickDestination {
        if let sourceGroup, selected == Set(sourceGroup.members.map(\.id)) {
            return .existing(workspaceId: sourceGroup.id)
        }
        if !selected.isEmpty,
           let match = ownedGroups.first(where: { Set($0.members.map(\.id)) == selected }) {
            return .existing(workspaceId: match.id)
        }
        return .newWorkspace
    }
}

final class PickPlayersService {
    static let shared = PickPlayersService()
    private let client = SupabaseClientManager.shared.client

    func getPickSources() async throws -> PickSources {
        do {
            let response = try await client
                .rpc("get_my_pick_sources")
                .execute()
            let sources = try EventService.makePostgresDecoder()
                .decode(PickSources.self, from: response.data)
            pickLogger.info("API getPickSources succeeded (groups: \(sources.groups.count), past: \(sources.pastPlayers.count))")
            return sources
        } catch {
            pickLogger.error("API getPickSources failed: \(error.localizedDescription)")
            throw error
        }
    }
}
