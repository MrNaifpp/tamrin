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
    /// The app's language when the activity was requested ("ar" or "en").
    /// The extension has no string catalog and need not share the app's
    /// per-app language, so it picks its copy and direction from this.
    /// Defaults to Arabic, which is also what a payload without it decodes to.
    var languageCode: String = "ar"

    var isArabic: Bool { !languageCode.hasPrefix("en") }

    var eventURL: URL? {
        URL(string: "sirr://event/\(eventID)")
    }

    var hasDirections: Bool {
        (latitude != nil && longitude != nil)
            || !venueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Route through Tamrin instead of opening Hudhud directly. The host app
    /// builds Hudhud's link from whatever the venue record has, which a widget
    /// extension has no way to decide.
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

extension WorkoutActivityAttributes {
    private enum CodingKeys: String, CodingKey {
        case eventID, title, venueName, latitude, longitude, languageCode
    }

    /// Written out so a payload from before `languageCode` existed still
    /// decodes, as Arabic.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try container.decode(String.self, forKey: .eventID)
        title = try container.decode(String.self, forKey: .title)
        venueName = try container.decode(String.self, forKey: .venueName)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode) ?? "ar"
    }
}
