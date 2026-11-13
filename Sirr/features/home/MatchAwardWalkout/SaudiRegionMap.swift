import SwiftUI

/// The thirteen Saudi regions, simplified from OpenStreetMap boundaries
/// (© OpenStreetMap contributors, ODbL). Points are Web Mercator in 0…1.
struct SaudiRegionMap: Sendable {
    struct Region: Identifiable, Sendable {
        let id: String
        let label: String
        let rings: [[CGPoint]]
        let bounds: CGRect
    }

    let country: [[CGPoint]]
    let countryBounds: CGRect
    let regions: [Region]

    static let shared: SaudiRegionMap = load()

    func region(_ id: String?) -> Region? { regions.first { $0.id == id } }

    static func label(for id: String?) -> String? { shared.region(id)?.label }

    private struct File: Decodable {
        struct Item: Decodable { let id: String; let label: String; let rings: [[[Double]]] }
        let country: [[[Double]]]
        let regions: [Item]
    }

    private static func load() -> SaudiRegionMap {
        guard let url = Bundle.main.url(forResource: "SaudiRegions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return SaudiRegionMap(country: [], countryBounds: .zero, regions: [])
        }
        let country = file.country.map(project)
        return SaudiRegionMap(
            country: country, countryBounds: bounds(country),
            regions: file.regions.map { item in
                let rings = item.rings.map(project)
                return Region(id: item.id, label: item.label, rings: rings, bounds: bounds(rings))
            })
    }

    private static func project(_ ring: [[Double]]) -> [CGPoint] {
        ring.map { point in
            let lat = min(max(point[1], -85.05), 85.05) * .pi / 180
            return CGPoint(x: (point[0] + 180) / 360,
                           y: (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2)
        }
    }

    private static func bounds(_ rings: [[CGPoint]]) -> CGRect {
        let points = rings.flatMap { $0 }
        guard let first = points.first else { return .zero }
        var rect = CGRect(origin: first, size: .zero)
        for point in points { rect = rect.union(CGRect(origin: point, size: .zero)) }
        return rect
    }
}

/// Rings drawn through a camera: `center` in map units lands mid-rect,
/// one map unit is `scale` points.
struct MapRingsShape: Shape {
    let rings: [[CGPoint]]
    var center: CGPoint
    var scale: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { .init(.init(center.x, center.y), scale) }
        set { center = CGPoint(x: newValue.first.first, y: newValue.first.second); scale = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for ring in rings {
            guard let first = ring.first else { continue }
            path.move(to: map(first, rect))
            for point in ring.dropFirst() { path.addLine(to: map(point, rect)) }
            path.closeSubpath()
        }
        return path
    }

    private func map(_ point: CGPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX + (point.x - center.x) * scale, y: rect.midY + (point.y - center.y) * scale)
    }
}

extension SaudiRegionMap {
    /// Camera that fits `bounds` into `size` with some breathing room.
    static func camera(fitting bounds: CGRect, in size: CGSize, fill: CGFloat = 0.82) -> (center: CGPoint, scale: CGFloat) {
        let width = max(bounds.width, 0.000001), height = max(bounds.height, 0.000001)
        return (CGPoint(x: bounds.midX, y: bounds.midY),
                min(size.width * fill / width, size.height * fill / height))
    }
}
