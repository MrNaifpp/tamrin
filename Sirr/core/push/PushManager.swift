//
//  PushManager.swift
//  Sirr
//
//  Owns notification permission + APNs device-token upload. Server sends the
//  actual pushes; the client only registers and uploads its token.
//

import Foundation
import Supabase
import UIKit
import UserNotifications
import os

@MainActor
final class PushManager {
    static let shared = PushManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "Push")
    private let client = SupabaseClientManager.shared.client
    private init() {}

    /// Ask for permission (system dialog shows once) and register for APNs if granted.
    /// Safe to call repeatedly and from any payment entry point.
    func requestAuthorizationAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            logger.info("notification authorization granted: \(granted)")
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            logger.error("requestAuthorization failed: \(error.localizedDescription)")
        }
    }

    /// Upsert the APNs token for the signed-in user. RLS lets a user manage own tokens.
    func upsertToken(_ hex: String) async {
        struct DeviceToken: Encodable {
            let user_id: String
            let apns_token: String
            let platform: String
        }
        do {
            let session = try await client.auth.session
            let payload = DeviceToken(
                user_id: session.user.id.uuidString,
                apns_token: hex,
                platform: "ios")
            try await client.from("device_tokens")
                .upsert(payload, onConflict: "user_id,apns_token")
                .execute()
            logger.info("device token upserted")
        } catch {
            logger.error("upsertToken failed: \(error.localizedDescription)")
        }
    }
}
