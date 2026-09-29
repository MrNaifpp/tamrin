import Foundation

/// Public web host for Universal Links. The same host must serve
/// `/.well-known/apple-app-site-association` and be listed as an
/// `applinks:` associated domain in `Sirr.entitlements`.
enum AppLinks {
    static let host = "https://tamrien.app"

    /// `https://tamrien.app/event/{uuid}` — opens the event in the app.
    static func eventURL(_ id: UUID) -> URL {
        URL(string: "\(host)/event/\(id.uuidString)")!
    }

    /// `https://tamrien.app/join/{code}` — workspace invite.
    static func joinURL(_ code: String) -> URL {
        URL(string: "\(host)/join/\(code)")!
    }
}
