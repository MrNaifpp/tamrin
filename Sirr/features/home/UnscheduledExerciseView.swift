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
    @State private var showsDetails = false
    let onCreate: () -> Void

    var body: some View { emptyContent }

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
            if !showsDetails {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.backward")
                        .frame(width: TamrinControlMetrics.glassIconContent,
                               height: TamrinControlMetrics.glassIconContent)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .accessibilityLabel("إغلاق")
                .padding(.horizontal, 20).padding(.top, 6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !showsDetails {
                Button { showsDetails = true } label: {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .frame(width: TamrinControlMetrics.glassIconContent,
                               height: TamrinControlMetrics.glassIconContent)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .accessibilityLabel("تفاصيل التمرين")
                .padding(.horizontal, 20).padding(.top, 6)
            }
        }
        .environment(\.layoutDirection, .tamrin)
        .colorScheme(.dark)
    }
}

extension PlanDraft {
    func newSessionValidationError(now: Date = .now) -> String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !locationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "حدد اسم التمرين والملعب.")
        }
        guard capacity > 0, totalVenueCost >= 0 else { return String(localized: "راجع عدد اللاعبين وقيمة الملعب.") }
        if scheduleKind == .oneOff {
            let calendar = Calendar.current
            let time = calendar.dateComponents([.hour, .minute], from: startTime)
            guard let start = calendar.date(bySettingHour: time.hour ?? 0,
                                            minute: time.minute ?? 0, second: 0, of: oneOffDate),
                  start > now else { return String(localized: "اختر وقتًا قادمًا للموعد.") }
        } else if weekdays.isEmpty {
            return String(localized: "اختر يومًا واحدًا على الأقل.")
        }
        return nil
    }
}
