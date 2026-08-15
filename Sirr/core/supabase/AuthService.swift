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

/// Row for the public.users table (user_id, name, position, optional avatar_url, optional STC Pay number).
struct UserRecord: Codable {
    let userId: UUID
    let name: String
    let position: String
    let avatarUrl: String?
    let stcPayNumber: String?

    init(userId: UUID, name: String, position: String, avatarUrl: String?, stcPayNumber: String? = nil) {
        self.userId = userId
        self.name = name
        self.position = position
        self.avatarUrl = avatarUrl
        self.stcPayNumber = stcPayNumber
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name
        case position = "postion"
        case avatarUrl = "avatar_url"
        case stcPayNumber = "stc_pay_number"
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

/// Payload for updating only the STC Pay number (normalized canonical form).
private struct UpdateSTCPayPayload: Encodable {
    let stcPayNumber: String?

    enum CodingKeys: String, CodingKey {
        case stcPayNumber = "stc_pay_number"
    }
}

/// Name-only insert for the Apple sign-in path, which runs before the profile
/// step and so may have no row yet. `postion` is `not null default ''` in the
/// schema, so leaving it out is valid.
private struct AppleNamePayload: Encodable {
    let userId: UUID
    let name: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name
    }
}

/// Name-only update for the Apple sign-in path, so storing the name Apple sent
/// cannot clobber a position or avatar the row already has.
private struct AppleNameUpdate: Encodable {
    let name: String
}

/// Decodes the `user_id` PostgREST hands back from an update with `.select()`.
/// An empty array means no row matched, which is how the update-then-insert
/// paths below tell "updated" from "does not exist yet".
private struct UserIdRow: Decodable {
    let userId: UUID

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
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
            // Update first, insert only when nothing matched. The Apple sign-in
            // path may already have created this row, so a plain insert can
            // collide — but upsert is not an option either: public.users was
            // created by hand and its user_id carries no unique constraint, so
            // ON CONFLICT fails with 42P10. This works either way.
            let created = try await updateThenInsertProfile(
                userId: userId,
                record: record,
                update: UpdateUserPayload(name: fullName, position: preferredPosition, avatarUrl: avatarUrl)
            )
            authLogger.info("API createOrUpdateProfile succeeded (inserted: \(created))")
        } catch {
            authLogger.error("API createOrUpdateProfile failed: \(error.localizedDescription)")
            if let e = error as? URLError { authLogger.error("URLError: \(String(describing: e))") }
            throw error
        }
    }

    /// Writes the caller's profile row without an ON CONFLICT target: updates
    /// first, inserts only when the update matched nothing. Returns true when a
    /// row was inserted.
    ///
    /// Needed because `public.users` was created by hand and its `user_id` has no
    /// unique constraint in this project, so `upsert(onConflict:)` fails with
    /// 42P10 "no unique or exclusion constraint matching the ON CONFLICT
    /// specification". Add the primary key and this can go back to a plain upsert.
    private func updateThenInsertProfile(
        userId: UUID,
        record: UserRecord,
        update: UpdateUserPayload
    ) async throws -> Bool {
        // .select() makes the update return the rows it touched, which is how we
        // tell "updated" from "no such row" — PostgREST reports no count otherwise.
        let touched: [UserIdRow] = try await client
            .from("users")
            .update(update)
            .eq("user_id", value: userId)
            .select("user_id")
            .execute()
            .value
        guard touched.isEmpty else { return false }

        try await client
            .from("users")
            .insert(record)
            .execute()
        return true
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

    /// Update only the STC Pay number on the current user's row.
    /// Pass nil to clear it. Caller is responsible for normalizing to canonical form.
    func updateSTCPayNumber(_ canonical: String?) async throws {
        let session = try await client.auth.session
        let userId = session.user.id
        let payload = UpdateSTCPayPayload(stcPayNumber: canonical)
        do {
            try await client
                .from("users")
                .update(payload)
                .eq("user_id", value: userId)
                .execute()
            authLogger.info("API updateSTCPayNumber succeeded (cleared: \(canonical == nil))")
        } catch {
            authLogger.error("API updateSTCPayNumber failed: \(error.localizedDescription)")
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

    /// Upload avatar image to storage bucket tamrin-stg; returns public URL or nil on failure.
    ///
    /// The path is the user's id, so every photo after the first is a
    /// replacement: without `upsert` the storage API rejects it as a duplicate
    /// and the new picture silently never leaves the device. And because the
    /// URL never changes either, the stored one carries a version stamp — the
    /// caches downstream (AsyncImage, URLCache) key on it, and would otherwise
    /// keep serving the picture the user just replaced.
    func uploadAvatar(userId: UUID, imageData: Data) async -> String? {
        let bucketName = "tamrin-stg"
        let path = "\(userId.uuidString).jpg"
        do {
            try await client.storage
                .from(bucketName)
                .upload(
                    path,
                    data: imageData,
                    options: FileOptions(contentType: "image/jpeg", upsert: true)
                )
            let url = try? client.storage.from(bucketName).getPublicURL(path: path).absoluteString
            authLogger.info("API uploadAvatar succeeded")
            return url.map { "\($0)?v=\(Int(Date().timeIntervalSince1970))" }
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

    /// Thrown when the account still owns a group other people are in. The
    /// server refuses in that case rather than cascading the group away, and
    /// the UI turns this into an instruction the user can act on.
    struct OwnsSharedWorkspaceError: LocalizedError {
        var errorDescription: String? {
            "لديك تمرين فيه أعضاء آخرون. احذف التمرين أو انقل ملكيته أولًا، ثم احذف الحساب."
        }
    }

    /// Delete the signed-in account. The `delete_account` RPC strips every
    /// personal field, blocks sign-in and unlinks the identities, while leaving
    /// one anonymous users row behind so the event and payment history other
    /// members share does not go with it. The local session is then dropped so
    /// the app returns to the login flow.
    func deleteAccount() async throws {
        do {
            try await client.rpc("delete_account").execute()
            authLogger.info("API deleteAccount succeeded")
        } catch {
            if "\(error)".contains("OWNS_SHARED_WORKSPACE") {
                authLogger.error("API deleteAccount blocked: owns a shared workspace")
                throw OwnsSharedWorkspaceError()
            }
            authLogger.error("API deleteAccount failed: \(error.localizedDescription)")
            throw error
        }

        // Sign-in is already blocked server-side, so this is about clearing the
        // stored session and returning to the login flow.
        try? await client.auth.signOut()
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

    /// Exchange an Apple identity token for a Supabase session. Returns true if new user.
    func signInWithApple(idToken: String, nonce: String) async throws -> Bool {
        do {
            try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
            )
            let isNew = await isNewUserFromUsersTable()
            authLogger.info("API signInWithApple succeeded (isNewUser: \(isNew))")
            return isNew
        } catch {
            authLogger.error("API signInWithApple failed: \(error.localizedDescription)")
            if let e = error as? URLError { authLogger.error("URLError: \(String(describing: e))") }
            throw error
        }
    }

    /// Stores the name Apple hands back and returns what the profile step should
    /// prefill, so the user is never asked to retype what Apple already sent
    /// (App Review guideline 4 — Design).
    ///
    /// Apple populates `fullName`/`email` **only on the first authorization** for
    /// an Apple ID; every later sign-in returns nil. A name arriving here must
    /// therefore be persisted at once or it is lost for good. Preference order:
    ///
    ///   1. a name already on the row — the user may have edited it themselves,
    ///      so it outranks anything we could derive
    ///   2. the name Apple just sent, which we persist
    ///   3. the local part of the email, as a prefill only — never written,
    ///      because it is a guess rather than something Apple or the user stated
    ///
    /// Returns "" only when none of the three is available, which is the one case
    /// where the profile step still has to ask.
    func adoptAppleIdentity(fullName: PersonNameComponents?, email: String?) async -> String {
        let stored = (try? await getCurrentUserProfile())?
            .name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty {
            authLogger.info("Apple identity: keeping the name already on the profile")
            return stored
        }

        if let fullName {
            let formatted = PersonNameComponentsFormatter
                .localizedString(from: fullName, style: .default, options: [])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !formatted.isEmpty {
                await persistAppleName(formatted)
                return formatted
            }
        }

        // No name from Apple: either a repeat sign-in, or the user chose to hide
        // it. Fall back to the email so the field is never empty and the button
        // is never blocked.
        let sessionEmail = (try? await client.auth.session)?.user.email
        let fallback = (email ?? sessionEmail)
            .flatMap { $0.split(separator: "@").first }
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        authLogger.info("Apple identity: no name supplied, prefilling from email (empty: \(fallback.isEmpty))")
        return fallback
    }

    /// Writes just the name onto the caller's row, creating the row when Apple
    /// sign-in happens before the profile step. Upsert rather than insert because
    /// a row may already exist from an earlier sign-in.
    private func persistAppleName(_ name: String) async {
        guard let session = try? await client.auth.session else { return }
        do {
            // Update then insert, for the same reason as createOrUpdateProfile:
            // user_id has no unique constraint, so ON CONFLICT is unavailable.
            // Name-only, so a position or avatar already on the row survives.
            let touched: [UserIdRow] = try await client
                .from("users")
                .update(AppleNameUpdate(name: name))
                .eq("user_id", value: session.user.id)
                .select("user_id")
                .execute()
                .value
            if touched.isEmpty {
                try await client
                    .from("users")
                    .insert(AppleNamePayload(userId: session.user.id, name: name))
                    .execute()
            }
            authLogger.info("Apple identity: persisted the name Apple supplied (inserted: \(touched.isEmpty))")
        } catch {
            // Non-fatal — the caller still prefills from the returned value, so
            // the user is not blocked. Logged loudly because a silent failure
            // here means Apple's name is gone by the next sign-in.
            authLogger.error("Apple identity: failed to persist the name: \(error.localizedDescription)")
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
