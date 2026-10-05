import Foundation
import Observation

@MainActor @Observable
final class MatchAwardModel {
    let eventID: UUID
    var award: MatchAward? {
        didSet {
            #if DEBUG
            if eventID == HomeDebugMemberFixture.matchAwardEventID, let award,
               let data = try? JSONEncoder().encode(award) {
                UserDefaults.standard.set(data, forKey: HomeDebugMemberFixture.matchAwardStateKey)
                Task { @MainActor in
                    NotificationCenter.default.post(name: .matchAwardDemoChanged, object: nil)
                }
            }
            #endif
        }
    }
    var isLoading = false
    var isSaving = false
    var error: String?
    var confirmation: String?
    private(set) var isDemo = false
    @ObservationIgnored private var revision = 0

    init(eventID: UUID) { self.eventID = eventID }

    func load() async {
        guard !isDemo, !isLoading, !isSaving else { return }
        let requestRevision = revision
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await MatchAwardService.shared.get(eventID)
            guard revision == requestRevision else { return }
            award = loaded
            error = nil
        } catch {
            self.error = String(localized: "تعذّر تحميل رجل المباراة. حاول مجددًا.")
        }
    }

    func nominate(_ ids: [UUID]) async {
        guard !isSaving, Set(ids).count == 3, award?.canNominate == true else { return }
        revision += 1
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            if isDemo, var updated = award {
                updated.players = updated.players.filter { ids.contains($0.id) }
                updated.status = .open
                updated.canNominate = false
                updated.canVote = true
                updated.closesAt = Date.now.addingTimeInterval(86400)
                award = updated
            } else {
                award = try await MatchAwardService.shared.nominate(eventID, players: ids)
            }
            confirmation = String(localized: "تم الترشيح وفتح التصويت")
            Haptics.success()
        } catch {
            isSaving = false
            await load()
            self.error = String(localized: "تعذّر نشر الترشيحات. حدّث القائمة وحاول مجددًا.")
        }
    }

    @discardableResult
    func vote(_ id: UUID) async -> Bool {
        guard !isSaving, let current = award, current.canVote,
              current.players.contains(where: { $0.id == id }) else { return false }
        guard current.closesAt.map({ $0 > .now }) != false else {
            await load()
            return false
        }
        revision += 1
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            if isDemo { award?.myVoteId = id }
            else { award = try await MatchAwardService.shared.vote(eventID, player: id) }
            confirmation = String(localized: "صوتك محفوظ، واختيارك يبقى سرّيًا")
            Haptics.success()
            return true
        } catch {
            isSaving = false
            await load()
            self.error = String(localized: "تعذّر حفظ صوتك. قد يكون التصويت انتهى؛ حدّث الصفحة وحاول مجددًا.")
            return false
        }
    }

    #if DEBUG
    static let scenarioModel: MatchAwardModel = {
        let model = MatchAwardModel(eventID: HomeDebugMemberFixture.matchAwardEventID)
        model.isDemo = true
        let saved = UserDefaults.standard.data(forKey: HomeDebugMemberFixture.matchAwardStateKey)
            .flatMap { try? JSONDecoder().decode(MatchAward.self, from: $0) }
        model.award = saved ?? HomeDebugMemberFixture.matchAwardInitialState()
        return model
    }()

    func resetScenario() {
        guard eventID == HomeDebugMemberFixture.matchAwardEventID else { return }
        confirmation = nil
        error = nil
        award = HomeDebugMemberFixture.matchAwardInitialState()
    }

    static func demo() -> MatchAwardModel {
        let model = MatchAwardModel(eventID: UUID(uuidString: "D4B00000-0000-4000-8000-000000000001")!)
        model.isDemo = true
        let names = ["لؤي الزهراني", "أحمد رشوان", "مراد الجهني", "خالد مسلمي", "عبدالرحمن الخزيم", "عماد العسيري"]
        model.award = MatchAward(eventId: model.eventID, title: "تمرين ليلة الخميس", status: .nomination,
            canNominate: true, canVote: false, players: names.enumerated().map { index, name in
                MatchAwardPlayer(id: HomeDebugMemberFixture.ownerPlayerID(at: index), name: name,
                    position: index == 1 ? "دفاع" : "وسط",
                    avatarURL: HomeDebugMemberFixture.DemoFaces.photo(at: index))
            })
        if ProcessInfo.processInfo.arguments.contains("-demoMatchAwardVote")
            || ProcessInfo.processInfo.arguments.contains("-demoMatchAwardResult")
            || ProcessInfo.processInfo.arguments.contains("-demoMatchAwardChosen") {
            if var updated = model.award {
                updated.players = Array(updated.players.prefix(3))
                updated.status = .open
                updated.canNominate = false
                updated.canVote = true
                updated.closesAt = Date.now.addingTimeInterval(86400)
                model.award = updated
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-demoMatchAwardChosen") {
            let chosen = model.award?.players.dropFirst().first?.id
            model.award?.myVoteId = chosen
        }
        if ProcessInfo.processInfo.arguments.contains("-demoMatchAwardResult") {
            let first = model.award?.players.first?.id
            model.award?.myVoteId = first
            model.finishDemo()
        }
        return model
    }
    func finishDemo() {
        guard isDemo, var updated = award, updated.status == .open else { return }
        updated.status = .closed
        updated.canVote = false
        updated.closesAt = .now
        for index in updated.players.indices {
            let isChosen = updated.players[index].id == updated.myVoteId
            updated.players[index].votes = isChosen ? 8 : 3
        }
        updated.totalVotes = updated.players.compactMap(\.votes).reduce(0, +)
        award = updated
    }
    #endif
}

extension Notification.Name {
    static let matchAwardDemoChanged = Notification.Name("matchAwardDemoChanged")
}
