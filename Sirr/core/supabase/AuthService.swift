//
//  AuthService.swift
//  Sirr
//
//  Created by naif ali alshahrani on 11/08/1447 AH.
//

import Supabase
import Foundation
import os

private let authLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "AuthService")

/// Row for the public.users table (user_id, name, position, optional avatar_url).
struct UserRecord: Codable {
    let userId: UUID
    let name: String
    let position: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name
        case position = "postion"
        case avatarUrl = "avatar_url"
    }
}

/// Payload for updating a user row (name, position, avatar_url only).
private struct UpdateUserPayload: Encodable {
    let name: String
    let position: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case name
        case position = "postion"
        case avatarUrl = "avatar_url"
    }
}

final class AuthService {
    static let shared = AuthService()
    private let client = SupabaseClientManager.shared.client

    // Sign Up
    func signUp(email: String, password: String) async throws {
        do {
            try await client.auth.signUp(email: email, password: password)
            authLogger.info("API signUp succeeded")
        } catch {
            authLogger.error("API signUp failed: \(error.localizedDescription)")
            if let e = error as? URLError { authLogger.error("URLError: \(String(describing: e))") }
            throw error
        }
    }

    // Anonymous sign-in (creates auth user so we can create a profile)
    func signInAnonymously() async throws {
        do {
            _ = try await client.auth.signInAnonymously()
            authLogger.info("API signInAnonymously succeeded")
        } catch {
            authLogger.error("API signInAnonymously failed: \(error.localizedDescription)")
            throw error
        }
    }

    // Create or update user row (users table). Call after sign-in.
    func createOrUpdateProfile(fullName: String, preferredPosition: String, avatarUrl: String?) async throws {
        do {
            let session = try await client.auth.session
            let userId = session.user.id
            let record = UserRecord(
                userId: userId,
                name: fullName,
                position: preferredPosition,
                avatarUrl: avatarUrl
            )
            try await client
                .from("users")
                .insert(record)
                .execute()
            authLogger.info("API createOrUpdateProfile succeeded")
        } catch {
            authLogger.error("API createOrUpdateProfile failed: \(error.localizedDescription)")
            if let e = error as? URLError { authLogger.error("URLError: \(String(describing: e))") }
            throw error
        }
    }

    /// Fetch the current user's row from public.users. Returns nil if not found or no session.
    func getCurrentUserProfile() async throws -> UserRecord? {
        let session = try await client.auth.session
        let userId = session.user.id
        do {
            let rows: [UserRecord] = try await client
                .from("users")
                .select()
                .eq("user_id", value: userId)
                .limit(1)
                .execute()
                .value
            authLogger.info("API getCurrentUserProfile succeeded (found: \(!rows.isEmpty))")
            return rows.first
        } catch {
            authLogger.error("API getCurrentUserProfile failed: \(error.localizedDescription)")
            if let e = error as? URLError { authLogger.error("URLError: \(String(describing: e))") }
            throw error
        }
    }

    /// Update the current user's row (name, position, avatar_url).
    func updateProfile(name: String, position: String, avatarUrl: String?) async throws {
        let session = try await client.auth.session
        let userId = session.user.id
        let payload = UpdateUserPayload(name: name, position: position, avatarUrl: avatarUrl)
        do {
            try await client
                .from("users")
                .update(payload)
                .eq("user_id", value: userId)
                .execute()
            authLogger.info("API updateProfile succeeded")
        } catch {
            authLogger.error("API updateProfile failed: \(error.localizedDescription)")
            if let e = error as? URLError { authLogger.error("URLError: \(String(describing: e))") }
            throw error
        }
    }

    // Upload avatar image to storage bucket tamrin-stg; returns public URL or nil on failure.
    func uploadAvatar(userId: UUID, imageData: Data) async -> String? {
        let bucketName = "tamrin-stg"
        let path = "\(userId.uuidString).jpg"
        do {
            try await client.storage
                .from(bucketName)
                .upload(path, data: imageData, options: FileOptions(contentType: "image/jpeg"))
            let url = try? client.storage.from(bucketName).getPublicURL(path: path).absoluteString
            authLogger.info("API uploadAvatar succeeded")
            return url
        } catch {
            authLogger.error("API uploadAvatar failed: \(error.localizedDescription)")
            if let e = error as? URLError { authLogger.error("URLError: \(String(describing: e))") }
            return nil
        }
    }

    // Login
    func signIn(email: String, password: String) async throws {
        do {
            try await client.auth.signIn(email: email, password: password)
            authLogger.info("API signIn succeeded")
        } catch {
            authLogger.error("API signIn failed: \(error.localizedDescription)")
            if let e = error as? URLError { authLogger.error("URLError: \(String(describing: e))") }
            throw error
        }
    }

    // Logout
    func signOut() async throws {
        do {
            try await client.auth.signOut()
            authLogger.info("API signOut succeeded")
        } catch {
            authLogger.error("API signOut failed: \(error.localizedDescription)")
            throw error
        }
    }

    // Current session
    func session() async throws -> Session? {
        do {
            let s = try await client.auth.session
            authLogger.info("API session succeeded")
            return s
        } catch {
            authLogger.error("API session failed: \(error.localizedDescription)")
            throw error
        }
    }

    // Request OTP (sends code to email)
    func requestOTP(email: String) async throws {
        do {
            try await client.auth.signInWithOTP(email: email)
            authLogger.info("API requestOTP succeeded")
        } catch {
            authLogger.error("API requestOTP failed: \(error.localizedDescription)")
            if let e = error as? URLError { authLogger.error("URLError: \(String(describing: e))") }
            throw error
        }
    }

    // Verify OTP and establish session. Returns true if new user (no row in users table).
    func verifyOTP(email: String, token: String) async throws -> Bool {
        do {
            try await client.auth.verifyOTP(email: email, token: token, type: .email)
            let isNew = await isNewUserFromUsersTable()
            authLogger.info("API verifyOTP succeeded (isNewUser: \(isNew))")
            return isNew
        } catch {
            authLogger.error("API verifyOTP failed: \(error.localizedDescription)")
            if let e = error as? URLError { authLogger.error("URLError: \(String(describing: e))") }
            throw error
        }
    }

    /// New user = no row in public.users for the current auth user (user_id matches auth id).
    private func isNewUserFromUsersTable() async -> Bool {
        guard let session = try? await client.auth.session else { return true }
        let userId = session.user.id
        do {
            struct UserRow: Decodable { let userId: UUID; enum CodingKeys: String, CodingKey { case userId = "user_id" } }
            let rows: [UserRow] = try await client
                .from("users")
                .select("user_id")
                .eq("user_id", value: userId)
                .limit(1)
                .execute()
                .value
            let hasUser = !rows.isEmpty
            authLogger.info("API users table check: hasRow=\(hasUser)")
            return !hasUser
        } catch {
            authLogger.error("API users table check failed: \(error.localizedDescription), treating as new user")
            return true
        }
    }
}
