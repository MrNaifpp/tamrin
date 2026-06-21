//
//  PushAppDelegate.swift
//  Sirr
//
//  APNs registration shim. The app is pure SwiftUI; remote-notification
//  callbacks only arrive through UIApplicationDelegate, so we adapt one in.
//

import UIKit
import UserNotifications
import os

private let pushLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "Push")

final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        pushLogger.info("APNs token registered (len: \(hex.count))")
        Task { await PushManager.shared.upsertToken(hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        pushLogger.error("APNs registration failed: \(error.localizedDescription)")
    }

    // Foreground presentation.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
