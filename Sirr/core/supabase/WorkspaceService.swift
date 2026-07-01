//
//  WorkspaceService.swift
//  Sirr
//
//  Workspaces: private groups that contain events. All calls go through
//  SECURITY DEFINER RPCs that identify the caller via auth.uid().
//

import Supabase
import Foundation
import os

private let wsLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "WorkspaceService")

/// Row from public.workspaces (as returned by workspace RPCs).
struct WorkspaceRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let ownerId: UUID
    let inviteCode: String?
    let imageUrl: String?
    let memberCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case ownerId = "owner_id"
        case inviteCode = "invite_code"
        case imageUrl = "image_url"
        case memberCount = "member_count"
    }

    /// Universal invite link (same domain as event links).
    var inviteURL: URL? {
        guard let inviteCode else { return nil }
        return URL(string: "https://guileless-squirrel-b6537a.netlify.app/join/\(inviteCode)")
    }
}

/// Member row from get_workspace RPC.
struct WorkspaceMemberRecord: Codable, Identifiable, Hashable {
    let userId: UUID
    let displayName: String?
    let avatarUrl: String?
    let isOwner: Bool

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case isOwner = "is_owner"
    }
}

/// Payload of get_workspace RPC.
struct WorkspaceDetail: Codable {
    let workspace: WorkspaceRecord
    let members: [WorkspaceMemberRecord]
}

/// Payload of get_workspace_by_invite RPC (join screen preview).
struct WorkspaceInvitePreview: Codable {
    let id: UUID
    let name: String
    let ownerName: String?
    let memberCount: Int
    let isMember: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case ownerName = "owner_name"
        case memberCount = "member_count"
        case isMember = "is_member"
    }
}

final class WorkspaceService {
    static let shared = WorkspaceService()
    private let client = SupabaseClientManager.shared.client

    func createWorkspace(name: String) async throws -> WorkspaceRecord {
        let response = try await client
            .rpc("create_workspace", params: ["p_name": name])
            .execute()
        let ws = try JSONDecoder().decode(WorkspaceRecord.self, from: response.data)
        wsLogger.info("API createWorkspace succeeded (id: \(ws.id))")
        return ws
    }

    func getMyWorkspaces() async throws -> [WorkspaceRecord] {
        let response = try await client
            .rpc("get_my_workspaces")
            .execute()
        let list = try JSONDecoder().decode([WorkspaceRecord].self, from: response.data)
        wsLogger.info("API getMyWorkspaces succeeded (count: \(list.count))")
        return list
    }

    func getWorkspace(id: UUID) async throws -> WorkspaceDetail {
        let response = try await client
            .rpc("get_workspace", params: ["p_workspace_id": id.uuidString])
            .execute()
        let detail = try JSONDecoder().decode(WorkspaceDetail.self, from: response.data)
        wsLogger.info("API getWorkspace succeeded (id: \(id))")
        return detail
    }

    func getInvitePreview(code: String) async throws -> WorkspaceInvitePreview {
        let response = try await client
            .rpc("get_workspace_by_invite", params: ["p_code": code])
            .execute()
        return try JSONDecoder().decode(WorkspaceInvitePreview.self, from: response.data)
    }

    /// Joins via invite code; returns the workspace id (idempotent server-side).
    func joinWorkspace(code: String) async throws -> UUID {
        struct JoinResult: Decodable {
            let workspaceId: UUID
            enum CodingKeys: String, CodingKey { case workspaceId = "workspace_id" }
        }
        let response = try await client
            .rpc("join_workspace", params: ["p_code": code])
            .execute()
        let result = try JSONDecoder().decode(JoinResult.self, from: response.data)
        wsLogger.info("API joinWorkspace succeeded (id: \(result.workspaceId))")
        return result.workspaceId
    }

    func leaveWorkspace(id: UUID) async throws {
        try await client
            .rpc("leave_workspace", params: ["p_workspace_id": id.uuidString])
            .execute()
        wsLogger.info("API leaveWorkspace succeeded (id: \(id))")
    }

    func removeMember(workspaceId: UUID, userId: UUID) async throws {
        let params = [
            "p_workspace_id": workspaceId.uuidString,
            "p_member_id": userId.uuidString
        ]
        try await client.rpc("remove_member", params: params).execute()
        wsLogger.info("API removeMember succeeded (workspace: \(workspaceId))")
    }

    func renameWorkspace(id: UUID, name: String) async throws -> WorkspaceRecord {
        let params = ["p_workspace_id": id.uuidString, "p_name": name]
        let response = try await client.rpc("update_workspace", params: params).execute()
        return try JSONDecoder().decode(WorkspaceRecord.self, from: response.data)
    }

    func regenerateInviteCode(id: UUID) async throws -> String {
        struct CodeResult: Decodable {
            let inviteCode: String
            enum CodingKeys: String, CodingKey { case inviteCode = "invite_code" }
        }
        let response = try await client
            .rpc("regenerate_invite_code", params: ["p_workspace_id": id.uuidString])
            .execute()
        return try JSONDecoder().decode(CodeResult.self, from: response.data).inviteCode
    }

    func deleteWorkspace(id: UUID) async throws {
        try await client
            .rpc("delete_workspace", params: ["p_workspace_id": id.uuidString])
            .execute()
        wsLogger.info("API deleteWorkspace succeeded (id: \(id))")
    }
}
