import SwiftUI
import UIKit
import CoreText

/// Shared by the profile, player details and image exports.
/// Figma cSWIOqMrkJHwZpXXnrnJlM / 506:16505, in its original canvas units.
struct PlayerCardView: View {
    let name: String
    let position: String
    let overall: Int
    let scores: PlayerRatingScores
    var portrait: Image?
    var showsScores: Bool = true
    var change: PlayerRatingChange? = nil
    /// Optional normalized placement for a cutout source; saved portraits
    /// already contain the full canvas and keep the default behavior.
    var portraitRect: CGRect? = nil

    static let designSize = CGSize(width: 370.8218078613281, height: 509.8800048828125)
    static let aspectRatio = designSize.width / designSize.height
    private static let panelHeight: CGFloat = 208.5872802734375
    private static let panelTop: CGFloat = 301.29412841796875

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / Self.designSize.width,
                            proxy.size.height / Self.designSize.height)
            card
                .scaleEffect(scale, anchor: .center)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        // This is a fixed artwork composition, including its exported image.
        .environment(\.layoutDirection, .leftToRight)
        .dynamicTypeSize(.large)
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            header
            statsPanel
                .offset(y: Self.panelTop)
        }
        .frame(width: Self.designSize.width, height: Self.designSize.height)
        .clipShape(.rect(cornerRadius: 46.352725982666, style: .continuous))
        .compositingGroup()
        // Figma's drop-shadow blur is a diameter; SwiftUI takes its radius.
        .shadow(color: .black.opacity(0.05), radius: 69.529 / 2)
    }

    private var backdrop: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.9599999785423279)
            if let portrait {
                if let rect = portraitRect {
                    portrait.resizable().scaledToFit()
                        .frame(width: Self.designSize.width * rect.width,
                               height: Self.designSize.height * rect.height)
                        .position(x: Self.designSize.width * rect.midX,
                                  y: Self.designSize.height * rect.midY)
                } else {
                    portrait
                        .resizable()
                        .frame(width: Self.designSize.width, height: Self.designSize.height)
                        .clipped()
                        .shadow(color: .black.opacity(0.05), radius: 69.529 / 2, y: 4.635)
                }
            }
        }
        .frame(width: Self.designSize.width, height: Self.designSize.height)
    }

    private var header: some View {
        ZStack(alignment: .topLeading) {
            Text(showsScores ? overall.tamrinNumber : "—")
                .font(Self.font("IBMPlexSansArabic-Medium", size: 69.529))
                .foregroundStyle(Color(hex: 0xAA9252).opacity(0.65)
                    .shadow(.inner(color: .black.opacity(0.25), radius: 4.635272979736328 / 2,
                                   y: 1.158818244934082)))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 84, height: 104, alignment: .trailing)
                .offset(x: 28.969703674316406, y: 12.748406410217285)

            if let change {
                RatingChangeIndicator(change: change, compact: true, onLightArtwork: true, interactive: false)
                    .frame(width: 84)
                    .offset(x: 28.97, y: 109)
            }

            VStack(alignment: .trailing, spacing: 13.90582275390625) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array(nameLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(Self.nameFont)
                            .foregroundStyle(.black.opacity(0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .frame(height: 42)
                    }
                }
                .frame(height: 84, alignment: .top)
                Text(displayPosition)
                    .font(Self.font("TheYearofHandicrafts-SemiBold", size: 23.176))
                    .foregroundStyle(.black.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: 42)
            }
            .multilineTextAlignment(.trailing)
            .frame(width: 149.487548828125, alignment: .trailing)
            .offset(x: 193.521484375, y: 22.1796875)
        }
    }

    private var nameLines: [String] {
        let parts = name.split(whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { return [""] }
        return parts.count > 1 ? [String(first), parts.dropFirst().joined(separator: " ")] : [String(first)]
    }

    /// Positions are stored in Arabic («حارس», «دفاع», «وسط», «هجوم»); this is
    /// only their display. Anything else is shown as stored.
    static func positionTitle(_ position: String) -> String {
        PlayerPosition.exact(from: position)?.title ?? position
    }

    private var displayPosition: String {
        // The card's own lettering stretches «وسط» with kashida.
        position == "وسط" ? String(localized: "وســط") : Self.positionTitle(position)
    }

    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 32.4469, bottomLeadingRadius: 0,
                               bottomTrailingRadius: 0, topTrailingRadius: 32.4469,
                               style: .continuous)
    }

    private var statsPanel: some View {
        ZStack(alignment: .topLeading) {
            // Blur the actual card backdrop. Unlike a system material, this
            // preserves the specified radius/tint and renders in ImageRenderer.
            backdrop
                .blur(radius: 46.353)
                .offset(y: -Self.panelTop)
            Color(white: 0.9895344972610474).opacity(0.8)
            HStack(alignment: .top, spacing: 55.62327575683594) {
                statColumn(.shooting, .awareness, width: 67, alignment: .trailing)
                statColumn(.passing, .defending, width: 51, alignment: .center)
                statColumn(.pace, .stamina, width: 50, alignment: .center)
            }
            .offset(x: 45.20746994018555, y: 27.071353912353516)
        }
        .frame(width: Self.designSize.width, height: Self.panelHeight, alignment: .topLeading)
        .clipShape(panelShape)
        .background {
            panelShape
                .fill(Color(white: 0.9895344972610474).opacity(0.8))
                .shadow(color: .black.opacity(0.13), radius: 69.529 / 2, y: -9.271)
        }
    }

    private func statColumn(_ top: PlayerAttribute, _ bottom: PlayerAttribute,
                            width: CGFloat, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 23.17636) {
            stat(top)
            stat(bottom)
        }
        .frame(width: width)
    }

    private func stat(_ attribute: PlayerAttribute) -> some View {
        VStack(spacing: 4.63527297973633) {
            Text(Self.label(attribute))
                .font(Self.font("TheYearofHandicrafts-Regular", size: 18.541))
                .foregroundStyle(.black.opacity(0.4))
                .fixedSize()
                .frame(height: 28)
            Text(showsScores ? scores[attribute].tamrinNumber : "—")
                .font(Self.font("IBMPlexSansArabic-SemiBold", size: 27.812))
                .foregroundStyle(.black.opacity(0.75))
                .fixedSize()
                .frame(height: 33)
        }
    }

    private static func label(_ attribute: PlayerAttribute) -> String {
        switch attribute {
        case .pace: String(localized: "السرعــة")
        case .passing: String(localized: "التمريــر")
        case .shooting: String(localized: "التسديــد")
        case .stamina: String(localized: "اللياقــة")
        case .defending: String(localized: "الدفــاع")
        case .awareness: String(localized: "وعي كروي")
        }
    }

    private static func font(_ name: String, size: CGFloat) -> Font {
        .custom(name, fixedSize: size)
    }

    private static var nameFont: Font {
        guard let base = UIFont(name: "thmanyahsans-Bold", size: 32.447) else {
            preconditionFailure("Missing bundled player-card Thmanyah font")
        }
        let features: [[UIFontDescriptor.FeatureKey: Any]] = [
            [.type: kStylisticAlternativesType, .selector: kStylisticAltOneOnSelector],
            [UIFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureTag as String): "salt",
             UIFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureValue as String): 1]
        ]
        return Font(UIFont(descriptor: base.fontDescriptor.addingAttributes([.featureSettings: features]),
                           size: 32.447) as CTFont)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
