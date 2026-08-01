import SwiftUI

/// Value types the reskinned Home feed reads, plus `HomeStore` — the real
/// integration layer that loads `WorkspaceService` / `EventService` /
/// `AuthService` records and maps them into these types, leaving the designer
/// views (which read this surface) essentially unchanged.
struct FeedTeam: Identifiable {
    let id: UUID
    let name: String
    let symbol: String
    let avatarData: Data?
    let memberCount: Int
    var inviteCode: String = "TMRN-000"
    /// The real shareable join link (Universal Link), from WorkspaceRecord.inviteURL.
    var inviteURL: URL? = nil
}

enum FeedTeamRole { case admin, member }
enum FeedCapacityPolicy { case waitlist, closed }
enum FeedScheduleKind { case recurring, oneOff }

/// Where a team trains. A custom venue is one only the team knows — the rest
/// house, the neighbourhood pitch — so it is typed in by hand; a rented one is
/// a commercial pitch that exists on the map, so it is searched for.
enum FeedVenueKind: String, Hashable, CaseIterable {
    case custom, rented

    var title: String {
        switch self {
        case .custom: "ملعب مخصص"
        case .rented: "ملعب مؤجر"
        }
    }

    var detail: String {
        switch self {
        case .custom: "ملعب معروف بينكم وخاص فيكم، مثل ملعب الاستراحة أو ملعب الحي."
        case .rented: "ملعب تجاري تستأجرونه لتمارينكم."
        }
    }

    var symbol: String {
        switch self {
        case .custom: "house.and.flag.fill"
        case .rented: "sportscourt.fill"
        }
    }
}

/// Scope selected by an organizer when saving edits to a recurring exercise.
/// An occurrence-only edit leaves the weekly template untouched, while a
/// series edit refreshes the template used to generate future occurrences.
enum EventEditScope {
    case occurrenceOnly
    case seriesTemplate

    var rpcValue: String {
        switch self {
        case .occurrenceOnly: "occurrence_only"
        case .seriesTemplate: "series_template"
        }
    }
}

// MARK: - Create-team drafts (mutable UI state for the CreateTeamFlow wizard)

struct TeamDraft {
    var teamName = ""
    var teamSymbol = "figure.soccer"
    var avatarData: Data?
    var plans: [PlanDraft] = []
    var startDate = Date.now
}

struct PlanDraft: Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var weekdays: Set<Int> = []
    var startTime = Calendar.current.date(from: DateComponents(hour: 20)) ?? .now
    var endTime = Calendar.current.date(from: DateComponents(hour: 21, minute: 30)) ?? .now
    var locationName = ""
    var locationAddress = ""
    /// Custom venues have no map entry, so the organizer may paste a Google
    /// Maps link instead. Optional, and only ever filled for `.custom`.
    var mapsURL = ""
    var venueKind: FeedVenueKind = .custom
    var latitude = 24.7136
    var longitude = 46.6753
    var capacity = 12
    var capacityPolicy: FeedCapacityPolicy = .waitlist
    /// Total venue rental cost. The per-player contribution is always derived
    /// from this value and `capacity`; organizers never type the contribution.
    var totalVenueCost = 0.0
    /// Every collection method the organizer accepts for this training session.
    /// One provider appears at most once; its draft carries the destination data.
    var paymentMethods: [PaymentMethodDraft] = []
    var scheduleKind: FeedScheduleKind = .recurring
    var oneOffDate = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    var publishLeadDays = 2
    var publishTime = Calendar.current.date(from: DateComponents(hour: 12)) ?? .now

    var pricePerPerson: Double {
        guard capacity > 0 else { return 0 }
        // `events.total_price` is stored in whole riyals, so derive from the
        // same rounded value the server will persist.
        return totalVenueCost.rounded() / Double(capacity)
    }
}

struct FeedTeamMember: Identifiable {
    let id: UUID
    let displayName: String
    let role: FeedTeamRole
    let isPending: Bool
}

/// Training-plan template a team runs. Backs the team-details page.
struct FeedPlan: Identifiable {
    let id: UUID
    let name: String
    let weekdays: [Int]        // 1 = Sunday … 7 = Saturday
    let startTime: Date
    let endTime: Date
    let startDate: Date
    let endDate: Date?
    let price: Double
    let totalVenueCost: Double
    let currency: String
    let capacity: Int
    let capacityPolicy: FeedCapacityPolicy
    let latitude: Double
    let longitude: Double
    let locationName: String
    let locationAddress: String
    /// The upcoming event this plan was synthesized from (edit target), and
    /// its weekly-series template when the event is recurring.
    var sourceEventID: UUID? = nil
    var sourceTemplateID: UUID? = nil
    var paymentMethods: [PaymentMethodDraft] = []
}

enum FeedRegStatus {
    case registered
    case paymentPending
    case waitlisted
}

enum FeedMemberResponse: String {
    case invited
    case declined
}

enum MemberEventParticipation {
    case available
    case full
    case registered
    case paymentPending
    case waitlisted
    case declined
    case cancelled
    case unavailable
}

struct FeedMember: Identifiable {
    let id: UUID
    let name: String
    var status: FeedRegStatus
    var userId: UUID? = nil
    var addedBy: UUID? = nil

    var paymentOwnerId: UUID? { userId ?? addedBy }
    var isGuest: Bool { userId == nil }
}

struct FeedOccurrence: Identifiable {
    let id: UUID
    let title: String
    let startAt: Date
    let locationName: String
    let capacity: Int
    let price: Double        // 0 == free
    var isCancelled: Bool
    let artIndex: Int        // cycles ExerciseArt1..3
    /// Weekly-series flags (rolling model: one upcoming occurrence at a time).
    var isRecurring: Bool = false
    var templateId: UUID? = nil
    var paymentMethodIds: [UUID] = []
    /// Nil means the organizer has not sent this exercise to the group yet.
    /// Existing rows are backfilled by the invitation migration so they keep
    /// their previous visibility.
    var publishedAt: Date? = nil
    var cancelledAt: Date? = nil
    var cancellationReasonCode: String? = nil
    var cancellationReasonText: String? = nil
    var memberResponse: FeedMemberResponse? = nil

    /// Compatibility convenience for surfaces that only need a representative
    /// method (the participant flow always uses `paymentMethodIds`).
    var paymentMethodId: UUID? { paymentMethodIds.first }
    var isPublished: Bool { publishedAt != nil }
    var hasCancellationReason: Bool {
        cancellationReasonText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || cancellationReasonCode != nil
    }
}

// MARK: - HomeStore (real backend-backed store)

@MainActor
@Observable
final class HomeStore {
    // Surface the designer views read (same names as the old mock).
    var teams: [FeedTeam] = []
    var selectedTeamID: UUID = UUID()          // dummy until the first workspace loads
    var occurrencesByTeam: [UUID: [FeedOccurrence]] = [:]
    var plansByTeam: [UUID: [FeedPlan]] = [:]
    var membersByTeam: [UUID: [FeedTeamMember]] = [:]
    var profileName: String = ""
    var playerPosition: String = ""
    var avatarData: Data? = nil
    var stcPayNumber: String? = nil
    var paymentMethodsByTeam: [UUID: [PaymentMethodRecord]] = [:]

    var isLoading = false
    var errorMessage: String?

    /// Set by DesignerHomeView so selection changes persist to AppState and the
    /// profile screen can sign out.
    var onSelectWorkspace: ((UUID?) -> Void)?
    var onLogout: (() -> Void)?
    /// Throws so the settings sheet can report the reason instead of silently
    /// dropping the user back to Home with the account still alive.
    var onDeleteAccount: (() async throws -> Void)?

    // Backend context / derived caches.
    private(set) var currentUserID: UUID?
    private var ownerByTeam: [UUID: UUID] = [:]
    private var avatarUrlRemote: String?
    /// Mapped roster + my status per event id (source for the detail page).
    private var rosterCache: [UUID: [FeedMember]] = [:]
    private var myEventStatus: [UUID: FeedRegStatus] = [:]
    private var rosterLoadFailedEventIDs: Set<UUID> = []
    private var memberResponseByEvent: [UUID: FeedMemberResponse] = [:]
    /// Organizer-only invitation responses, fetched for the cards currently
    /// visible on Home. Members never request or retain this list.
    private var memberResponseRecordsByEvent: [UUID: [EventMemberResponseRecord]] = [:]
    /// Original records are retained so editing a card opens that exact event,
    /// rather than the first synthesized plan in the workspace.
    private var eventRecordsByID: [UUID: EventRecord] = [:]

    /// Preview/testing stores skip all network calls.
    private let isPreview: Bool

    /// The member journey fixture is compiled only into Debug builds. These
    /// checks stay available in Release as constant-false helpers, keeping all
    /// backend guards easy to audit at each mutation boundary.
    private func isDebugMemberFixtureTeam(_ teamID: UUID) -> Bool {
        #if DEBUG
        return teamID == HomeDebugMemberFixture.teamID
        #else
        return false
        #endif
    }

    private func isDebugMemberFixtureEvent(_ eventID: UUID) -> Bool {
        #if DEBUG
        return eventID == HomeDebugMemberFixture.eventID
        #else
        return false
        #endif
    }

    // MARK: Derived (same surface the views used on the mock)
    var currentTeam: FeedTeam? { teams.first { $0.id == selectedTeamID } }
    /// Owner (admin) of the selected workspace — gates edit / series / delete /
    /// invite affordances. Server-side RPCs enforce the same rule.
    var isCurrentTeamOwner: Bool {
        guard let uid = currentUserID else { return false }
        return ownerByTeam[selectedTeamID] == uid
    }
    var occurrences: [FeedOccurrence] { occurrencesByTeam[selectedTeamID] ?? [] }
    var teamPlans: [FeedPlan] { plansByTeam[selectedTeamID] ?? [] }
    var teamMembers: [FeedTeamMember] { membersByTeam[selectedTeamID] ?? [] }
    func methodsForCurrentTeam() -> [PaymentMethodRecord] {
        let newestFirst = (paymentMethodsByTeam[selectedTeamID] ?? []).sorted { $0.createdAt > $1.createdAt }
        var seen: Set<PaymentProvider> = []
        return newestFirst.filter { seen.insert($0.provider).inserted }
    }

    func roster(for occurrence: FeedOccurrence) -> [FeedMember] { rosterCache[occurrence.id] ?? [] }
    func registeredCount(for occurrence: FeedOccurrence) -> Int {
        roster(for: occurrence).filter { $0.status != .waitlisted }.count
    }
    func waitlistCount(for occurrence: FeedOccurrence) -> Int {
        roster(for: occurrence).filter { $0.status == .waitlisted }.count
    }
    func myRegistration(for occurrence: FeedOccurrence) -> FeedMember? {
        guard let status = myEventStatus[occurrence.id] else { return nil }
        return FeedMember(id: currentUserID ?? occurrence.id, name: profileName.isEmpty ? "أنا" : profileName, status: status)
    }
    func declinedResponses(for occurrence: FeedOccurrence) -> [EventMemberResponseRecord] {
        guard isCurrentTeamOwner else { return [] }
        return (memberResponseRecordsByEvent[occurrence.id] ?? []).filter {
            $0.status == FeedMemberResponse.declined.rawValue
        }
    }

    func participationState(for occurrence: FeedOccurrence) -> MemberEventParticipation {
        if occurrence.isCancelled { return .cancelled }
        if rosterLoadFailedEventIDs.contains(occurrence.id), myEventStatus[occurrence.id] == nil {
            return .unavailable
        }
        switch myEventStatus[occurrence.id] {
        case .registered: return .registered
        case .paymentPending: return .paymentPending
        case .waitlisted: return .waitlisted
        case nil:
            if memberResponseByEvent[occurrence.id] == .declined || occurrence.memberResponse == .declined {
                return .declined
            }
            let isFull = occurrence.capacity > 0 && registeredCount(for: occurrence) >= occurrence.capacity
            return isFull ? .full : .available
        }
    }

    // MARK: Init
    init() { isPreview = false }
    private init(previewSeed: Bool) { isPreview = true; seedPreview() }
    static var preview: HomeStore { HomeStore(previewSeed: true) }

    #if DEBUG
    /// Installs a realistic non-admin team beside live workspaces without ever
    /// creating corresponding backend records. Existing local participation is
    /// preserved across refreshes so register/decline/withdraw can be tested.
    private func installDebugMemberFixtureIfNeeded() {
        // Off unless the scheme asks for it: see HomeDebugMemberFixture.isEnabled.
        guard HomeDebugMemberFixture.isEnabled else { return }

        let teamID = HomeDebugMemberFixture.teamID
        if !teams.contains(where: { $0.id == teamID }) {
            teams.append(HomeDebugMemberFixture.team)
        }
        ownerByTeam[teamID] = HomeDebugMemberFixture.organizerID
        membersByTeam[teamID] = HomeDebugMemberFixture.members(
            currentUserID: currentUserID,
            profileName: profileName
        )

        guard occurrencesByTeam[teamID] == nil else { return }
        let occurrence = HomeDebugMemberFixture.occurrence()
        occurrencesByTeam[teamID] = [occurrence]
        plansByTeam[teamID] = [HomeDebugMemberFixture.plan(for: occurrence)]
        paymentMethodsByTeam[teamID] = []
        rosterCache[occurrence.id] = HomeDebugMemberFixture.roster()
        memberResponseByEvent[occurrence.id] = .invited
    }
    #endif

    // MARK: Bootstrap / loads
    func bootstrap(initialWorkspaceID: UUID?) async {
        guard !isPreview else { return }
        isLoading = true
        defer { isLoading = false }
        await loadProfile()          // also captures currentUserID
        await loadWorkspaces(preferred: initialWorkspaceID)
    }

    func loadProfile() async {
        guard !isPreview else { return }
        if let profile = (try? await AuthService.shared.getCurrentUserProfile()) ?? nil {
            currentUserID = profile.userId
            profileName = profile.name
            playerPosition = profile.position
            stcPayNumber = profile.stcPayNumber
            avatarUrlRemote = profile.avatarUrl
        }
    }

    /// Full refresh — workspace list + the selected team's events / members /
    /// rosters. Used by pull-to-refresh, foreground return, and after mutations.
    func refresh() async {
        guard !isPreview, !isDebugMemberFixtureTeam(selectedTeamID) else { return }
        await loadWorkspaces(preferred: selectedTeamID)
    }

    func loadWorkspaces(preferred: UUID?) async {
        guard !isPreview else { return }
        do {
            let records = try await WorkspaceService.shared.getMyWorkspaces()
            teams = records.map(mapTeam)
            ownerByTeam = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.ownerId) })
            #if DEBUG
            installDebugMemberFixtureIfNeeded()
            #endif
            if let pref = preferred, teams.contains(where: { $0.id == pref }) {
                selectedTeamID = pref
            } else if let first = teams.first {
                selectedTeamID = first.id
                onSelectWorkspace?(first.id)
            } else {
                onSelectWorkspace?(nil)
            }
            if !teams.isEmpty { await loadSelectedTeamData() }
        } catch {
            #if DEBUG
            // The local member journey remains testable when the development
            // backend is unavailable; no fixture operation depends on it.
            installDebugMemberFixtureIfNeeded()
            if let preferred,
               teams.contains(where: { $0.id == preferred }) {
                selectedTeamID = preferred
            } else if teams.count == 1,
                      let fixture = teams.first,
                      isDebugMemberFixtureTeam(fixture.id) {
                selectedTeamID = fixture.id
                onSelectWorkspace?(fixture.id)
            }
            #endif
            errorMessage = error.localizedDescription
        }
    }

    /// Loads the selected workspace's events, members, a synthesized plan, and
    /// participant rosters for the events shown on Home.
    func loadSelectedTeamData() async {
        guard !isPreview, !isDebugMemberFixtureTeam(selectedTeamID) else { return }
        let id = selectedTeamID
        let isOwner = currentUserID.map { ownerByTeam[id] == $0 } ?? false

        if isOwner {
            paymentMethodsByTeam[id] = (try? await ManualPaymentService.shared.getMyWorkspaceMethods(workspaceId: id)) ?? []
        } else {
            // Destination details are intentionally member-gated through the
            // event RPC; members never receive the organizer's whole catalog.
            paymentMethodsByTeam[id] = []
        }

        let events = (try? await EventService.shared.getWorkspaceEvents(workspaceId: id)) ?? []
        for event in events { eventRecordsByID[event.id] = event }
        occurrencesByTeam[id] = events.map(mapOccurrence)
        for event in events {
            if let response = event.myResponseStatus.flatMap(FeedMemberResponse.init(rawValue:)) {
                memberResponseByEvent[event.id] = response
            } else {
                memberResponseByEvent[event.id] = nil
            }
        }
        plansByTeam[id] = events.first.map { [synthesizePlan(from: $0)] } ?? []

        if let detail = try? await WorkspaceService.shared.getWorkspace(id: id) {
            membersByTeam[id] = detail.members.map(mapMember)
        }

        // Rosters for the visible cards (Home shows counts on each poster).
        let visible = Array(events.prefix(6))
        await withTaskGroup(of: (UUID, [ParticipantRecord]?).self) { group in
            for ev in visible {
                group.addTask {
                    do {
                        return (ev.id, try await EventService.shared.getEventParticipants(eventId: ev.id))
                    } catch {
                        return (ev.id, nil)
                    }
                }
            }
            for await (eventId, parts) in group {
                if let parts {
                    applyParticipants(parts, to: eventId)
                } else if rosterCache[eventId] == nil {
                    rosterLoadFailedEventIDs.insert(eventId)
                }
            }
        }

        // Apology reasons are private organizer data. Clear any prior values
        // first, then call the owner-only RPC solely for the visible cards.
        for event in events { memberResponseRecordsByEvent[event.id] = nil }
        if isOwner {
            await withTaskGroup(of: (UUID, [EventMemberResponseRecord]).self) { group in
                for event in visible {
                    group.addTask {
                        let responses = (try? await EventService.shared.getEventMemberResponses(eventId: event.id)) ?? []
                        return (event.id, responses)
                    }
                }
                for await (eventId, responses) in group {
                    memberResponseRecordsByEvent[eventId] = responses
                }
            }
        }
    }

    func reloadRoster(_ eventId: UUID) async {
        guard !isPreview, !isDebugMemberFixtureEvent(eventId) else { return }
        do {
            let parts = try await EventService.shared.getEventParticipants(eventId: eventId)
            applyParticipants(parts, to: eventId)
        } catch {
            // A transient fetch failure must not turn a registered member into
            // an apparently available one. Keep the last known roster/status.
            if rosterCache[eventId] == nil {
                rosterLoadFailedEventIDs.insert(eventId)
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Refreshes the organizer-only invitation responses for any event opened
    /// in detail, including events reached by a deep link outside Home's first
    /// six cards. Failures preserve the last known private response cache.
    func reloadMemberResponses(_ eventId: UUID) async {
        guard !isPreview, isCurrentTeamOwner else { return }
        do {
            memberResponseRecordsByEvent[eventId] = try await EventService.shared
                .getEventMemberResponses(eventId: eventId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyParticipants(_ parts: [ParticipantRecord], to eventId: UUID) {
        rosterLoadFailedEventIDs.remove(eventId)
        rosterCache[eventId] = parts.map {
            FeedMember(id: $0.participantId,
                       name: $0.displayName ?? $0.guestName ?? "—",
                       status: $0.isPending ? .paymentPending : .registered,
                       userId: $0.userId,
                       addedBy: $0.addedBy)
        }
        if let mine = parts.first(where: { $0.userId == currentUserID && $0.guestName == nil }) {
            myEventStatus[eventId] = mine.isPending ? .paymentPending : .registered
        } else {
            myEventStatus[eventId] = nil
        }
    }

    // MARK: Team selection / lifecycle
    func selectTeam(_ id: UUID) {
        guard id != selectedTeamID else { return }
        selectedTeamID = id
        onSelectWorkspace?(id)
        Task { await loadSelectedTeamData() }
    }

    /// Deletes (owner) or leaves (member) a workspace. Optimistically removes it
    /// locally; Home falls back to WelcomeView when none remain.
    func deleteTeam(_ id: UUID) {
        let isLocalDebugFixture = isDebugMemberFixtureTeam(id)
        let isOwner = ownerByTeam[id] == currentUserID
        teams.removeAll { $0.id == id }
        occurrencesByTeam[id] = nil
        plansByTeam[id] = nil
        membersByTeam[id] = nil
        paymentMethodsByTeam[id] = nil
        eventRecordsByID = eventRecordsByID.filter { $0.value.workspaceId != id }
        #if DEBUG
        if isLocalDebugFixture {
            let eventID = HomeDebugMemberFixture.eventID
            ownerByTeam[id] = nil
            rosterCache[eventID] = nil
            myEventStatus[eventID] = nil
            memberResponseByEvent[eventID] = nil
            memberResponseRecordsByEvent[eventID] = nil
        }
        #endif
        if selectedTeamID == id, let next = teams.first?.id {
            selectedTeamID = next
            onSelectWorkspace?(next)
        } else if teams.isEmpty {
            onSelectWorkspace?(nil)
        }
        guard !isPreview, !isLocalDebugFixture else { return }
        Task {
            do {
                if isOwner { try await WorkspaceService.shared.deleteWorkspace(id: id) }
                else { try await WorkspaceService.shared.leaveWorkspace(id: id) }
            } catch { errorMessage = error.localizedDescription }
            // Re-sync from the server either way — confirms the delete, or
            // restores the row if the server refused it.
            await refresh()
        }
    }

    /// Live invite-code preview for the join screen.
    func invitePreview(code: String) async -> WorkspaceInvitePreview? {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isPreview, c.count >= 4 else { return nil }
        return try? await WorkspaceService.shared.getInvitePreview(code: c)
    }

    /// Joins a workspace by invite code. Returns false on an invalid/unknown code.
    @discardableResult
    func join(code rawCode: String) async -> Bool {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !isPreview else { return false }
        do {
            let wsId = try await WorkspaceService.shared.joinWorkspace(code: code)
            await loadWorkspaces(preferred: wsId)
            return true
        } catch {
            return false
        }
    }

    /// Creates a workspace from the wizard draft, then turns each planned session
    /// into a real event. A failed event rolls the new workspace back, so the UI
    /// never reports a group as ready without its sessions and payment methods.
    @discardableResult
    func createTeam(from draft: TeamDraft) async throws -> FeedTeam {
        let name = draft.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isPreview else {
            throw NSError(
                domain: "HomeStore.CreateTeam",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "اكتب اسم المجموعة أولًا."]
            )
        }
        var createdWorkspace: WorkspaceRecord?
        do {
            let ws = try await WorkspaceService.shared.createWorkspace(name: name)
            createdWorkspace = ws
            try await createEvents(from: draft.plans, startDate: draft.startDate, in: ws.id)

            let team = mapTeam(ws)
            teams.append(team)
            ownerByTeam[ws.id] = ws.ownerId
            membersByTeam[ws.id] = []
            selectedTeamID = ws.id
            onSelectWorkspace?(ws.id)
            await loadSelectedTeamData()      // pick up the events just created
            return team
        } catch {
            errorMessage = error.localizedDescription
            if let workspace = createdWorkspace {
                try? await WorkspaceService.shared.deleteWorkspace(id: workspace.id)
                paymentMethodsByTeam[workspace.id] = nil
            }
            throw error
        }
    }

    /// Adds session(s) to the current workspace from one composed plan (same
    /// mapping as the wizard), then reloads the feed so they appear on Home.
    func addSession(_ plan: PlanDraft) async throws {
        guard !isPreview, !isDebugMemberFixtureTeam(selectedTeamID) else { return }
        do {
            try await createEvents(from: [plan], startDate: Date(), in: selectedTeamID)
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
        await loadSelectedTeamData()
    }

    /// Applies a composed plan back onto an existing event. The server performs
    /// the occurrence + optional series-template edit atomically and authorizes
    /// the current workspace owner, so the client can never leave half an edit.
    func updateSession(
        _ plan: PlanDraft,
        eventID: UUID,
        templateID: UUID? = nil,
        scope: EventEditScope = .occurrenceOnly
    ) async throws {
        guard !isPreview, !isDebugMemberFixtureEvent(eventID) else { return }
        let cal = Calendar(identifier: .gregorian)
        let start: Date
        if scope == .occurrenceOnly,
           templateID != nil,
           let originalStart = eventRecordsByID[eventID]?.startDate {
            // Editing one concrete occurrence changes its clock time without
            // re-selecting a different calendar occurrence of the weekday.
            start = combine(day: originalStart, time: plan.startTime, cal: cal)
        } else if plan.scheduleKind == .oneOff {
            start = combine(day: plan.oneOffDate, time: plan.startTime, cal: cal)
        } else if let weekday = plan.weekdays.sorted().first {
            let anchor = eventRecordsByID[eventID]
                .map { cal.startOfDay(for: $0.startDate) }
                ?? Date()
            start = nextWeekday(weekday, at: plan.startTime, onOrAfter: anchor, cal: cal)
        } else {
            start = combine(day: Date(), time: plan.startTime, cal: cal)
        }
        var end = combine(day: start, time: plan.endTime, cal: cal)
        if end <= start { end = cal.date(byAdding: .hour, value: 1, to: start) ?? start }
        do {
            let paymentMethodIds = try await persistPaymentMethods(for: plan, workspaceId: selectedTeamID)
            try await EventService.shared.updateEventWithScope(
                eventId: eventID,
                scope: scope.rpcValue,
                name: plan.name.trimmingCharacters(in: .whitespacesAndNewlines),
                location: plan.locationName,
                startDate: start,
                endDate: end,
                maxParticipants: plan.capacity,
                totalPrice: Int(plan.totalVenueCost.rounded()),
                latitude: plan.latitude,
                longitude: plan.longitude,
                paymentMethodIds: paymentMethodIds
            )
        } catch {
            errorMessage = error.localizedDescription
            await loadSelectedTeamData()
            throw error
        }
        await loadSelectedTeamData()
    }

    /// Maps each wizard plan to real event(s). Backend recurrence is weekly-only,
    /// so a recurring plan with multiple weekdays becomes one weekly series per
    /// day; a one-off plan becomes a single non-recurring event.
    private func createEvents(from plans: [PlanDraft], startDate: Date, in workspaceId: UUID) async throws {
        let cal = Calendar(identifier: .gregorian)
        let base = max(Date(), startDate)
        var createdEvents: [EventRecord] = []

        do {
            for plan in plans {
                let name = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let paymentMethodIds = try await persistPaymentMethods(for: plan, workspaceId: workspaceId)

                if plan.scheduleKind == .oneOff {
                    let start = combine(day: plan.oneOffDate, time: plan.startTime, cal: cal)
                    createdEvents.append(
                        try await createOneEvent(
                            plan,
                            name: name,
                            start: start,
                            recurrence: "none",
                            paymentMethodIds: paymentMethodIds,
                            in: workspaceId,
                            cal: cal
                        )
                    )
                } else {
                    for weekday in plan.weekdays.sorted() {
                        let start = nextWeekday(weekday, at: plan.startTime, onOrAfter: base, cal: cal)
                        createdEvents.append(
                            try await createOneEvent(
                                plan,
                                name: name,
                                start: start,
                                recurrence: "weekly",
                                paymentMethodIds: paymentMethodIds,
                                in: workspaceId,
                                cal: cal
                            )
                        )
                    }
                }
            }
        } catch {
            for event in createdEvents.reversed() {
                if let templateId = event.templateId {
                    try? await EventService.shared.endRecurrence(templateId: templateId)
                }
                try? await EventService.shared.deleteEvent(eventId: event.id)
            }
            throw error
        }
    }

    private func createOneEvent(
        _ plan: PlanDraft,
        name: String,
        start: Date,
        recurrence: String,
        paymentMethodIds: [UUID],
        in workspaceId: UUID,
        cal: Calendar
    ) async throws -> EventRecord {
        var end = combine(day: start, time: plan.endTime, cal: cal)
        if end <= start { end = cal.date(byAdding: .hour, value: 1, to: start) ?? start }
        return try await EventService.shared.createEvent(
            workspaceId: workspaceId,
            name: name,
            location: plan.locationName,
            description: "",
            startDate: start,
            endDate: end,
            imageUrl: nil,
            maxParticipants: plan.capacity,
            totalPrice: Int(plan.totalVenueCost.rounded()),
            pricePerPerson: plan.pricePerPerson,
            latitude: plan.latitude,
            longitude: plan.longitude,
            recurrence: recurrence,
            paymentMethodIds: paymentMethodIds
        )
    }

    /// Saves every selected reusable destination and returns the immutable ids
    /// attached to this event. Provider uniqueness keeps the picker and server
    /// contract deterministic.
    private func persistPaymentMethods(for plan: PlanDraft, workspaceId: UUID) async throws -> [UUID] {
        guard plan.totalVenueCost > 0 else { return [] }
        let drafts = plan.paymentMethods
        guard !drafts.isEmpty,
              drafts.allSatisfy(\.isValid),
              Set(drafts.map(\.provider)).count == drafts.count else {
            throw NSError(
                domain: "HomeStore.Payment",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "أضف وسيلة دفع صحيحة واحدة على الأقل قبل حفظ التمرين."]
            )
        }

        var methods = paymentMethodsByTeam[workspaceId] ?? []
        var ids: [UUID] = []
        for draft in drafts {
            let record = try await ManualPaymentService.shared.upsertWorkspaceMethod(
                workspaceId: workspaceId,
                draft: draft
            )
            methods.removeAll { $0.id == record.id }
            methods.append(record)
            ids.append(record.id)
        }
        paymentMethodsByTeam[workspaceId] = methods
        return ids
    }

    /// Next date matching `weekday` (1=Sun…7=Sat) at `time`, on or after `base`.
    private func nextWeekday(_ weekday: Int, at time: Date, onOrAfter base: Date, cal: Calendar) -> Date {
        let t = cal.dateComponents([.hour, .minute], from: time)
        var day = cal.startOfDay(for: base)
        for _ in 0..<8 {
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = t.hour; comps.minute = t.minute
            if let candidate = cal.date(from: comps),
               cal.component(.weekday, from: candidate) == weekday, candidate >= base {
                return candidate
            }
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return base
    }

    private func combine(day: Date, time: Date, cal: Calendar) -> Date {
        let d = cal.dateComponents([.year, .month, .day], from: day)
        let t = cal.dateComponents([.hour, .minute], from: time)
        var c = DateComponents()
        c.year = d.year; c.month = d.month; c.day = d.day; c.hour = t.hour; c.minute = t.minute
        return cal.date(from: c) ?? day
    }

    // MARK: Registration (event participation)

    /// Outcome of a registration attempt, for the register sheet to render.
    enum RegistrationOutcome {
        case success
        case failure(String)
    }

    /// Sends this exact exercise to every current member of the workspace.
    /// The server operation is idempotent, so a double tap never duplicates
    /// invitations or push notifications.
    func publish(_ occurrence: FeedOccurrence) async -> RegistrationOutcome {
        guard isCurrentTeamOwner else { return .failure("هذا الإجراء متاح لمشرف المجموعة فقط.") }
        if isPreview {
            updateOccurrence(occurrence.id) { $0.publishedAt = .now }
            return .success
        }
        do {
            try await EventService.shared.publishEvent(eventId: occurrence.id)
            await loadSelectedTeamData()
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Cancels only the visible occurrence. A recurring template remains live
    /// and can generate the following week's exercise as usual.
    func skip(
        _ occurrence: FeedOccurrence,
        reasonCode: String?,
        reasonText: String?
    ) async -> RegistrationOutcome {
        guard isCurrentTeamOwner else { return .failure("هذا الإجراء متاح لمشرف المجموعة فقط.") }
        if isPreview {
            updateOccurrence(occurrence.id) {
                $0.cancelledAt = .now
                $0.isCancelled = true
                $0.cancellationReasonCode = reasonCode
                $0.cancellationReasonText = reasonText
            }
            return .success
        }
        do {
            try await EventService.shared.cancelEventOccurrence(
                eventId: occurrence.id,
                reasonCode: reasonCode,
                reasonText: reasonText
            )
            await loadSelectedTeamData()
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Records an optional apology reason and frees any seat/payment request
    /// held by the current member in one server-side transaction.
    func decline(
        _ occurrence: FeedOccurrence,
        reasonCode: String?,
        reasonText: String?
    ) async -> RegistrationOutcome {
        if isPreview || isDebugMemberFixtureEvent(occurrence.id) {
            removeMe(from: occurrence)
            memberResponseByEvent[occurrence.id] = .declined
            updateOccurrence(occurrence.id) { $0.memberResponse = .declined }
            return .success
        }
        do {
            try await EventService.shared.declineEvent(
                eventId: occurrence.id,
                reasonCode: reasonCode,
                reasonText: reasonText
            )
            memberResponseByEvent[occurrence.id] = .declined
            await loadSelectedTeamData()
            return .success
        } catch {
            await reloadRoster(occurrence.id)
            return .failure(error.localizedDescription)
        }
    }

    func confirmPayment(for member: FeedMember, in occurrence: FeedOccurrence) async -> RegistrationOutcome {
        guard let creatorId = currentUserID,
              let joinerId = member.userId,
              isCurrentTeamOwner else {
            return .failure("لا يمكن تأكيد هذه الدفعة.")
        }
        do {
            try await STCPayService.shared.confirmPayment(
                eventId: occurrence.id,
                joinerId: joinerId,
                creatorId: creatorId
            )
            await reloadRoster(occurrence.id)
            return .success
        } catch {
            await reloadRoster(occurrence.id)
            return .failure("تعذر تأكيد الدفعة. حاول مرة أخرى.")
        }
    }

    func rejectPayment(for member: FeedMember, in occurrence: FeedOccurrence) async -> RegistrationOutcome {
        guard let creatorId = currentUserID,
              let joinerId = member.userId,
              isCurrentTeamOwner else {
            return .failure("لا يمكن رفض هذه الدفعة.")
        }
        do {
            _ = try await STCPayService.shared.rejectPayment(
                eventId: occurrence.id,
                joinerId: joinerId,
                creatorId: creatorId
            )
            await reloadRoster(occurrence.id)
            return .success
        } catch {
            await reloadRoster(occurrence.id)
            return .failure("تعذر رفض الدفعة. حاول مرة أخرى.")
        }
    }

    func paymentDestination(for occurrence: FeedOccurrence) async throws -> PaymentDestination {
        #if DEBUG
        if isDebugMemberFixtureEvent(occurrence.id) {
            return HomeDebugMemberFixture.destination(for: occurrence)
        }
        #endif
        return try await ManualPaymentService.shared.getEventDestination(eventId: occurrence.id)
    }

    /// Records the transfer after the player has reviewed the selected method.
    /// The resulting seats are payment-pending, not waitlisted.
    func submitRegistration(
        guests: [String],
        for occurrence: FeedOccurrence,
        expectedDestination: PaymentDestination
    ) async -> RegistrationOutcome {
        let cleanGuests = guests.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !isPreview else {
            appendMe(to: occurrence)
            appendGuests(cleanGuests, to: occurrence.id)
            return .success
        }
        #if DEBUG
        if isDebugMemberFixtureEvent(occurrence.id) {
            guard expectedDestination.eventId == occurrence.id,
                  expectedDestination.selectedMethod != nil else {
                return .failure("اختر وسيلة الدفع أولًا.")
            }
            appendMe(to: occurrence, as: .paymentPending)
            appendGuests(cleanGuests, to: occurrence.id)
            memberResponseByEvent[occurrence.id] = nil
            updateOccurrence(occurrence.id) { $0.memberResponse = nil }
            return .success
        }
        #endif
        guard currentUserID != nil else { return .failure("يجب تسجيل الدخول أولاً.") }
        do {
            let result = try await ManualPaymentService.shared.submitPayment(
                eventId: occurrence.id,
                guestNames: cleanGuests,
                expectedDestination: expectedDestination
            )
            await reloadRoster(occurrence.id)
            switch result {
            case .submitted, .alreadyJoined:
                memberResponseByEvent[occurrence.id] = nil
                updateOccurrence(occurrence.id) { $0.memberResponse = nil }
                return .success
            case .seatsFull:
                return .failure("اكتملت المقاعد لهذا التمرين.")
            case .creatorMissingPaymentMethod:
                return .failure("منظّم المجموعة لم يضف وسيلة دفع لهذا التمرين بعد.")
            case .registrationClosed:
                return .failure("التسجيل مقفل لهذا التمرين.")
            case .eventTermsChanged:
                return .failure("غيّر المشرف مبلغ التمرين أو وسيلة الدفع. أغلق النافذة وافتحها مجددًا لمراجعة البيانات الجديدة.")
            }
        } catch {
            await reloadRoster(occurrence.id)
            return .failure(error.localizedDescription)
        }
    }

    /// Withdraw through the server operation that matches the current state,
    /// so pending payments, confirmed seats, and waitlist entries stay distinct.
    func withdraw(from occurrence: FeedOccurrence) {
        let status = myEventStatus[occurrence.id]
        removeMe(from: occurrence)
        guard !isPreview,
              !isDebugMemberFixtureEvent(occurrence.id),
              let uid = currentUserID else { return }
        Task {
            do {
                switch status {
                case .paymentPending:
                    _ = try await STCPayService.shared.cancelPending(eventId: occurrence.id, userId: uid)
                case .waitlisted:
                    try await STCPayService.shared.leaveWaitlist(eventId: occurrence.id, userId: uid)
                case .registered:
                    try await EventService.shared.leaveEvent(eventId: occurrence.id)
                case nil:
                    break
                }
            } catch { errorMessage = error.localizedDescription }
            await reloadRoster(occurrence.id)
        }
    }

    private func appendMe(to occurrence: FeedOccurrence, as explicitStatus: FeedRegStatus? = nil) {
        guard myEventStatus[occurrence.id] == nil else { return }
        var list = rosterCache[occurrence.id] ?? []
        let registered = list.filter { $0.status == .registered }.count
        let status: FeedRegStatus = explicitStatus
            ?? ((occurrence.capacity > 0 && registered >= occurrence.capacity) ? .waitlisted : .registered)
        list.append(
            FeedMember(
                id: currentUserID ?? UUID(),
                name: profileName.isEmpty ? "أنا" : profileName,
                status: status,
                userId: currentUserID
            )
        )
        rosterCache[occurrence.id] = list
        myEventStatus[occurrence.id] = status
    }

    private func appendGuests(_ names: [String], to eventId: UUID) {
        guard !names.isEmpty else { return }
        var list = rosterCache[eventId] ?? []
        for name in names { list.append(FeedMember(id: UUID(), name: name, status: .registered)) }
        rosterCache[eventId] = list
    }

    private func removeMe(from occurrence: FeedOccurrence) {
        myEventStatus[occurrence.id] = nil
        if var list = rosterCache[occurrence.id] {
            let myDisplayName = profileName.isEmpty ? "أنا" : profileName
            if let idx = list.firstIndex(where: {
                ($0.userId != nil && $0.userId == currentUserID) || $0.name == myDisplayName
            }) {
                list.remove(at: idx)
            }
            rosterCache[occurrence.id] = list
        }
    }

    private func updateOccurrence(_ eventID: UUID, mutate: (inout FeedOccurrence) -> Void) {
        for teamID in occurrencesByTeam.keys {
            guard let index = occurrencesByTeam[teamID]?.firstIndex(where: { $0.id == eventID }) else { continue }
            mutate(&occurrencesByTeam[teamID]![index])
            return
        }
    }

    /// Builds the editor draft for the exact Home card the organizer selected.
    func editDraft(for occurrence: FeedOccurrence) -> PlanDraft? {
        guard let event = eventRecordsByID[occurrence.id] else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        var draft = PlanDraft()
        draft.name = event.name
        draft.weekdays = [calendar.component(.weekday, from: event.startDate)]
        draft.startTime = event.startDate
        draft.endTime = event.endDate
            ?? calendar.date(byAdding: .hour, value: 1, to: event.startDate)
            ?? event.startDate
        draft.locationName = event.location
        draft.latitude = event.latitude ?? draft.latitude
        draft.longitude = event.longitude ?? draft.longitude
        draft.capacity = event.maxParticipants ?? draft.capacity
        draft.totalVenueCost = Double(event.totalPrice ?? 0)
        draft.scheduleKind = (event.isRecurring ?? false) ? .recurring : .oneOff
        draft.oneOffDate = event.startDate
        let methodIDs = event.paymentMethodIds.isEmpty
            ? event.paymentMethodId.map { [$0] } ?? []
            : event.paymentMethodIds
        draft.paymentMethods = methodIDs.compactMap { id in
            paymentMethodsByTeam[event.workspaceId ?? selectedTeamID]?.first { $0.id == id }
        }.map(PaymentMethodDraft.init(record:))
        return draft
    }

    /// Resolves a notification deep link into the live Home occurrence,
    /// switching workspaces first when the invitation belongs elsewhere.
    func occurrenceForDeepLink(eventID: UUID) async throws -> FeedOccurrence? {
        if let cached = occurrences.first(where: { $0.id == eventID }) { return cached }
        #if DEBUG
        if isDebugMemberFixtureEvent(eventID),
           let fixtureOccurrence = occurrencesByTeam[HomeDebugMemberFixture.teamID]?
            .first(where: { $0.id == eventID }) {
            selectedTeamID = HomeDebugMemberFixture.teamID
            onSelectWorkspace?(HomeDebugMemberFixture.teamID)
            return fixtureOccurrence
        }
        #endif
        guard !isPreview else { return nil }

        let event = try await EventService.shared.getEventById(eventID)
        guard let workspaceID = event.workspaceId else { return nil }

        // Revalidate membership so a newly joined workspace can be selected,
        // while a public event link never borrows the role of another group.
        let workspaceRecords = try await WorkspaceService.shared.getMyWorkspaces()
        guard workspaceRecords.contains(where: { $0.id == workspaceID }) else {
            return nil
        }
        teams = workspaceRecords.map(mapTeam)
        ownerByTeam = Dictionary(uniqueKeysWithValues: workspaceRecords.map { ($0.id, $0.ownerId) })
        selectedTeamID = workspaceID
        onSelectWorkspace?(workspaceID)

        await loadSelectedTeamData()
        eventRecordsByID[event.id] = event

        // Upcoming events resolve from the refreshed feed. A cancelled or just
        // ended occurrence can fall outside that query but still has a valid
        // notification destination, so map the resolved record directly.
        return occurrences.first(where: { $0.id == eventID }) ?? mapOccurrence(event)
    }

    // MARK: Profile
    /// Optimistically applies the profile edit, then persists name / position /
    /// avatar. STC Pay number is edited elsewhere.
    func saveProfile(name: String, avatarData: Data?, playerPosition: String) {
        profileName = name
        self.playerPosition = playerPosition
        if let avatarData { self.avatarData = avatarData }
        guard !isPreview else { return }
        Task {
            var newUrl: String? = avatarUrlRemote
            if let data = avatarData, let uid = currentUserID,
               let uploaded = await AuthService.shared.uploadAvatar(userId: uid, imageData: data) {
                newUrl = uploaded
                avatarUrlRemote = uploaded
            }
            try? await AuthService.shared.updateProfile(name: name, position: playerPosition, avatarUrl: newUrl)
        }
    }

    // MARK: Mappers
    private func mapTeam(_ ws: WorkspaceRecord) -> FeedTeam {
        FeedTeam(id: ws.id, name: ws.name, symbol: "figure.soccer", avatarData: nil,
                 memberCount: ws.memberCount ?? 0, inviteCode: ws.inviteCode ?? "",
                 inviteURL: ws.inviteURL)
    }

    private func mapMember(_ m: WorkspaceMemberRecord) -> FeedTeamMember {
        FeedTeamMember(id: m.userId, displayName: m.displayName ?? "عضو",
                       role: m.isOwner ? .admin : .member, isPending: false)
    }

    private func mapOccurrence(_ ev: EventRecord) -> FeedOccurrence {
        let methodIDs = ev.paymentMethodIds.isEmpty
            ? ev.paymentMethodId.map { [$0] } ?? []
            : ev.paymentMethodIds
        return FeedOccurrence(id: ev.id, title: ev.name, startAt: ev.startDate,
                              locationName: ev.location, capacity: ev.maxParticipants ?? 0,
                              price: ev.pricePerPerson ?? Double(ev.totalPrice ?? 0),
                              isCancelled: ev.cancelledAt != nil, artIndex: Self.stableIndex(ev.id),
                              isRecurring: ev.isRecurring ?? false, templateId: ev.templateId,
                              paymentMethodIds: methodIDs,
                              publishedAt: ev.publishedAt,
                              cancelledAt: ev.cancelledAt,
                              cancellationReasonCode: ev.cancellationReasonCode,
                              cancellationReasonText: ev.cancellationReasonText,
                              memberResponse: ev.myResponseStatus.flatMap(FeedMemberResponse.init(rawValue:)))
    }

    /// Gap: there is no per-workspace template list, so the team-detail "session"
    /// card is synthesized from the earliest upcoming event.
    private func synthesizePlan(from ev: EventRecord) -> FeedPlan {
        let cal = Calendar(identifier: .gregorian)
        let weekday = cal.component(.weekday, from: ev.startDate)
        let end = ev.endDate ?? cal.date(byAdding: .hour, value: 2, to: ev.startDate) ?? ev.startDate
        let methodIDs = ev.paymentMethodIds.isEmpty
            ? ev.paymentMethodId.map { [$0] } ?? []
            : ev.paymentMethodIds
        let storedMethods = methodIDs.compactMap { methodID in
            paymentMethodsByTeam[ev.workspaceId ?? selectedTeamID]?.first { $0.id == methodID }
        }
        return FeedPlan(id: ev.templateId ?? ev.id, name: ev.name, weekdays: [weekday],
                        startTime: ev.startDate, endTime: end, startDate: ev.startDate, endDate: nil,
                        price: ev.pricePerPerson ?? Double(ev.totalPrice ?? 0),
                        totalVenueCost: Double(ev.totalPrice ?? 0), currency: "ر.س",
                        capacity: ev.maxParticipants ?? 0, capacityPolicy: .waitlist,
                        latitude: ev.latitude ?? 24.7136, longitude: ev.longitude ?? 46.6753,
                        locationName: ev.location, locationAddress: "",
                        sourceEventID: ev.id,
                        sourceTemplateID: (ev.isRecurring ?? false) ? ev.templateId : nil,
                        paymentMethods: storedMethods.map(PaymentMethodDraft.init(record:)))
    }

    static func stableIndex(_ id: UUID) -> Int {
        let sum = id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return sum % 3
    }

    // MARK: Preview seed (no network) — used by #Previews and HomeStore.preview
    private func seedPreview() {
        profileName = "نايف"
        currentUserID = UUID()
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        func at(_ days: Int, _ hour: Int) -> Date {
            let base = cal.date(byAdding: .day, value: days, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        }

        let teamA = FeedTeam(id: UUID(), name: "رفاق الملعب", symbol: "figure.run", avatarData: nil, memberCount: 12, inviteCode: "MLB-4827")
        let teamB = FeedTeam(id: UUID(), name: "نادي الفجر", symbol: "figure.cooldown", avatarData: nil, memberCount: 8, inviteCode: "FJR-1193")
        teams = [teamA, teamB]
        selectedTeamID = teamA.id
        ownerByTeam[teamA.id] = currentUserID
        ownerByTeam[teamB.id] = currentUserID

        let a1 = FeedOccurrence(id: UUID(), title: "كورة الثلاثاء", startAt: at(2, 20),
                                locationName: "ملعب النخيل", capacity: 14, price: 25, isCancelled: false, artIndex: 0)
        let a2 = FeedOccurrence(id: UUID(), title: "تمرين الجري", startAt: at(4, 6),
                                locationName: "كورنيش الرياض", capacity: 20, price: 0, isCancelled: false, artIndex: 1)
        let b1 = FeedOccurrence(id: UUID(), title: "تمرين الصباح", startAt: at(1, 7),
                                locationName: "منتزه السلام", capacity: 16, price: 0, isCancelled: false, artIndex: 1)
        occurrencesByTeam = [teamA.id: [a1, a2], teamB.id: [b1]]

        let pool = ["سلطان", "عبدالله", "فهد", "تركي", "ماجد", "خالد", "نواف"]
        rosterCache = [
            a1.id: pool.prefix(9).map { FeedMember(id: UUID(), name: $0, status: .registered) },
            a2.id: pool.map { FeedMember(id: UUID(), name: $0, status: .registered) },
            b1.id: pool.prefix(5).map { FeedMember(id: UUID(), name: $0, status: .registered) },
        ]

        plansByTeam = [
            teamA.id: [FeedPlan(id: UUID(), name: "تمرين الأسبوع", weekdays: [3, 6],
                                startTime: at(0, 20), endTime: at(0, 22),
                                startDate: at(-30, 20), endDate: nil,
                                price: 25, totalVenueCost: 350, currency: "ر.س", capacity: 14, capacityPolicy: .waitlist,
                                latitude: 24.7743, longitude: 46.7386,
                                locationName: "ملعب النخيل", locationAddress: "حي النخيل، الرياض")],
            teamB.id: [],
        ]
        membersByTeam = [
            teamA.id: [FeedTeamMember(id: UUID(), displayName: "نايف", role: .admin, isPending: false)]
                + pool.prefix(6).map { FeedTeamMember(id: UUID(), displayName: $0, role: .member, isPending: false) },
            teamB.id: [FeedTeamMember(id: UUID(), displayName: "نايف", role: .admin, isPending: false)],
        ]
    }
}
