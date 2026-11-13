import SwiftUI
import Combine

/// Lives between the registered-player count and the lineup. It never reserves
/// space on Home or adds an unrelated floating call to action.
struct MatchAwardEntryView<Fallback: View>: View {
    let eventID: UUID
    var artName: String
    private let fallback: Fallback
    @State private var award: MatchAward?
    @State private var presented = false
    @Environment(\.scenePhase) private var scenePhase

    init(eventID: UUID, artName: String, @ViewBuilder fallback: () -> Fallback) {
        self.eventID = eventID
        self.artName = artName
        self.fallback = fallback()
        #if DEBUG
        if eventID == HomeDebugMemberFixture.matchAwardEventID {
            _award = State(initialValue: MatchAwardModel.scenarioModel.award)
        }
        #endif
    }

    var body: some View {
        Group {
            if let award, award.status != .unavailable {
                Button { presented = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trophy")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("رجل المباراة")
                                .font(TamrinFont.font(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                            Text(statusText(award))
                                .font(TamrinFont.font(size: 13, weight: .regular))
                                .foregroundStyle(.white.opacity(0.62))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .tamrinGlassCard()
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                fallback
            }
        }
        .task(id: eventID) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .matchAwardDemoChanged)) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .eventPushReceived)) { _ in
            Task { await reload() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
        .fullScreenCover(isPresented: $presented, onDismiss: { Task { await reload() } }) {
            MatchAwardFlowView(eventID: eventID, artName: artName)
        }
    }

    private func statusText(_ award: MatchAward) -> String {
        switch award.status {
        case .nomination: return award.canNominate ? String(localized: "رشّح ثلاثة لاعبين") : String(localized: "بانتظار الترشيحات")
        case .open: return award.myVoteId == nil ? String(localized: "صوّت للاعبك") : String(localized: "تصويتك · بانتظار النتائج")
        case .closed: return String(localized: "عرض النتيجة")
        case .unavailable: return String(localized: "بانتظار الترشيحات")
        }
    }

    private func reload() async {
        do { award = try await MatchAwardService.shared.get(eventID) }
        catch { /* Preserve an already loaded action during a connection failure. */ }
    }
}
