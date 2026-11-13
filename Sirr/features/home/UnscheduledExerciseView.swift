import SwiftUI

/// Workspace-only destinations never masquerade as dated events. The UUID is
/// the workspace's, so Home can keep it stable while its schedule is empty.
enum HomeExerciseDestination: Identifiable {
    case event(FeedOccurrence)
    case workspace(FeedTeam, createSession: Bool = false)

    var id: UUID {
        switch self {
        case .event(let event): event.id
        case .workspace(let team, _): team.id
        }
    }
    var occurrence: FeedOccurrence? {
        if case .event(let event) = self { return event }
        return nil
    }
}

struct CreateSessionButton: View {
    var title = String(localized: "إنشاء موعد جديد")
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(TamrinFont.font(size: 15, weight: .medium))
            }
            .foregroundStyle(isPrimary ? Color.black : .white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 14)
            .background {
                if isPrimary { RoundedRectangle(cornerRadius: 20).fill(.white) }
                else { RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("يفتح إنشاء موعد إضافي في المجموعة نفسها")
    }
}

struct UnscheduledExercisePoster: View {
    let team: FeedTeam
    let isOwner: Bool
    let artName: String
    let action: () -> Void
    let onCreate: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                Color.clear.overlay {
                    Image(exerciseArt: artName).resizable().scaledToFill()
                }.clipped()
                LinearGradient(colors: [.clear, ArtworkPalette.averageColor(for: artName).opacity(0.9)],
                               startPoint: .center, endPoint: .bottom)
                VStack(spacing: 10) {
                    Text(team.name)
                        .font(TamrinFont.font(size: 31, weight: .bold))
                        .lineLimit(2).minimumScaleFactor(0.7)
                    Text("لا يوجد موعد")
                        .font(TamrinFont.font(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.84))
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24).padding(.bottom, isOwner ? 110 : 32)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if isOwner {
                    EventSupervisorTagView(artName: artName)
                        .padding(.top, 20).padding(.trailing, 20)
                }
            }
            .clipShape(.rect(cornerRadius: 36, style: .continuous))
            .contentShape(.rect(cornerRadius: 36, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(team.name)، لا يوجد موعد")
        .accessibilityHint("يفتح التمرين وأعضاءه")
        .overlay(alignment: .bottom) {
            if isOwner {
                CreateSessionButton(title: String(localized: "إنشاء موعد"), isPrimary: true, action: onCreate)
                    .padding(.horizontal, 24).padding(.bottom, 28)
            }
        }
    }
}

/// The same photo/title/details-entry hierarchy as a scheduled EventDetailView,
/// with no registration, money or roster controls when no occurrence exists.
struct UnscheduledExerciseView: View {
    @Bindable var feed: HomeStore
    let team: FeedTeam
    let artName: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hasVerticalBar) private var hasVerticalBar
    @State private var showsDetails = false
    let onCreate: () -> Void

    var body: some View { emptyContent }

    /// The details page drawn over this one brings its own toolbar items, so
    /// these step aside while it is open.
    private var hostsChromeInVerticalBar: Bool {
        hasVerticalBar && !showsDetails
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Label("إغلاق", systemImage: "chevron.backward")
                .labelStyle(.iconOnly)
                .frame(width: TamrinControlMetrics.glassIconContent,
                       height: TamrinControlMetrics.glassIconContent)
        }
        .accessibilityLabel("إغلاق")
    }

    private var detailsButton: some View {
        Button { showsDetails = true } label: {
            Label("تفاصيل التمرين", systemImage: "list.bullet.rectangle.portrait")
                .labelStyle(.iconOnly)
                .frame(width: TamrinControlMetrics.glassIconContent,
                       height: TamrinControlMetrics.glassIconContent)
        }
        .accessibilityLabel("تفاصيل التمرين")
    }

    private var emptyContent: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Image(exerciseArt: artName).resizable().scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                Image(exerciseArt: artName).resizable().scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    .blur(radius: 26, opaque: true)
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0.22),
                        .init(color: .black, location: 0.45)
                    ], startPoint: .top, endPoint: .bottom))
                LinearGradient(colors: [.black.opacity(0.32), .black.opacity(0.58)],
                               startPoint: .top, endPoint: .bottom)
                ScrollView {
                    VStack(spacing: 14) {
                        Color.clear.frame(height: 300)
                        Text(team.name)
                            .font(TamrinFont.font(size: 30, weight: .bold))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        Text("لا يوجد موعد")
                            .font(TamrinFont.font(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                        if feed.isOwner(ofTeamID: team.id) {
                            CreateSessionButton(title: String(localized: "إنشاء موعد"), isPrimary: true, action: onCreate)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.bottom, 40)
                }
                if showsDetails {
                    Color.black.opacity(0.25).background(.ultraThinMaterial)
                    ExerciseDetailsOverlayPage(feed: feed, occurrence: nil, teamID: team.id,
                                               screenTopInset: proxy.safeAreaInsets.top,
                                               onLeave: { dismiss() },
                                               onClose: { showsDetails = false })
                }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            if !showsDetails && !hasVerticalBar {
                closeButton
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .padding(.horizontal, 20).padding(.top, 6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !showsDetails && !hasVerticalBar {
                detailsButton
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .padding(.horizontal, 20).padding(.top, 6)
            }
        }
        // iPhone Duo's cover screen: the floating buttons would sit under the
        // camera, so the system places them in its vertical bar instead.
        .toolbar {
            if hostsChromeInVerticalBar {
                ToolbarItem(placement: .cancellationAction) { closeButton }
                ToolbarItem(placement: .primaryAction) { detailsButton }
            }
        }
        .environment(\.layoutDirection, .tamrin)
        .colorScheme(.dark)
    }
}
