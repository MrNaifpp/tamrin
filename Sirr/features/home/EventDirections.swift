import UIKit

/// Where the exercise is, in whatever form the record actually has it: a pin
/// when the organizer picked one on the map, otherwise the venue's name for a
/// maps app to search.
struct EventDirectionsDestination {
    let latitude: Double?
    let longitude: Double?
    let name: String

    var coordinate: (latitude: Double, longitude: Double)? {
        guard let latitude, let longitude else { return nil }
        return (latitude, longitude)
    }

    var query: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }
}

/// The map apps a group around here actually navigates with.
enum EventDirectionsProvider {
    case hudhud
    case googleMaps

    /// Falls back to the web when the app itself is not installed, so the tap
    /// always lands somewhere useful.
    func url(for destination: EventDirectionsDestination) -> URL? {
        switch self {
        case .hudhud:
            if let appURL = hudhudAppURL(destination),
               UIApplication.shared.canOpenURL(appURL) {
                return appURL
            }
            return URL(string: "https://apps.apple.com/app/id6477774492")

        case .googleMaps:
            if let appURL = googleMapsAppURL(destination),
               UIApplication.shared.canOpenURL(appURL) {
                return appURL
            }
            return googleMapsWebURL(destination)
        }
    }

    /// NOTE: Hudhud does not publish a URL-scheme reference, so this is the
    /// conventional `scheme://?lat=&lon=` shape rather than a documented one.
    /// `canOpenURL` gates it: if the scheme is wrong — or the app simply is not
    /// installed — the caller falls through to the App Store instead.
    private func hudhudAppURL(_ destination: EventDirectionsDestination) -> URL? {
        if let coordinate = destination.coordinate {
            return URL(string: "hudhud://?lat=\(coordinate.latitude)&lon=\(coordinate.longitude)")
        }
        guard let query = destination.query else { return nil }
        return URL(string: "hudhud://?q=\(query)")
    }

    private func googleMapsAppURL(_ destination: EventDirectionsDestination) -> URL? {
        if let coordinate = destination.coordinate {
            return URL(string: "comgooglemaps://?daddr=\(coordinate.latitude),\(coordinate.longitude)&directionsmode=driving")
        }
        guard let query = destination.query else { return nil }
        return URL(string: "comgooglemaps://?daddr=\(query)&directionsmode=driving")
    }

    private func googleMapsWebURL(_ destination: EventDirectionsDestination) -> URL? {
        if let coordinate = destination.coordinate {
            return URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(coordinate.latitude),\(coordinate.longitude)")
        }
        guard let query = destination.query else { return nil }
        return URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(query)")
    }
}
