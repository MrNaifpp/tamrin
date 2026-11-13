import SwiftUI
import UIKit
import CoreText

/// The man-of-the-match card: the player card's layout in green, over the
/// rising arrow. Figma cSWIOqMrkJHwZpXXnrnJlM / 948:29684, in its own canvas units.
struct MatchAwardCardView: View {
    let name: String
    let position: String
    let overall: Int
    let scores: PlayerRatingScores
    var portrait: Image?
    var showsScores: Bool = true
    var portraitRect: CGRect? = nil

    static let designSize = CGSize(width: 486.82, height: 669.6)
    static let aspectRatio = designSize.width / designSize.height
    static let green = Color(hex: 0x18B44C)
    private static let panelHeight: CGFloat = 223
    private static let corner: CGFloat = 60.852

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / Self.designSize.width,
                            proxy.size.height / Self.designSize.height)
            card
                .scaleEffect(scale, anchor: .center)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        // A fixed artwork composition, like the regular card.
        .environment(\.layoutDirection, .leftToRight)
        .dynamicTypeSize(.large)
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            header
            statsPanel
                .offset(y: Self.designSize.height - Self.panelHeight)
        }
        .frame(width: Self.designSize.width, height: Self.designSize.height)
        .clipShape(.rect(cornerRadius: Self.corner, style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 91.279 / 2)
    }

    private var backdrop: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Self.green, .white], startPoint: .top, endPoint: .bottom)
            MatchAwardArrow()
                .fill(Self.green.opacity(0.15)
                    .shadow(.inner(color: .black.opacity(0.25), radius: 5.685, y: 2.843)))
                .frame(width: 356, height: 355.019)
                .offset(x: 65, y: 53)
            if let portrait {
                if let rect = portraitRect {
                    portrait.resizable().scaledToFit()
                        .frame(width: Self.designSize.width * rect.width,
                               height: Self.designSize.height * rect.height)
                        .position(x: Self.designSize.width * rect.midX,
                                  y: Self.designSize.height * rect.midY)
                } else {
                    portrait.resizable().scaledToFill()
                        .frame(width: 498, height: 663)
                        .offset(x: (Self.designSize.width - 498) / 2 - 5.41, y: 28)
                }
            }
        }
        .frame(width: Self.designSize.width, height: Self.designSize.height, alignment: .topLeading)
        .clipped()
    }

    private var header: some View {
        ZStack(alignment: .topLeading) {
            Text(showsScores ? overall.tamrinNumber : "—")
                .font(Self.thmanyah(size: 91.279))
                .foregroundStyle(Color(hex: 0xCEF3DA))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 150, height: 120)
                .position(x: 93, y: 13 + 60)

            VStack(alignment: .trailing, spacing: 10.503) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array(nameLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(Self.thmanyah(size: 40))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .frame(height: 54.767)
                    }
                }
                Text(displayPosition)
                    .font(Self.thmanyah(size: 30.426, medium: true))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .frame(height: 54.767)
            }
            .multilineTextAlignment(.trailing)
            .frame(width: 196.249, alignment: .trailing)
            .offset(x: Self.designSize.width - 36.51 - 196.249, y: 30.43)
        }
    }

    private var nameLines: [String] {
        let parts = name.split(whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { return [""] }
        return parts.count > 1 ? [String(first), parts.dropFirst().joined(separator: " ")] : [String(first)]
    }

    private var sport: RatingSport { PlayerPosition.exact(from: position)?.sport ?? .football }

    private var displayPosition: String {
        position == "وسط" ? String(localized: "وســط") : PlayerCardView.positionTitle(position)
    }

    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 42.6, bottomLeadingRadius: 0,
                               bottomTrailingRadius: 0, topTrailingRadius: 42.6,
                               style: .continuous)
    }

    private var statsPanel: some View {
        ZStack(alignment: .top) {
            // Blur the card's own backdrop so the panel also renders in ImageRenderer.
            backdrop
                .blur(radius: 60.852 / 2)
                .offset(y: -(Self.designSize.height - Self.panelHeight))
                .frame(width: Self.designSize.width, height: Self.panelHeight, alignment: .top)
            Color(red: 16 / 255, green: 145 / 255, blue: 59 / 255).opacity(0.4)
            HStack(alignment: .top, spacing: 73.023) {
                ForEach(Array(PlayerCardView.statColumns(for: sport).enumerated()), id: \.offset) { _, column in
                    statColumn(column.0, column.1)
                }
            }
            .padding(.top, 21)
        }
        .frame(width: Self.designSize.width, height: Self.panelHeight, alignment: .top)
        .clipShape(panelShape)
        .background {
            panelShape.fill(Self.green.opacity(0.4))
                .shadow(color: .black.opacity(0.13), radius: 91.279 / 2, y: -12.17)
        }
    }

    private func statColumn(_ top: PlayerAttribute, _ bottom: PlayerAttribute) -> some View {
        VStack(spacing: 10.503) {
            stat(top)
            stat(bottom)
        }
    }

    private func stat(_ attribute: PlayerAttribute) -> some View {
        VStack(spacing: 5.251) {
            Text(attribute.cardLabel)
                .font(.custom("TheYearofHandicrafts-Regular", fixedSize: 21.005))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize()
                .frame(height: 36.5)
            Text(showsScores ? scores[attribute].tamrinNumber : "—")
                .font(.custom("IBMPlexSansArabic-SemiBold", fixedSize: 31.508))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize()
                .frame(height: 42.6)
        }
    }

    private static func thmanyah(size: CGFloat, medium: Bool = false) -> Font {
        guard let base = UIFont(name: medium ? "thmanyahsans-Medium" : "thmanyahsans-Bold", size: size) else {
            return .custom(medium ? "thmanyahsans-Medium" : "thmanyahsans-Bold", fixedSize: size)
        }
        let features: [[UIFontDescriptor.FeatureKey: Any]] = [
            [UIFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureTag as String): "salt",
             UIFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureValue as String): 1]
        ]
        return Font(UIFont(descriptor: base.fontDescriptor.addingAttributes([.featureSettings: features]),
                           size: size) as CTFont)
    }
}

/// The rising arrow behind the player, path taken from the Figma vector.
struct MatchAwardArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 356, sy = rect.height / 355.019
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(356, 196.194))
        path.addLine(to: p(252.741, 196.194))
        path.addLine(to: p(252.741, 355.019))
        path.addLine(to: p(103.26, 355.019))
        path.addLine(to: p(103.26, 196.194))
        path.addLine(to: p(0, 196.194))
        path.addLine(to: p(178, 0))
        path.closeSubpath()
        return path
    }
}

extension PlayerAttribute {
    /// The card's lettering, stretched with kashida.
    var cardLabel: String {
        switch self {
        case .pace: String(localized: "السرعــة")
        case .passing: String(localized: "التمريــر")
        case .shooting: String(localized: "التسديــد")
        case .stamina: String(localized: "اللياقــة")
        case .defending: String(localized: "الدفــاع")
        case .awareness: String(localized: "وعي كروي")
        case .receiving: String(localized: "الاستقبال")
        case .setting: String(localized: "الإعــداد")
        case .attacking: String(localized: "الهجــوم")
        case .blocking: String(localized: "الصــد")
        case .serving: String(localized: "الإرســال")
        case .courtAwareness: String(localized: "الوعــي")
        }
    }
}
