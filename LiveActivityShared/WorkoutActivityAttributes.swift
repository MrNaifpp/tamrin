import ActivityKit
import Foundation

/// The compact, Codable contract shared by the app and its Live Activity
/// extension. Keep server-independent values here so a future push-to-start
/// payload can use the same shape without importing any app-only models.
struct WorkoutActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        /// Unix time keeps the payload unambiguous across the app, widget, and
        /// any future APNs sender. The view converts it to `Date` for `.timer`.
        var startTimestamp: TimeInterval

        var startDate: Date {
            Date(timeIntervalSince1970: startTimestamp)
        }
    }

    let eventID: String
    let title: String
    let venueName: String
    let latitude: Double?
    let longitude: Double?

    var eventURL: URL? {
        URL(string: "sirr://event/\(eventID)")
    }

    var hasDirections: Bool {
        (latitude != nil && longitude != nil)
            || !venueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Route through Tamrin instead of opening Hudhud directly. The host app
    /// already knows how to validate Hudhud's scheme and fall back when the app
    /// isn't installed, while a widget extension can't call `canOpenURL`.
    var directionsURL: URL? {
        guard hasDirections else { return nil }

        var components = URLComponents()
        components.scheme = "sirr"
        components.host = "directions"

        var queryItems = [URLQueryItem(name: "provider", value: "hudhud")]
        if let latitude, let longitude {
            queryItems.append(URLQueryItem(name: "lat", value: String(latitude)))
            queryItems.append(URLQueryItem(name: "lon", value: String(longitude)))
        }

        let trimmedName = venueName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            queryItems.append(URLQueryItem(name: "name", value: trimmedName))
        }

        components.queryItems = queryItems
        return components.url
    }
}
