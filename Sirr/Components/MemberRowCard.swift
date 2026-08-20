import SwiftUI

/// The circular initial that stands in for a member's photo.
/// The one place a person is drawn in this app: their photo when there is one,
/// their initial when there is not. Both sources are accepted so a picture the
/// user just chose shows immediately, before it has finished uploading, while
/// everyone else's arrives as a URL from their profile row.
struct MemberAvatar: View {
    let name: String
    var size: CGFloat = MemberRowCard<EmptyView>.avatarSize
    /// A photo held in memory — the freshly picked one, ahead of its upload.
    var imageData: Data?
    /// The stored profile photo.
    var imageUrl: String?
    /// Overrides the neutral disc — used to mark the organizer.
    var tint: Color = .white.opacity(0.28)
    /// The initial is dark on a bright tint and white on the neutral disc.
    var foreground: Color = .white

    private var localImage: UIImage? {
        guard let imageData else { return nil }
        return UIImage(data: imageData)
    }

    var body: some View {
        Group {
            if let localImage {
                Image(uiImage: localImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let imageUrl, let url = URL(string: imageUrl) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        initial
                    }
                }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    private var initial: some View {
        Circle()
            .fill(tint)
            .overlay {
                Text(String(name.prefix(1)))
                    .font(TamrinFont.font(size: size * 0.44, weight: .bold))
                    .foregroundStyle(foreground)
            }
    }
}

/// The app's list row: something round on the leading edge, a title over an
/// optional secondary line, and whatever status or control belongs on the far
/// side — on the standard glass card.
///
/// Every list that names things uses this one row — the exercise roster, the
/// apologies page, the group's members, the payment methods — so they read as
/// one family. The measurements below are the row's definition; do not restate
/// them at a call site.
struct TamrinRowCard<Leading: View, Accessory: View>: View {
    /// Diameter of the leading circle, and with it the row's whole height.
    static var leadingSize: CGFloat { 40 }
    /// Set together with `leadingSize` so the row keeps its 72pt height:
    /// resizing one alone would resize every row in the app.
    static var verticalPadding: CGFloat { (72 - leadingSize) / 2 }

    let title: String
    var subtitle: String?
    /// Off when the row is part of a larger card that paints the glass itself,
    /// so the two do not stack two surfaces with a seam between them.
    var drawsCard: Bool = true
    @ViewBuilder var leading: Leading
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            leading

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TamrinFont.font(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(TamrinFont.font(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            accessory
        }
        .padding(.horizontal, 16)
        .padding(.vertical, Self.verticalPadding)
        .modifier(OptionalGlassCard(isOn: drawsCard))
        .frame(maxWidth: .infinity, alignment: .leading)

    }
}

extension TamrinRowCard where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder leading: () -> Leading) {
        self.init(title: title, subtitle: subtitle, leading: leading) { EmptyView() }
    }
}

/// The row for a person: the same card, with their initial on the leading edge.
struct MemberRowCard<Accessory: View>: View {
    static var avatarSize: CGFloat { TamrinRowCard<EmptyView, EmptyView>.leadingSize }

    let name: String
    var subtitle: String?
    var avatarImageData: Data?
    var avatarImageUrl: String?
    var avatarTint: Color = .white.opacity(0.28)
    var avatarForeground: Color = .white
    var drawsCard: Bool = true
    @ViewBuilder var accessory: Accessory

    var body: some View {
        TamrinRowCard(title: name, subtitle: subtitle, drawsCard: drawsCard) {
            MemberAvatar(
                name: name,
                size: Self.avatarSize,
                imageData: avatarImageData,
                imageUrl: avatarImageUrl,
                tint: avatarTint,
                foreground: avatarForeground
            )
        } accessory: {
            accessory
        }
    }
}

extension MemberRowCard where Accessory == EmptyView {
    init(
        name: String,
        subtitle: String? = nil,
        avatarImageData: Data? = nil,
        avatarImageUrl: String? = nil
    ) {
        self.init(
            name: name,
            subtitle: subtitle,
            avatarImageData: avatarImageData,
            avatarImageUrl: avatarImageUrl
        ) { EmptyView() }
    }
}

#Preview {
    ZStack {
        Color.black
        VStack(spacing: 14) {
            MemberRowCard(name: "أبو صقر", subtitle: "لم يُذكر سبب")
            MemberRowCard(name: "فارس أبومالح") {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(TamrinTheme.lime)
            }
            MemberRowCard(
                name: "نايف الشهراني",
                subtitle: "مشرف التمرين",
                avatarTint: TamrinTheme.lime,
                avatarForeground: TamrinTheme.ink
            ) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(TamrinTheme.lime)
            }
        }
        .padding(20)
    }
    .environment(\.layoutDirection, .rightToLeft)
    .colorScheme(.dark)
}


/// Applies the app's glass card only when asked, so one row can stand alone and
/// another can be a slice of a bigger card.
private struct OptionalGlassCard: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.tamrinGlassCard()
        } else {
            content
        }
    }
}
