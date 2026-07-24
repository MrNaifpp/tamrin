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

            ZStack(alignment: .bottomLeading) {
                Color(red: 0.067, green: 0.067, blue: 0.067).ignoresSafeArea()

                VStack(alignment: .leading, spacing: 20) {
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
                    }
                    .frame(width: menuWidth)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 8) {
                            ForEach(feed.teams) { team in
                                Button {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    onSelectTeam(team.id)
                                } label: {
                                    TeamSideMenuRow(team: team, isSelected: team.id == feed.selectedTeamID)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(team.id == feed.selectedTeamID ? .isSelected : [])
                            }
                        }
                        .frame(width: menuWidth)
                    }
                    .frame(maxHeight: proxy.size.height * 0.46)

                    Spacer(minLength: 0)
                }
                .padding(.top, max(proxy.safeAreaInsets.top + 40, 82))
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                VStack {
                    Spacer()
                    Button(action: openSettings) {
                        HStack(spacing: 10) {
                            MenuProfileAvatar(name: feed.profileName)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(feed.profileName.isEmpty ? "حسابي" : feed.profileName)
                                    .font(TamrinFont.font(size: 14, weight: .bold))
                                Text("الملف الشخصي")
                                    .font(TamrinFont.font(size: 10, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            Spacer()
                        }
                        .frame(width: menuWidth)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .accessibilityLabel("الملف الشخصي")
                }
                .padding(.leading, 16)
                .padding(.bottom, max(proxy.safeAreaInsets.bottom + 24, 40))
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .colorScheme(.dark)
    }
}

private struct TeamSideMenuRow: View {
    let team: FeedTeam
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            TeamAvatarView(
                avatarData: team.avatarData,
                symbol: team.symbol,
                size: 56,
                cornerRadiusRatio: 12 / 56,
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
                    .font(TamrinFont.font(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("الأعضاء  \(team.memberCount)")
                    .font(TamrinFont.font(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .frame(height: 20, alignment: .center)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            isSelected ? Color(red: 0.10, green: 0.10, blue: 0.10) : .clear,
            in: .rect(cornerRadius: 24, style: .continuous)
        )
    }
}

private struct MenuProfileAvatar: View {
    let name: String
    var body: some View {
        Circle()
            .fill(.white.opacity(0.18))
            .frame(width: 36, height: 36)
            .overlay {
                Text(String(name.prefix(1)))
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    TeamSideMenu(feed: HomeStore.preview, createTeam: {}, openSettings: {},
                 onSelectTeam: { _ in })
}
