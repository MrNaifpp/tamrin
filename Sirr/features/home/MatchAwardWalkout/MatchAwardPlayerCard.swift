import SwiftUI
import UIKit

/// A nominee's rating, from the workspace's ratings or the demo's fixed numbers.
struct MatchAwardPlayerStats: Equatable {
    var overall: Int
    var scores: PlayerRatingScores
    var isKnown: Bool

    static let unknown = MatchAwardPlayerStats(overall: 50, scores: .neutral, isKnown: false)

    static func demoAsset(for player: MatchAwardPlayer, isDemo: Bool) -> String? {
        guard isDemo else { return nil }
        switch player.name {
        case "أحمد رشوان": return "MatchAwardDemoAhmed"
        case "لؤي الزهراني": return "MatchAwardDemoLoai"
        case "مراد الجهني": return "MatchAwardDemoMorad"
        default: return nil
        }
    }

    static func demo(for player: MatchAwardPlayer, isDemo: Bool) -> MatchAwardPlayerStats? {
        switch demoAsset(for: player, isDemo: isDemo) {
        case "MatchAwardDemoAhmed":
            return .init(overall: 74, scores: PlayerRatingScores(pace: 71, passing: 61, shooting: 63, stamina: 78, defending: 89, awareness: 63), isKnown: true)
        case "MatchAwardDemoLoai":
            return .init(overall: 82, scores: PlayerRatingScores(pace: 81, passing: 86, shooting: 91, stamina: 77, defending: 62, awareness: 85), isKnown: true)
        case "MatchAwardDemoMorad":
            return .init(overall: 82, scores: PlayerRatingScores(pace: 90, passing: 82, shooting: 84, stamina: 81, defending: 71, awareness: 83), isKnown: true)
        default:
            return nil
        }
    }

    @MainActor
    static func load(for player: MatchAwardPlayer, workspaceID: UUID?, isDemo: Bool) async -> MatchAwardPlayerStats {
        if let demo = demo(for: player, isDemo: isDemo) { return demo }
        guard !isDemo, let workspaceID, let userID = player.userId,
              let rating = try? await RatingService.shared.getPlayerRating(workspaceId: workspaceID, userId: userID)
        else { return .unknown }
        return .init(overall: rating.averageOverall ?? 50, scores: rating.average ?? .neutral,
                     isKnown: rating.average != nil)
    }
}

/// A nominee's card. `style: .award` is the green man-of-the-match card.
struct MatchAwardPlayerCard: View {
    enum Style { case standard, award }

    let player: MatchAwardPlayer
    var workspaceID: UUID?
    var isDemo = false
    var backgroundOnly = false
    var style: Style = .standard
    @State private var localPortrait: UIImage?
    @State private var stats: MatchAwardPlayerStats?

    static func aspectRatio(_ style: Style) -> CGFloat {
        style == .award ? MatchAwardCardView.aspectRatio : PlayerCardView.aspectRatio
    }

    private var demoAsset: String? { MatchAwardPlayerStats.demoAsset(for: player, isDemo: isDemo) }

    var body: some View {
        Group {
            if let demoAsset {
                card(Image(demoAsset))
            } else if let localPortrait {
                card(Image(uiImage: localPortrait))
            } else if let raw = player.portraitURL, let url = URL(string: raw) {
                AsyncImage(url: url) { phase in
                    card(phase.image)
                }
            } else {
                card(nil)
            }
        }
        .task(id: player.id) {
            localPortrait = PlayerCardLibrary.shared.portrait(for: player.userId)
            #if DEBUG
            // Demo portraits stay in the bundle and never generate paid images.
            if localPortrait == nil, let raw = player.avatarURL, let url = URL(string: raw), url.isFileURL {
                localPortrait = UIImage(contentsOfFile: url.path)
            }
            #endif
        }
        .task(id: workspaceID) {
            guard !backgroundOnly else { return }
            stats = await MatchAwardPlayerStats.load(for: player, workspaceID: workspaceID, isDemo: isDemo)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("بطاقة \(player.name)، \(PlayerCardView.positionTitle(player.position))")
    }

    @ViewBuilder
    private func card(_ portrait: Image?) -> some View {
        let stats = stats ?? MatchAwardPlayerStats.demo(for: player, isDemo: isDemo) ?? .unknown
        let rect: CGRect? = demoAsset != nil ? CGRect(x: 0.1, y: 0.045, width: 0.8, height: 0.875) : nil
        if backgroundOnly {
            GeometryReader { proxy in
                ZStack {
                    Color(white: 0.96)
                    if let portrait {
                        portrait.resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    }
                }
            }
        } else if style == .award {
            MatchAwardCardView(name: player.name, position: player.position, overall: stats.overall,
                               scores: stats.scores, portrait: portrait, showsScores: stats.isKnown,
                               portraitRect: rect)
                .overlay { placeholder(portrait) }
        } else {
            PlayerCardView(name: player.name, position: player.position, overall: stats.overall,
                           scores: stats.scores, portrait: portrait, showsScores: stats.isKnown,
                           portraitRect: rect)
                .overlay { placeholder(portrait) }
        }
    }

    @ViewBuilder
    private func placeholder(_ portrait: Image?) -> some View {
        if portrait == nil {
            Image(systemName: "person.fill")
                .resizable().scaledToFit()
                .foregroundStyle(style == .award ? .white.opacity(0.2) : .black.opacity(0.08))
                .padding(60).offset(y: -20).allowsHitTesting(false)
        }
    }
}
