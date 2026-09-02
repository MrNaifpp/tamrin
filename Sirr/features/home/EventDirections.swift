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
        return trimmed
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
            return customSchemeURL(
                scheme: "hudhud",
                queryItems: [
                    URLQueryItem(name: "lat", value: String(coordinate.latitude)),
                    URLQueryItem(name: "lon", value: String(coordinate.longitude))
                ]
            )
        }
        guard let query = destination.query else { return nil }
        return customSchemeURL(
            scheme: "hudhud",
            queryItems: [URLQueryItem(name: "q", value: query)]
        )
    }

    private func googleMapsAppURL(_ destination: EventDirectionsDestination) -> URL? {
        let destinationValue: String
        if let coordinate = destination.coordinate {
            destinationValue = "\(coordinate.latitude),\(coordinate.longitude)"
        } else if let query = destination.query {
            destinationValue = query
        } else {
            return nil
        }
        return customSchemeURL(
            scheme: "comgooglemaps",
            queryItems: [
                URLQueryItem(name: "daddr", value: destinationValue),
                URLQueryItem(name: "directionsmode", value: "driving")
            ]
        )
    }

    private func googleMapsWebURL(_ destination: EventDirectionsDestination) -> URL? {
        let destinationValue: String
        if let coordinate = destination.coordinate {
            destinationValue = "\(coordinate.latitude),\(coordinate.longitude)"
        } else if let query = destination.query {
            destinationValue = query
        } else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/maps/dir/"
        components.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: destinationValue)
        ]
        return components.url
    }

    private func customSchemeURL(
        scheme: String,
        queryItems: [URLQueryItem]
    ) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.queryItems = queryItems
        return components.url
    }
}
