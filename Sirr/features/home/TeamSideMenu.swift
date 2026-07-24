import SwiftUI

/// Ported side-menu drawer (designer TeamSideMenu, member view) bound to
/// HomeStore. Team selection is live; create-team and settings are supplied
/// by the parent. The admin/member experience switcher is intentionally dropped.
struct TeamSideMenu: View {
    @Bindable var feed: HomeStore
    let createTeam: () -> Void
    let openSettings: () -> Void
    let onSelectTeam: (UUID) -> Void

    var body: some View {
        GeometryReader { proxy in
            let menuWidth = min(proxy.size.width - 94, 308)

            ZStack(alignment: .topLeading) {
                Color(red: 0.067, green: 0.067, blue: 0.067)
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    menuHeader(width: menuWidth)
                        .padding(.bottom, 10)

                    groupsScrollWithEdgeEffects(width: menuWidth)
                        .frame(maxHeight: .infinity)

                    profileButton(width: menuWidth)
                        .padding(.top, 12)
                }
                .frame(width: menuWidth, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, max(proxy.safeAreaInsets.top + 24, 68))
                .padding(.bottom, max(proxy.safeAreaInsets.bottom + 16, 30))
                .padding(.leading, 16)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .colorScheme(.dark)
    }

    private func menuHeader(width: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text("المجموعات")
                .font(TamrinFont.font(size: 22, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            Button(action: createTeam) {
                Label("إنشاء مجموعة", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: TamrinControlMetrics.glassIconContent, height: TamrinControlMetrics.glassIconContent)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .tint(.blue)
            .accessibilityLabel("إنشاء مجموعة")
            .accessibilityHint("يفتح شاشة إنشاء مجموعة جديدة")
        }
        .frame(width: width)
    }

    @ViewBuilder
    private func groupsScrollWithEdgeEffects(width: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            groupsScroll(width: width)
                // Native iOS 26 scroll-edge material creates the same soft
                // fade under the title and above the anchored profile card.
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            groupsScroll(width: width)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.055),
                            .init(color: .black, location: 0.945),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
    }

    private func groupsScroll(width: CGFloat) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 4) {
                ForEach(feed.teams) { team in
                    let isSelected = team.id == feed.selectedTeamID

                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        onSelectTeam(team.id)
                    } label: {
                        TeamSideMenuRow(team: team, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(team.name)
                    .accessibilityValue(isSelected ? "المجموعة الحالية" : "\(team.memberCount) عضو")
                    .accessibilityHint(isSelected ? "المجموعة محددة حاليًا" : "التبديل إلى هذه المجموعة")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, 10)
            .frame(width: width)
        }
    }

    private func profileButton(width: CGFloat) -> some View {
        Button(action: openSettings) {
            HStack(spacing: 11) {
                MenuProfileAvatar(name: feed.profileName)

                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.profileName.isEmpty ? "حسابي" : feed.profileName)
                        .font(TamrinFont.font(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("الملف الشخصي")
                        .font(TamrinFont.font(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.54))
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(width: width)
            .frame(minHeight: 62)
            .background(.white.opacity(0.075), in: .rect(cornerRadius: 20, style: .continuous))
            .contentShape(.rect(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("الملف الشخصي")
        .accessibilityHint("يفتح إعدادات الملف الشخصي")
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
                            Color(red: 0.80, green: 0.83, blue: 0.72),
                            Color(red: 0.95, green: 0.95, blue: 0.84)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                ),
                symbolColor: Color(red: 0.10, green: 0.13, blue: 0.10)
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(team.name)
                    .font(TamrinFont.font(size: 16, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(team.memberCount.formatted(.number.locale(Locale(identifier: "ar_SA")).grouping(.never))) عضو")
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
    var body: some View {
        Circle()
            .fill(.white.opacity(0.18))
            .frame(width: 40, height: 40)
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
            .accessibilityHidden(true)
    }
}

#Preview {
    TeamSideMenu(feed: HomeStore.preview, createTeam: {}, openSettings: {},
                 onSelectTeam: { _ in })
}
