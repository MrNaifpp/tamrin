import SwiftUI
import CoreText

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
}

enum TamrinFont {
    static func font(size: CGFloat, weight: TamrinFontWeight = .regular, features: Bool = true) -> Font {
        guard features else { return .custom(weight.postScriptName, size: size) }
        let attributes: [CFString: Any] = [
            kCTFontNameAttribute: weight.postScriptName,
            kCTFontSizeAttribute: size,
            kCTFontFeatureSettingsAttribute: [
                [
                    kCTFontFeatureTypeIdentifierKey: 35,
                    kCTFontFeatureSelectorIdentifierKey: 2
                ]
            ]
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
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
    static let page = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.06, blue: 0.052, alpha: 1)
            : UIColor(red: 0.955, green: 0.958, blue: 0.945, alpha: 1)
    })
    static let card = Color(uiColor: .systemBackground)
    static let secondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.16, alpha: 1)
            : UIColor(red: 0.92, green: 0.925, blue: 0.90, alpha: 1)
    })
    static let glass = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.13, alpha: 0.94)
            : UIColor(white: 1, alpha: 0.74)
    })
    static let hairline = Color.primary.opacity(0.08)
    static let ink = Color(red: 0.075, green: 0.08, blue: 0.07)
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
    static let actionHeight: CGFloat = 48
    static let symbolSize: CGFloat = 17
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
                            Color(red: 0.33, green: 0.15, blue: 0.24).opacity(dimming),
                            Color(red: 0.16, green: 0.23, blue: 0.16).opacity(dimming + 0.18)
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

struct TamrinCapsuleField: ViewModifier {
    var focused = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 18)
            .frame(minHeight: 56)
            .background(.thinMaterial, in: .capsule)
            .overlay {
                Capsule()
                    .stroke(.white.opacity(focused ? 0.78 : 0.22), lineWidth: focused ? 1.5 : 1)
            }
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
            .overlay(Circle().stroke(TamrinTheme.hairline, lineWidth: 1))
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
            .overlay(Circle().stroke(.white.opacity(0.65)))
    }
}

struct BrandMark: View {
    var size: CGFloat = 72
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(.black)
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TamrinFont.headline)
            .frame(maxWidth: .infinity)
            .frame(minHeight: TamrinControlMetrics.actionHeight)
            .foregroundStyle(.white)
            .background(TamrinTheme.ink.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.22), in: .capsule)
            .shadow(color: isEnabled ? .black.opacity(0.14) : .clear, radius: 18, y: 9)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TamrinFont.headline)
            .frame(maxWidth: .infinity)
            .frame(minHeight: TamrinControlMetrics.actionHeight)
            .foregroundStyle(.primary)
            .background(TamrinTheme.secondary, in: .capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
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
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Text(label).font(.subheadline.weight(.semibold))
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
        .font(.caption.weight(.semibold)).foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(color.opacity(0.1), in: .capsule)
    }
}

extension Date {
    var arabicDay: String { formatted(.dateTime.locale(Locale(identifier: "ar_SA")).weekday(.wide)) }
    var arabicDate: String { formatted(.dateTime.locale(Locale(identifier: "ar_SA")).day().month(.wide)) }
    var arabicTime: String { formatted(.dateTime.locale(Locale(identifier: "ar_SA")).hour().minute()) }
}

extension Double {
    var cleanAmount: String { formatted(.number.precision(.fractionLength(0...2))) }
}
