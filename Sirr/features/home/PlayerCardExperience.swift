import SwiftUI
import UIKit
import ImageIO
import Observation

/// Test portraits are local, partitioned by account, and never sent to a provider.
@MainActor @Observable
final class PlayerCardLibrary {
    static let shared = PlayerCardLibrary()
    @ObservationIgnored private var portraits: [UUID: UIImage] = [:]
    @ObservationIgnored private var loaded: Set<UUID> = []
    private var revision = 0

    func portrait(for id: UUID?) -> UIImage? {
        _ = revision
        guard let id else { return nil }
        if !loaded.contains(id) {
            loaded.insert(id)
            if let url = try? fileURL(id), let data = try? Data(contentsOf: url) {
                portraits[id] = UIImage(data: data)
            } else if let url = try? fileURL(id, legacy: true),
                      let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                portraits[id] = PlayerPortraitLayout.migrateLegacy(image)
            }
        }
        return portraits[id]
    }

    func save(_ image: UIImage, for id: UUID) throws {
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: fileURL(id), options: [.atomic, .completeFileProtection])
        portraits[id] = image
        loaded.insert(id)
        revision += 1
    }

    private func fileURL(_ id: UUID, legacy: Bool = false) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PlayerCardPortraits", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(id.uuidString + (legacy ? "" : ".canvas")).appendingPathExtension("png")
    }

    nonisolated static func decode(_ data: Data) -> UIImage? {
        guard data.count <= 25 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct PlayerCardThumbnail: View {
    let name: String
    let position: String
    var overall: Int = LineupStrength.neutral
    var scores: PlayerRatingScores = .neutral
    var portrait: UIImage?
    var showsScores: Bool = true
    var change: PlayerRatingChange? = nil
    var create: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var hidesThumbnail = false

    private var card: PlayerCardView {
        PlayerCardView(name: name, position: position, overall: overall, scores: scores,
                       portrait: portrait.map { Image(uiImage: $0) }, showsScores: showsScores, change: change)
    }

    var body: some View {
        VStack(spacing: 10) {
            Button {
                if portrait == nil, let create { create() } else { isExpanded = true }
            } label: {
                card
                    .frame(width: 150, height: 150 / PlayerCardView.aspectRatio)
                    .modifier(PlayerCardIdleMotion(paused: isExpanded || reduceMotion))
                    .opacity(hidesThumbnail ? 0 : 1)
                    .transaction { $0.animation = nil }
            }
            .buttonStyle(.plain)
            .background {
                PlayerCardZoomPresenter(isPresented: $isExpanded, hidesThumbnail: $hidesThumbnail,
                                        card: card, reduceMotion: reduceMotion, edit: create)
            }
            .accessibilityLabel(portrait == nil && create != nil ? String(localized: "أنشئ بطاقتك") : String(localized: "تكبير بطاقة \(name)"))
            .accessibilityIdentifier("player-card-thumbnail")
            .contextMenu {
                if portrait != nil, let create {
                    Button("اختيار صورة جديدة للبطاقة", systemImage: "photo", action: create)
                }
            }
            if portrait == nil, let create {
                Button("أنشئ بطاقتك", action: create).font(TamrinFont.font(size: 14, weight: .medium))
            }
        }
    }
}

private struct PlayerCardIdleMotion: ViewModifier {
    let paused: Bool
    @State private var origin = Date()

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { timeline in
            let t = paused ? 0 : timeline.date.timeIntervalSince(origin)
            content
                .overlay {
                    LinearGradient(colors: [.clear, .white.opacity(0.045 + 0.035 * sin(t * 0.65)), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .clipShape(.rect(cornerRadius: 150 * 46.3527 / PlayerCardView.designSize.width))
                        .allowsHitTesting(false)
                }
                .rotation3DEffect(.degrees(sin(t * 0.72) * 1.6), axis: (x: 1, y: 0, z: 0), perspective: 0.3)
                .rotation3DEffect(.degrees(sin(t * 0.51) * 2.2), axis: (x: 0, y: 1, z: 0), perspective: 0.3)
        }
    }
}

struct PlayerCardParticles: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var origin = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSince(origin)
            Canvas { context, size in
                for i in 0..<38 {
                    let seed = Double(i)
                    let angle = seed * 2.39996 + t * (0.3 + Double(i % 5) * 0.025)
                    let radius = 12 + Double(i % 9) * 7 + sin(t * 0.7 + seed) * 12
                    let x = size.width / 2 + cos(angle) * radius
                    let y = size.height / 2 + sin(angle) * radius * 0.7
                    let dot = 2 + Double(i % 4)
                    var glow = context
                    glow.addFilter(.blur(radius: i % 3 == 0 ? 3 : 0.5))
                    glow.opacity = 0.35 + (sin(t + seed) + 1) * 0.3
                    glow.fill(Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot)), with: .color(.white))
                }
            }
        }.frame(width: 220, height: 180).accessibilityHidden(true)
    }
}
