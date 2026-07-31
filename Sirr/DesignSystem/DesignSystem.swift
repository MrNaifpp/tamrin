import SwiftUI
import CoreText
import UIKit

enum TamrinFontWeight {
    case light, regular, medium, bold

    var postScriptName: String {
        switch self {
        case .light: "Thmanyahsans12-Light"
        case .regular: "Thmanyahsans12-Regular"
        case .medium: "Thmanyahsans12-Medium"
        case .bold: "Thmanyahsans12-Bold"
        }
    }

    init(_ weight: Font.Weight) {
        switch weight {
        case .ultraLight, .thin, .light:
            self = .light
        case .medium:
            self = .medium
        case .semibold, .bold, .heavy, .black:
            self = .bold
        default:
            self = .regular
        }
    }
}

enum TamrinFont {
    /// Thmanyah's identity alternates. CoreText enables Arabic shaping,
    /// ligatures, kerning and marks automatically; `ss01` is the intentional
    /// brand alternate and must stay enabled everywhere text is rendered.
    private static let brandFeatures: [[UIFontDescriptor.FeatureKey: Any]] = [
        [
            .type: kStylisticAlternativesType,
            .selector: kStylisticAltOneOnSelector
        ]
    ]

    static func uiFont(size: CGFloat, weight: TamrinFontWeight = .regular) -> UIFont {
        guard let base = UIFont(name: weight.postScriptName, size: size) else {
            preconditionFailure("Missing bundled Thmanyah font: \(weight.postScriptName)")
        }
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: brandFeatures
        ])
        let result = UIFont(descriptor: descriptor, size: size)
        precondition(
            result.fontName == weight.postScriptName,
            "Unexpected font fallback: \(result.fontName)"
        )
        return result
    }

    static func font(size: CGFloat, weight: TamrinFontWeight = .regular) -> Font {
        Font(uiFont(size: size, weight: weight) as CTFont)
    }

    static let body = font(size: 17, weight: .regular)
    static let caption = font(size: 12, weight: .medium)
    static let footnote = font(size: 13, weight: .regular)
    static let subheadline = font(size: 15, weight: .regular)
    static let headline = font(size: 17, weight: .medium)
    static let title3 = font(size: 20, weight: .bold)
    static let title2 = font(size: 24, weight: .bold)
    static let title = font(size: 30, weight: .bold)
    static let largeTitle = font(size: 40, weight: .bold)
    static let display = font(size: 46, weight: .bold)
}

extension View {
    func tamrinTypography() -> some View {
        self
            .font(TamrinFont.body)
            .dynamicTypeSize(.xSmall ... .accessibility3)
    }
}

enum TamrinTheme {
    /// Surfaces are intentionally neutral. Any warm (beige / olive) cast makes
    /// the photographic artwork behind Home read as muddy brown, so greys here
    /// stay on the achromatic axis and colour comes only from `lime`.
    ///
    /// **No surface is ever pure black in dark mode.** The deepest tone in the
    /// app is `surfaceFloor`, ten steps (10/255) above black; every other
    /// surface is a lighter step on the same neutral ramp. That keeps layered
    /// surfaces — drawer, page, card, sheet — readable against one another
    /// instead of collapsing into one flat void.
    ///
    /// The one exception is black inside a `mask`, where it is the alpha
    /// channel rather than a colour and must stay pure.
    static let surfaceFloor = Color(white: 10.0 / 255.0)

    static let page = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.058, alpha: 1)
            : UIColor(white: 0.953, alpha: 1)
    })
    /// A presented sheet floats above `page`, so in dark mode it steps up from
    /// it — painting a sheet at `page` makes it read as an unlit hole.
    static let sheet = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.12, alpha: 1)
            : UIColor(white: 0.953, alpha: 1)
    })
    /// A card raised above `page` or `sheet`.
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.19, alpha: 1)
            : .systemBackground
    })
    /// Near-opaque chrome that floats over artwork (toasts, pills). Fixed dark
    /// because its content is always white, but still off pure black.
    static let floatingChrome = Color(white: 0.11)
    /// Input fields, chips and unselected controls. Must clear `sheet` by a
    /// visible margin, since that is what it usually sits on.
    static let secondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.24, alpha: 1)
            : UIColor(white: 0.917, alpha: 1)
    })
    static let glass = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.20, alpha: 0.95)
            : UIColor(white: 1, alpha: 0.74)
    })
    /// Fixed near-black: used both as a filled surface (with white content on
    /// top) and as the text colour over `lime` / white, so it must not invert.
    static let ink = Color(white: 0.078)
    static let lime = Color(red: 0.76, green: 0.92, blue: 0.39)
    /// اللون الأخضر المستخدم كلَكْنة في ملف Figma (العناوين والحالات الإيجابية).
    static let brandGreen = Color(red: 0.34, green: 0.73, blue: 0.47)
    static let mint = Color(red: 0.62, green: 0.86, blue: 0.72)
    static let peach = Color(red: 0.98, green: 0.76, blue: 0.61)
    static let corner: CGFloat = 24
}

/// Shared control sizing for the iOS 26 interface. Native controls use the
/// system's regular size; custom actions stay compact while preserving at
/// least Apple's 44pt touch target.
enum TamrinControlMetrics {
    static let touchTarget: CGFloat = 44
    /// Content frame inside iOS 26 glass chrome (the style adds its own inset).
    static let glassIconContent: CGFloat = 36
    static let glassActionHeight: CGFloat = 40
    static let actionHeight: CGFloat = 50
    static let roundButton: CGFloat = 50
    static let symbolSize: CGFloat = 18
}

/// الخلفية الفوتوغرافية المموهة المشتركة في شاشات Figma.
/// الصورة تبقى ديكورًا فقط، بينما طبقة التعتيم تضمن وضوح النص في الوضعين.
struct TamrinPhotoBackdrop: View {
    var imageName = "ExerciseArt1"
    var dimming: Double = 0.32

    var body: some View {
        GeometryReader { proxy in
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .blur(radius: 46, opaque: true)
                .scaleEffect(1.22)
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(dimming * 0.45),
                            Color.black.opacity(dimming),
                            Color.black.opacity(dimming + 0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Sheet sizing

/// Sizes a sheet to whatever its content actually needs, instead of a guessed
/// fraction. The content is measured once laid out and that height becomes the
/// sheet's detent, so short sheets stop short and never scroll; only content
/// taller than `maxFraction` of the screen falls back to scrolling.
///
/// Apply this to the sheet's root view — it replaces `presentationDetents`.
/// Published by `sheetContentHeight()` when the natural height lives on an
/// inner subtree — a `ScrollView` fills whatever it is offered, so measuring
/// the sheet's root would always report "full screen".
private struct SheetContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Marks the subtree whose height should size the enclosing `fittedSheet`.
    /// Put it on the stack *inside* a `ScrollView`, not on the scroll view.
    func sheetContentHeight() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: SheetContentHeightKey.self, value: proxy.size.height)
            }
        }
    }
}

private struct FittedSheetDetent: ViewModifier {
    var minHeight: CGFloat
    var maxFraction: CGFloat
    var allowsExpansion: Bool
    var includesNavigationBar: Bool
    var background: AnyShapeStyle
    /// Slack added to the measured height. Use it where a step's content can
    /// change while the sheet is open and it should breathe rather than clip.
    var extraHeight: CGFloat

    @State private var measuredRoot: CGFloat = 0
    @State private var measuredContent: CGFloat = 0

    /// The system's inline navigation-bar height, asked of UIKit instead of
    /// hardcoded, so a sheet wrapped in a `NavigationStack` can still be sized
    /// to its content.
    private static let navigationBarHeight: CGFloat = UINavigationBar()
        .sizeThatFits(CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        .height

    private var contentHeight: CGFloat {
        let measured = measuredContent > 0 ? measuredContent : measuredRoot
        return measured + (includesNavigationBar ? Self.navigationBarHeight : 0)
    }

    private var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
    }

    private var availableHeight: CGFloat {
        (scene?.screen.bounds.height ?? 852) * maxFraction
    }

    /// A detent's height spans the whole sheet, but the content is laid out
    /// inside the bottom safe area — so that strip has to be added on, or the
    /// sheet ends up with a dead band under the last control.
    private var bottomInset: CGFloat {
        scene?.keyWindow?.safeAreaInsets.bottom ?? 0
    }

    private var resolvedHeight: CGFloat {
        min(max(contentHeight + bottomInset + extraHeight, minHeight), availableHeight)
    }

    private var detents: Set<PresentationDetent> {
        allowsExpansion && resolvedHeight < availableHeight
            ? [.height(resolvedHeight), .large]
            : [.height(resolvedHeight)]
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                // Ignore sub-point churn so the detent can't oscillate against
                // the layout it is itself driving.
                guard abs(newHeight - measuredRoot) > 0.5 else { return }
                measuredRoot = newHeight
            }
            .onPreferenceChange(SheetContentHeightKey.self) { newHeight in
                guard abs(newHeight - measuredContent) > 0.5 else { return }
                measuredContent = newHeight
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // Covers the safe-area strip too, which a `.background` on the
            // content itself cannot reach.
            .presentationBackground(background)
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
    }
}

extension View {
    /// Makes a sheet exactly as tall as its content. See `FittedSheetDetent`.
    /// - Parameters:
    ///   - minHeight: floor for very short sheets, so the grabber has room.
    ///   - maxFraction: ceiling as a share of the screen height.
    ///   - allowsExpansion: also offers a full-height detent the user can drag to.
    ///   - includesNavigationBar: pass `true` when the sheet's root is a
    ///     `NavigationStack`, so the bar is counted in the detent.
    func fittedSheet(
        minHeight: CGFloat = 200,
        maxFraction: CGFloat = 0.92,
        allowsExpansion: Bool = false,
        includesNavigationBar: Bool = false,
        background: some ShapeStyle = TamrinTheme.sheet,
        extraHeight: CGFloat = 0
    ) -> some View {
        modifier(FittedSheetDetent(
            minHeight: minHeight,
            maxFraction: maxFraction,
            allowsExpansion: allowsExpansion,
            includesNavigationBar: includesNavigationBar,
            background: AnyShapeStyle(background),
            extraHeight: extraHeight
        ))
    }
}

// MARK: - Sheet titles

extension View {
    /// Title and explanatory line for a sheet's bar.
    ///
    /// `navigationSubtitle` can't be used for this: its label carries no font
    /// attributes, so it inherits the 18pt `UILabel` appearance default — bigger
    /// than the title above it — and the resulting two-line block sits packed
    /// against the sheet's top edge. Drawing the pair as a principal item keeps
    /// the native placement while the sizes and the breathing room stay ours.
    func sheetTitle(_ title: String, subtitle: String? = nil) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(title)
                            .font(TamrinFont.font(size: 17, weight: .bold))
                        if let subtitle {
                            Text(subtitle)
                                .font(TamrinFont.font(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 30)
                    .padding(.bottom, 6)
                }
            }
    }
}

// MARK: - Native controls

/// The app's action buttons are the stock iOS 26 ones — `.glassProminent` for a
/// primary action, `.glass` for a secondary — so they inherit the system's own
/// Liquid Glass rendering, press animation, tint handling and accessibility
/// behaviour instead of a hand-drawn capsule that only imitates them.
extension View {
    /// Primary action: filled Liquid Glass, tinted with the app accent.
    func tamrinPrimaryAction(tint: Color = .accentColor) -> some View {
        buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(tint)
            .font(TamrinFont.headline)
    }

    /// Secondary action: clear Liquid Glass, no fill.
    func tamrinSecondaryAction() -> some View {
        buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .font(TamrinFont.headline)
    }

    /// Full-width variant for the bottom of a form or sheet.
    func tamrinWideAction() -> some View {
        frame(maxWidth: .infinity)
    }
}

/// The app's standard full-width action. A plain `Button` under one of the
/// system's iOS 26 styles — the press animation, glass rendering, disabled
/// treatment and destructive tint all come from the platform.
struct TamrinActionButton: View {
    let title: String
    var systemImage: String?
    var role: ButtonRole?
    var isLoading = false
    var prominent = true
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(role: role) {
            action()
        } label: {
            label
                .font(TamrinFont.headline)
                .frame(maxWidth: .infinity)
        }
        .modifier(NativeActionStyle(prominent: prominent, tint: tint))
        .disabled(isLoading)
        .animation(.smooth(duration: 0.25), value: isLoading)
    }

    @ViewBuilder
    private var label: some View {
        if isLoading {
            ProgressView().controlSize(.small)
        } else if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

/// Applies whichever stock style the button asked for. Split out because
/// `buttonStyle` returns different opaque types on each branch.
private struct NativeActionStyle: ViewModifier {
    let prominent: Bool
    let tint: Color

    func body(content: Content) -> some View {
        if prominent {
            content
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(tint)
        } else {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }
}

struct TamrinCapsuleField: ViewModifier {
    var focused = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 18)
            .frame(minHeight: 56)
            .background(.thinMaterial, in: .capsule)
    }
}

extension View {
    func tamrinCapsuleField(focused: Bool = false) -> some View {
        modifier(TamrinCapsuleField(focused: focused))
    }
}

struct AuroraBackdrop: View {
    var intensity: Double = 1
    var body: some View {
        ZStack {
            TamrinTheme.page
            Circle().fill(TamrinTheme.lime.opacity(0.30 * intensity)).frame(width: 340, height: 340).blur(radius: 75).offset(x: 150, y: -280)
            Circle().fill(TamrinTheme.mint.opacity(0.22 * intensity)).frame(width: 280, height: 280).blur(radius: 85).offset(x: -170, y: -80)
            LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
        }.ignoresSafeArea()
    }
}

struct IconOrb: View {
    let symbol: String
    var tint: Color = TamrinTheme.ink
    var size: CGFloat = 46
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(tint).frame(width: size, height: size)
            .background(TamrinTheme.glass, in: .circle)
            .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
    }
}

struct TeamAvatarView: View {
    var avatarData: Data? = nil
    var symbol: String = "figure.run"
    var size: CGFloat = 56
    var cornerRadiusRatio: CGFloat = 0.32
    var fallbackBackground: AnyShapeStyle = AnyShapeStyle(TamrinTheme.secondary)
    var symbolColor: Color = TamrinTheme.ink

    var body: some View {
        Group {
            if let data = avatarData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(fallbackBackground)
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(symbolColor)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * cornerRadiusRatio, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct FloatingCloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: TamrinControlMetrics.symbolSize, weight: .semibold))
                .frame(width: TamrinControlMetrics.touchTarget, height: TamrinControlMetrics.touchTarget)
        }
            .buttonStyle(.plain).background(.thinMaterial, in: .circle)
    }
}

/// The app's own icon, drawn at whatever size the caller asks for. The artwork
/// comes from the bundled icon rather than a stand-in glyph, so the mark on
/// screen is always the same one on the Home Screen — including its light /
/// dark variants, which the asset catalog resolves for us.
struct BrandMark: View {
    var size: CGFloat = 72

    /// Icon Composer ships the icon unmasked (the system applies the squircle
    /// at display time), so we apply iOS's own corner ratio here.
    private var cornerRadius: CGFloat { size * 0.2237 }

    var body: some View {
        Group {
            if let icon = Self.appIcon {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
            } else {
                // No icon in the bundle (previews, and any build that ships
                // without one) — fall back to the wordless glyph tile.
                ZStack {
                    Rectangle().fill(TamrinTheme.ink)
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    /// The asset-catalog entry first — that one carries the light/dark/tinted
    /// variants. `CFBundleIconFiles` is the flattened PNG the launcher uses and
    /// only stands in when the catalog lookup misses.
    private static let appIcon: UIImage? = {
        if let named = UIImage(named: "AppIcon") { return named }
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last
        else { return nil }
        return UIImage(named: last)
    }()
}

struct SpringCardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.975 : 1))
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

struct SectionEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(TamrinFont.caption).tracking(0.4).foregroundStyle(.secondary)
    }
}

struct DayPicker: View {
    @Binding var selection: Set<Int>
    private let days = [(7,"س"), (1,"ح"), (2,"ن"), (3,"ث"), (4,"ر"), (5,"خ"), (6,"ج")]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(days, id: \.0) { day, label in
                Button {
                    if selection.contains(day) { selection.remove(day) } else { selection.insert(day) }
                    Haptics.selection()
                } label: {
                    Text(label).font(TamrinFont.font(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity).frame(height: 42)
                        .foregroundStyle(selection.contains(day) ? .white : .primary)
                        .background(selection.contains(day) ? Color.black : TamrinTheme.secondary, in: .circle)
                }
                .buttonStyle(.plain).accessibilityLabel(dayName(day))
                .accessibilityAddTraits(selection.contains(day) ? .isSelected : [])
            }
        }
    }

    private func dayName(_ value: Int) -> String {
        [1:"الأحد",2:"الاثنين",3:"الثلاثاء",4:"الأربعاء",5:"الخميس",6:"الجمعة",7:"السبت"][value] ?? ""
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = .secondary
    var symbol: String?
    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let symbol { Image(systemName: symbol) }
        }
        .font(TamrinFont.font(size: 12, weight: .bold)).foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(color.opacity(0.1), in: .capsule)
    }
}

extension Locale {
    /// Arabic copy, Western digits — the only locale the UI formats against.
    ///
    /// Plain `ar` / `ar_SA` render Arabic-Indic numerals (٠١٢٣), which this app
    /// never shows: every number on screen is 0123456789. The `numbers=latn`
    /// keyword keeps month names, weekday names and AM/PM Arabic while pinning
    /// the numbering system, so callers get the Arabic wording for free.
    static let tamrin = Locale(identifier: "ar_SA@numbers=latn")
}

extension Date {
    var arabicDay: String { formatted(.dateTime.locale(.tamrin).weekday(.wide)) }
    var arabicDate: String { formatted(.dateTime.locale(.tamrin).day().month(.wide)) }
    var arabicTime: String { formatted(.dateTime.locale(.tamrin).hour().minute()) }
}

extension Double {
    var cleanAmount: String { formatted(.number.precision(.fractionLength(0...2))) }
}
