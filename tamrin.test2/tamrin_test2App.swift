import SwiftUI
import SwiftData
import UserNotifications

extension Notification.Name { static let openTamrinOccurrence = Notification.Name("openTamrinOccurrence") }

final class TamrinAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["occurrenceID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run { NotificationCenter.default.post(name: .openTamrinOccurrence, object: id) }
    }
}

@main
struct tamrin_test2App: App {
    @UIApplicationDelegateAdaptor(TamrinAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, Locale(identifier: "ar_SA"))
                .environment(\.layoutDirection, .rightToLeft)
                .tint(.primary)
        }
        .modelContainer(for: [
            UserProfile.self, Team.self, Membership.self, TrainingPlan.self,
            Occurrence.self, Registration.self, PaymentMethod.self,
            PaymentRecord.self, Invite.self, AppNotification.self
        ])
    }
}
