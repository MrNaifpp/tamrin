import SwiftUI
import UIKit

enum PlayerCardShareDestination: String, CaseIterable, Identifiable {
    case instagram, instagramStory, snapchatStory, whatsapp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .instagram: String(localized: "إنستجرام")
        case .instagramStory: String(localized: "ستوري إنستجرام")
        case .snapchatStory: String(localized: "ستوري سناب")
        case .whatsapp: String(localized: "واتساب")
        }
    }
    var platform: String {
        switch self {
        case .instagram, .instagramStory: String(localized: "إنستجرام")
        case .snapchatStory: String(localized: "سناب شات")
        case .whatsapp: String(localized: "واتساب")
        }
    }
    var size: CGSize {
        switch self {
        case .instagram: CGSize(width: 1080, height: 1350)
        case .instagramStory, .snapchatStory: CGSize(width: 1080, height: 1920)
        case .whatsapp: CGSize(width: 1080, height: 1080)
        }
    }
    var dimensions: String { "\(Int(size.width)) × \(Int(size.height))" }
}

/// Platform canvases change, but the card composition and its aspect ratio do not.
struct PlayerCardExportView: View {
    let name: String
    let position: String
    let overall: Int
    let scores: PlayerRatingScores
    let portrait: UIImage
    let size: CGSize
    var change: PlayerRatingChange? = nil

    private var cardWidth: CGFloat {
        min(size.width - 300, (size.height - 280) * PlayerCardView.aspectRatio)
    }

    var body: some View {
        ZStack {
            Color(hex: 0x171918)
            VStack(spacing: 44) {
                Text("تمرين").font(TamrinFont.font(size: 42, weight: .bold)).foregroundStyle(.white)
                PlayerCardView(name: name, position: position, overall: overall, scores: scores,
                               portrait: Image(uiImage: portrait), change: change)
                    .frame(width: cardWidth, height: cardWidth / PlayerCardView.aspectRatio)
                Text("نلعبها سوا").font(TamrinFont.font(size: 27, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: size.width, height: size.height)
        .environment(\.locale, .tamrin)
        .environment(\.layoutDirection, .tamrin)
    }
}

struct PlayerCardSharePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Supported native hand-off. It never pretends that merely opening an app shares media.
struct PlayerCardShareSheet: UIViewControllerRepresentable {
    let payload: PlayerCardSharePayload
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [payload.image], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
