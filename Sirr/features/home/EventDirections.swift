import UIKit

/// Where the exercise is, in whatever form the record actually has it: a pin
/// when the organizer picked one on the map, otherwise the venue's name for a
/// maps app to search.
struct EventDirectionsDestination {
    let latitude: Double?
    let longitude: Double?
    let name: String

    var coordinate: (latitude: Double, longitude: Double)? {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
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

    /// Every route lands somewhere useful whether or not the app is installed.
    func url(for destination: EventDirectionsDestination) -> URL? {
        switch self {
        case .hudhud:
            // Hudhud's own link: iOS hands it straight to the Hudhud app when
            // it is installed, and to Hudhud's web map otherwise. A venue known
            // only by name still opens Hudhud, just without a pin, because the
            // person chose Hudhud and not another map.
            return hudhudURL(destination)

        case .googleMaps:
            if let appURL = googleMapsAppURL(destination),
               UIApplication.shared.canOpenURL(appURL) {
                return appURL
            }
            return googleMapsWebURL(destination)
        }
    }

    /// `https://l.hudhud.sa/directions/{lat},{lon}`: the link the Hudhud app
    /// itself claims (apple-app-site-association on l.hudhud.sa, every path).
    func hudhudURL(_ destination: EventDirectionsDestination) -> URL? {
        guard let coordinate = destination.coordinate else {
            return URL(string: "https://l.hudhud.sa/")
        }
        return URL(string: "https://l.hudhud.sa/directions/\(coordinate.latitude),\(coordinate.longitude)")
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
