import UIKit

/// Where the exercise is, in whatever form the record actually has it: a pin
/// when the organizer picked one on the map, otherwise the venue's name for a
/// maps app to search.
struct EventDirectionsDestination {
    let latitude: Double?
    let longitude: Double?
    let name: String
    /// The Hudhud place link the organizer pasted, when there is one.
    var mapLink: String? = nil

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
            // A venue known only by name still opens Hudhud, just without a
            // pin, because the person chose Hudhud and not another map.
            return hudhudURL(destination)

        case .googleMaps:
            if let appURL = googleMapsAppURL(destination),
               UIApplication.shared.canOpenURL(appURL) {
                return appURL
            }
            return googleMapsWebURL(destination)
        }
    }

    /// A pasted Hudhud place link (`l.hudhud.sa/p/{id}`) first, since it opens
    /// the named place. Then the app's own `hudhud://directions?to={lat},{lon}`
    /// for a pin, when the app is installed. Hudhud's web map otherwise. A pin
    /// sent as `l.hudhud.sa/directions/...` is not used: the app answers it
    /// with its "update the app" screen.
    func hudhudURL(_ destination: EventDirectionsDestination) -> URL? {
        if let link = destination.mapLink.flatMap(URL.init(string:)),
           link.host?.lowercased() == "l.hudhud.sa",
           link.path.hasPrefix("/p/") {
            return link
        }
        guard let coordinate = destination.coordinate else {
            return URL(string: "https://l.hudhud.sa/")
        }
        let pin = "\(coordinate.latitude),\(coordinate.longitude)"

        var app = URLComponents()
        app.scheme = "hudhud"
        app.host = "directions"
        app.queryItems = [URLQueryItem(name: "to", value: pin)]
        if let appURL = app.url, UIApplication.shared.canOpenURL(appURL) {
            return appURL
        }

        var web = URLComponents(string: "https://web.hudhud.sa/preview")
        web?.queryItems = [
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lng", value: String(coordinate.longitude))
        ]
        return web?.url
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
