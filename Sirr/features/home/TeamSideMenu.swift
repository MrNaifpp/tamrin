import SwiftUI

enum HomeDrawerMetrics {
    static let horizontalInset: CGFloat = 12
    static let chromeInset: CGFloat = 18

    /// Matches the roughly 300pt drawer used by ChatGPT on a 402pt iPhone,
    /// while retaining enough of the page to make the spatial relationship clear.
    static func width(for containerWidth: CGFloat) -> CGFloat {
        min(300, max(0, containerWidth - 72))
    }
}

/// Ported side-menu drawer (designer TeamSideMenu, member view) bound to
/// HomeStore. Team selection is live; create-team and settings are supplied
/// by the parent. The admin/member experience switcher is intentionally dropped.
struct TeamSideMenu: View {
    @Bindable var feed: HomeStore
    let createTeam: () -> Void
    let openSettings: () -> Void
    let openAppSettings: () -> Void
    let onSelectTeam: (UUID) -> Void
    @State private var scrollOffset: CGFloat = 0
    /// Shared by the two header buttons so their glass shapes merge.
    @Namespace private var headerGlass

    var body: some View {
        GeometryReader { proxy in
            let drawerWidth = HomeDrawerMetrics.width(for: proxy.size.width)
            let contentWidth = max(
                drawerWidth - (HomeDrawerMetrics.horizontalInset * 2),
                0
            )
            let chromeWidth = max(
                drawerWidth - (HomeDrawerMetrics.chromeInset * 2),
                0
            )
            let pulledPastTop = max(-scrollOffset, 0)

            ZStack {
                // The drawer is the deepest layer, so it takes the floor tone —
                // `systemBackground` here would be pure black.
                TamrinTheme.surfaceFloor
                    .ignoresSafeArea()

                ZStack {
                    groupsScroll(width: contentWidth)
                        .frame(width: drawerWidth)
                        .scrollBounceBehavior(.always)
                        // Fade only the scrolling rows. Keeping the drawer
                        // background outside this mask preserves one solid
                        // black surface with no toolbar-shaped rectangles.
                        .mask { scrollContentMask }
                        .onScrollGeometryChange(for: CGFloat.self) { geometry in
                            geometry.contentOffset.y - geometry.contentInsets.top
                        } action: { _, newOffset in
                            scrollOffset = newOffset
                        }

                    menuHeader(width: chromeWidth)
                        // ChatGPT's header follows a strong rubber-band pull at
                        // a slower rate, then settles back with the list.
                        .offset(y: min(pulledPastTop * 0.32, 42))
                        .padding(.horizontal, HomeDrawerMetrics.chromeInset)
                        .padding(.top, 62)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    profileButton(width: contentWidth)
                        .padding(.horizontal, HomeDrawerMetrics.horizontalInset)
                        .padding(.bottom, 30)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .frame(width: drawerWidth)
                .environment(\.layoutDirection, .rightToLeft)
                // The drawer itself is placed on the physical right. RTL
                // applies only inside it so semantic alignment cannot move
                // the whole 300pt surface back to the left.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .colorScheme(.dark)
    }

    private func menuHeader(width: CGFloat) -> some View {
        ZStack {
            Text("التمارين")
                .font(TamrinFont.font(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)

            headerControls
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
        // Physical placement is fixed: Arabic title on the right and the
        // primary action on the left, independent of an ancestor's RTL rules.
        .environment(\.layoutDirection, .leftToRight)
    }

    /// Settings and add as one merged glass capsule.
    ///
    /// `ControlGroup` is the obvious container for a pair like this, but its
    /// grouped-glass appearance only comes from a toolbar. This header is a
    /// hand-built overlay inside the drawer, so a control group there falls back
    /// to a flat filled rectangle and has to be `fixedSize`d — which drops it
    /// under the standard control metrics. `glassEffectUnion` is the API for the
    /// same visual outside a toolbar: two ordinary buttons whose glass shapes
    /// merge into one capsule, each keeping the system's 44pt hit target.
    ///
    /// Physical order is gear then plus: the header is pinned to LTR, so in the
    /// Arabic reading direction the primary action (add) still comes first.
    private var headerControls: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                headerIconButton(
                    "gearshape",
                    label: "الإعدادات",
                    hint: "يفتح إعدادات التطبيق",
                    action: openAppSettings
                )

                headerIconButton(
                    "plus",
                    label: "إضافة",
                    hint: feed.isCurrentTeamOwner
                        ? "يفتح خيارات إنشاء تمرين أو موعد"
                        : "يفتح خيارات إنشاء تمرين أو الانضمام إلى تمرين",
                    action: createTeam
                )
            }
        }
    }

    private func headerIconButton(
        _ systemImage: String,
        label: String,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                // 44×44 is the platform's minimum touch target; the icon-only
                // control groups in system apps are laid out on the same grid.
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectUnion(id: "headerControls", namespace: headerGlass)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    private func groupsScroll(width: CGFloat) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 4) {
                ForEach(feed.teams) { team in
                    let isSelected = team.id == feed.selectedTeamID

                    Button {
                        Haptics.selection()
                        onSelectTeam(team.id)
                    } label: {
                        TeamSideMenuRow(team: team, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(team.name)
                    .accessibilityValue(isSelected ? "التمرين الحالي" : team.memberCount.counted(.member))
                    .accessibilityHint(isSelected ? "التمرين محدد حاليًا" : "التبديل إلى هذا التمرين")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.top, 128)
            .padding(.bottom, 110)
            .frame(width: width)
        }
    }

    private var scrollContentMask: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.58),
                    .init(color: .black.opacity(0.45), location: 0.78),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 128)

            Rectangle().fill(.black)

            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.88), location: 0.06),
                    .init(color: .black.opacity(0.18), location: 0.18),
                    .init(color: .clear, location: 0.32),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 112)
        }
    }

    /// Bottom-anchored account control. The subtitle names exactly what is
    /// editable behind it (name + position) and the trailing pencil makes the
    /// row read as an entry point rather than a static profile badge.
    ///
    /// Uses `glassEffect` rather than `buttonStyle(.glass)`: the button style
    /// insets its label by an amount we can't read, so the capsule ended up
    /// wider than the team cards above it. Here the capsule is exactly the card
    /// width and the content uses the cards' own 10pt inset, so the avatars and
    /// both edges line up down the whole drawer.
    private func profileButton(width: CGFloat) -> some View {
        Button(action: openSettings) {
            HStack(spacing: 11) {
                MenuProfileAvatar(
                    name: feed.profileName,
                    avatarData: feed.avatarData,
                    avatarUrl: feed.avatarUrl
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.profileName.isEmpty ? "حسابي" : feed.profileName)
                        .font(TamrinFont.font(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(profileSubtitle)
                        .font(TamrinFont.font(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.14), in: .circle)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: TeamSideMenu.accountRowHeight)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(feed.profileName.isEmpty ? "حسابي" : feed.profileName)
        .accessibilityHint("يفتح تعديل الاسم والمركز")
    }

    private static let accountRowHeight: CGFloat = 62

    private var profileSubtitle: String {
        let position = feed.playerPosition.trimmingCharacters(in: .whitespacesAndNewlines)
        return position.isEmpty ? "عدّل اسمك ومركزك" : "\(position) · عدّل معلوماتك"
    }
}

private struct TeamSideMenuRow: View {
    let team: FeedTeam
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            TeamAvatarView(
                avatarData: team.avatarData,
                symbol: team.symbol,
                size: 44,
                cornerRadiusRatio: 13 / 44,
                fallbackBackground: AnyShapeStyle(
                    LinearGradient(
                        colors: [
                            team.color.color,
                            team.color.color.opacity(0.82)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                ),
                symbolColor: team.color.symbolColor
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(team.name)
                    .font(TamrinFont.font(size: 16, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(team.memberCount.counted(.member))
                    .font(TamrinFont.font(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(minHeight: 64)
        .background(
            isSelected ? Color.white.opacity(0.105) : .clear,
            in: .rect(cornerRadius: 18, style: .continuous)
        )
        .contentShape(.rect(cornerRadius: 18, style: .continuous))
    }
}

private struct MenuProfileAvatar: View {
    let name: String
    var avatarData: Data?
    var avatarUrl: String?

    var body: some View {
        Group {
            if let avatarData, let image = UIImage(data: avatarData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let avatarUrl, let url = URL(string: avatarUrl) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        initialDisc
                    }
                }
            } else {
                initialDisc
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    private var initialDisc: some View {
        Circle()
            .fill(.white.opacity(0.18))
            .overlay {
                if name.isEmpty {
                    Image(systemName: "person.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                } else {
                    Text(String(name.prefix(1)))
                        .font(TamrinFont.font(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }
}

#Preview {
    TeamSideMenu(feed: HomeStore.preview, createTeam: {}, openSettings: {},
                 openAppSettings: {}, onSelectTeam: { _ in })
}
