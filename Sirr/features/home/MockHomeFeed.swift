import SwiftUI

/// Value types the reskinned Home feed reads, plus `HomeStore` — the real
/// integration layer that loads `WorkspaceService` / `EventService` /
/// `AuthService` records and maps them into these types, leaving the designer
/// views (which read this surface) essentially unchanged.
struct FeedTeam: Identifiable {
    let id: UUID
    let name: String
    let symbol: String
    /// The colour picked with the symbol. Every surface that draws the group's
    /// icon tints it with this, so the choice is the group's identity rather
    /// than a flourish on the creation screen.
    var color: TeamColor = TeamColor.allCases[0]
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

/// The tint behind a group's symbol. Stored by `rawValue` so the choice can be
/// persisted as a string the day the workspace record carries one.
enum TeamColor: String, CaseIterable, Identifiable {
    /// Declaration order is display order, and the first is what a new group
    /// starts as.
    case blue, lime, red, orange, yellow, purple, pink

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .lime: return TamrinTheme.lime
        case .blue: return Color(red: 0.0, green: 0.48, blue: 1.0)
        case .red: return Color(red: 1.0, green: 0.23, blue: 0.19)
        case .orange: return Color(red: 1.0, green: 0.58, blue: 0.0)
        case .yellow: return Color(red: 1.0, green: 0.8, blue: 0.0)
        case .purple: return Color(red: 0.58, green: 0.44, blue: 0.86)
        case .pink: return Color(red: 1.0, green: 0.25, blue: 0.45)
        }
    }

    /// Lime and yellow are too bright to carry white; the rest are not.
    var symbolColor: Color {
        switch self {
        case .lime, .yellow: return TamrinTheme.ink
        default: return .white
        }
    }
}

struct TeamDraft {
    var teamName = ""
    var teamSymbol = "figure.soccer"
    var teamColor: TeamColor = TeamColor.allCases[0]
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
    /// The member's profile photo. It always came back from the members RPC;
    /// the mapping used to drop it, so this list drew initials for people the
    /// exercise roster drew properly.
    var avatarUrl: String? = nil
    /// Their position, so the member list can open a sheet that knows how to
    /// weight a rating.
    var position: String = ""
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
    /// Seat confirmed: free, or the organizer said the money arrived.
    case registered
    /// Seat held, share not paid yet. The seat counts and cannot be taken by
    /// anyone else — only the money is outstanding.
    case awaitingPayment
    /// The payer said they transferred; the organizer has not confirmed it.
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
    /// Registered, but the share is still owed.
    case awaitingPayment
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
    /// Seated by the organizer typing a name. Such a person has no account and
    /// cannot withdraw themselves, so only the organizer can free the seat.
    var isManual: Bool = false
    /// When they took the seat, for the player's detail sheet.
    var joinedAt: Date? = nil
    /// Profile photo, shown large at the top of the player's detail sheet.
    var avatarUrl: String? = nil
    /// The position from their profile, verbatim — the detail sheet leads with
    /// it, and it decides how their rating's Overall is weighted. Empty for a
    /// guest, or for anyone who never picked one.
    var position: String = ""
    /// Last payment nudge the organizer sent them, which the sheet's reminder
    /// button counts an hour from. Only the organizer's roster carries it.
    var paymentReminderSentAt: Date? = nil

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
    /// The pitch on the map, when the organizer picked one — what the
    /// directions button hands to a maps app.
    var latitude: Double? = nil
    var longitude: Double? = nil
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
    /// Persists the organizer's payment request on the event itself so a
    /// registered player can always return to the transfer details.
    var paymentReminderSentAt: Date? = nil
    var memberResponse: FeedMemberResponse? = nil
    /// What happens once every seat is taken: a reserve list the organizer
    /// opened, or a closed door. Defaults to the reserve list, which is what
    /// every event did before the choice existed.
    var capacityPolicy: FeedCapacityPolicy = .waitlist

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
    /// The stored profile photo, so every avatar in the app can show it
    /// without each screen re-fetching the profile row.
    private(set) var avatarUrl: String?
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
            || teamID == HomeDebugMemberFixture.paidMemberTeamID
            || teamID == HomeDebugMemberFixture.ownerTeamID
        #else
        return false
        #endif
    }

    private func isDebugMemberFixtureEvent(_ eventID: UUID) -> Bool {
        #if DEBUG
        return eventID == HomeDebugMemberFixture.eventID
            || eventID == HomeDebugMemberFixture.paidMemberEventID
            || eventID == HomeDebugMemberFixture.ownerEventID
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
        case .awaitingPayment: return .awaitingPayment
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
    /// Deterministic member-side screen for visually checking the persistent
    /// contribution entry point added in T-40. It never reaches Supabase.
    static var paymentRequestPreview: HomeStore {
        let store = HomeStore(previewSeed: true)
        let memberID = store.currentUserID ?? HomeDebugMemberFixture.memberFallbackID
        let team = HomeDebugMemberFixture.paidMemberTeam
        var occurrence = HomeDebugMemberFixture.paidMemberOccurrence()
        occurrence.paymentReminderSentAt = .now

        store.teams = [team]
        store.selectedTeamID = team.id
        store.ownerByTeam[team.id] = HomeDebugMemberFixture.organizerID
        store.membersByTeam[team.id] = HomeDebugMemberFixture.members(
            currentUserID: memberID,
            profileName: store.profileName
        )
        store.occurrencesByTeam = [team.id: [occurrence]]
        store.rosterCache = [occurrence.id: HomeDebugMemberFixture.paidMemberRoster(
            currentUserID: memberID,
            profileName: store.profileName
        )]
        store.myEventStatus[occurrence.id] = .registered
        return store
    }

    /// Member-side roster with a guest linked to a named teammate. This proves
    /// the T-46 attribution UI without creating any backend participant rows.
    static var guestAttributionPreview: HomeStore {
        let store = paymentRequestPreview
        guard let occurrence = store.occurrences.first else { return store }
        store.rosterCache[occurrence.id, default: []].insert(
            FeedMember(
                id: UUID(uuidString: "F3B00000-0000-4000-8000-000000000099")!,
                name: "ضيف سلمان",
                status: .registered,
                addedBy: HomeDebugMemberFixture.salmanID,
                joinedAt: .now
            ),
            at: 0
        )
        return store
    }

    /// Member-side fixture with no personal participant row. Used to verify
    /// that a guest-only request is explicit about not reserving or charging
    /// a seat for the current member.
    static var guestOnlyRegistrationPreview: HomeStore {
        let store = paymentRequestPreview
        guard let occurrence = store.occurrences.first else { return store }
        store.rosterCache[occurrence.id]?.removeAll {
            $0.userId == store.currentUserID
        }
        store.myEventStatus[occurrence.id] = nil
        return store
    }
    #endif

    #if DEBUG
    /// Installs a realistic non-admin team beside live workspaces without ever
    /// creating corresponding backend records. Existing local participation is
    /// preserved across refreshes so register/decline/withdraw can be tested.
    private func installDebugMemberFixtureIfNeeded() {
        // Off unless the scheme asks for it: see HomeDebugMemberFixture.isEnabled.
        guard HomeDebugMemberFixture.isEnabled else { return }

        // Fixture mode also works with a clean simulator that has never logged
        // in. Give that run one stable local identity so the owner scenario is
        // genuinely an owner and rating never mistakes another player for me.
        if currentUserID == nil {
            currentUserID = HomeDebugMemberFixture.memberFallbackID
        }
        if profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profileName = "أنا — حساب التجربة"
        }
        if playerPosition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            playerPosition = "وسط"
        }
        let fixtureUserID = currentUserID ?? HomeDebugMemberFixture.memberFallbackID

        let teamID = HomeDebugMemberFixture.teamID
        if !teams.contains(where: { $0.id == teamID }) {
            teams.append(HomeDebugMemberFixture.team)
        }
        ownerByTeam[teamID] = HomeDebugMemberFixture.organizerID
        membersByTeam[teamID] = HomeDebugMemberFixture.memberTeamMembers(
            currentUserID: fixtureUserID,
            profileName: profileName
        )

        if occurrencesByTeam[teamID] == nil {
            let free = HomeDebugMemberFixture.occurrence()
            occurrencesByTeam[teamID] = [free]
            plansByTeam[teamID] = [HomeDebugMemberFixture.plan(for: free)]
            paymentMethodsByTeam[teamID] = []
            rosterCache[free.id] = HomeDebugMemberFixture.roster()
            myEventStatus[free.id] = nil
            memberResponseByEvent[free.id] = .invited
        }

        let paidMemberTeamID = HomeDebugMemberFixture.paidMemberTeamID
        if !teams.contains(where: { $0.id == paidMemberTeamID }) {
            teams.append(HomeDebugMemberFixture.paidMemberTeam)
        }
        ownerByTeam[paidMemberTeamID] = HomeDebugMemberFixture.organizerID
        membersByTeam[paidMemberTeamID] = HomeDebugMemberFixture.memberTeamMembers(
            currentUserID: fixtureUserID,
            profileName: profileName
        )
        if occurrencesByTeam[paidMemberTeamID] == nil {
            let paid = HomeDebugMemberFixture.paidMemberOccurrence()
            occurrencesByTeam[paidMemberTeamID] = [paid]
            plansByTeam[paidMemberTeamID] = [HomeDebugMemberFixture.plan(for: paid)]
            paymentMethodsByTeam[paidMemberTeamID] = []
            rosterCache[paid.id] = HomeDebugMemberFixture.paidMemberRoster(
                currentUserID: fixtureUserID,
                profileName: profileName
            )
            myEventStatus[paid.id] = .registered
        }

        // The third group is mine, so the organizer's side of every screen is
        // reachable without a backend: money tiles, payment review, reminders.
        let ownerTeamID = HomeDebugMemberFixture.ownerTeamID
        if !teams.contains(where: { $0.id == ownerTeamID }) {
            teams.append(HomeDebugMemberFixture.ownerTeam)
        }
        ownerByTeam[ownerTeamID] = fixtureUserID
        membersByTeam[ownerTeamID] = HomeDebugMemberFixture.ownerTeamMembers(
            currentUserID: fixtureUserID,
            profileName: profileName
        )

        if occurrencesByTeam[ownerTeamID] == nil {
            let mine = HomeDebugMemberFixture.ownerOccurrence()
            occurrencesByTeam[ownerTeamID] = [mine]
            plansByTeam[ownerTeamID] = [HomeDebugMemberFixture.plan(for: mine)]
            paymentMethodsByTeam[ownerTeamID] = []
            rosterCache[mine.id] = HomeDebugMemberFixture.ownerRoster()
        }
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
            avatarUrl = profile.avatarUrl
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
            #if DEBUG
            if HomeDebugMemberFixture.isEnabled,
               teams.contains(where: { isDebugMemberFixtureTeam($0.id) }) {
                // The flag was passed to test the fixture, so open on it rather
                // than on whichever real workspace happens to sort first.
                selectedTeamID = HomeDebugMemberFixture.teamID
                onSelectWorkspace?(HomeDebugMemberFixture.teamID)
                return
            }
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
            if HomeDebugMemberFixture.isEnabled,
               teams.contains(where: { $0.id == HomeDebugMemberFixture.teamID }) {
                selectedTeamID = HomeDebugMemberFixture.teamID
                onSelectWorkspace?(HomeDebugMemberFixture.teamID)
            } else if let preferred,
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

    /// Refreshes event-level state that can change while the detail screen is
    /// open (for example, an organizer requesting the contribution). Roster
    /// refreshes alone cannot observe columns on `events`.
    func reloadOccurrence(_ eventId: UUID) async {
        guard !isPreview, !isDebugMemberFixtureEvent(eventId) else { return }
        do {
            let event = try await EventService.shared.getEventById(eventId)
            eventRecordsByID[event.id] = event
            guard let workspaceID = event.workspaceId else { return }
            let mapped = mapOccurrence(event)
            if let index = occurrencesByTeam[workspaceID]?.firstIndex(where: { $0.id == eventId }) {
                occurrencesByTeam[workspaceID]?[index] = mapped
            }
        } catch {
            // Keep the last known event. A transient event refresh must not
            // hide the detail screen or discard the already loaded roster.
            errorMessage = error.localizedDescription
        }
    }

    func paymentWasRequested(for occurrence: FeedOccurrence) -> Bool {
        let current = occurrencesByTeam.values
            .lazy
            .compactMap { $0.first(where: { $0.id == occurrence.id }) }
            .first
        return (current?.paymentReminderSentAt ?? occurrence.paymentReminderSentAt) != nil
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
                       status: $0.isAwaitingPayment
                           ? .awaitingPayment
                           : ($0.isPending ? .paymentPending : .registered),
                       userId: $0.userId,
                       addedBy: $0.addedBy,
                       isManual: $0.isManual,
                       joinedAt: $0.joinedAtDate,
                       // My own photo is already loaded with my profile, so my
                       // row shows it without waiting on the roster's copy.
                       avatarUrl: $0.avatarUrl
                           ?? ($0.userId == currentUserID ? avatarUrl : nil),
                       // Same reasoning as the avatar: my own position is
                       // already loaded with my profile.
                       position: $0.playerPosition
                           ?? ($0.userId == currentUserID ? playerPosition : ""),
                       paymentReminderSentAt: $0.paymentReminderSentAtDate)
        }
        if let mine = parts.first(where: { $0.userId == currentUserID && $0.guestName == nil }) {
            myEventStatus[eventId] = mine.isAwaitingPayment
                ? .awaitingPayment
                : (mine.isPending ? .paymentPending : .registered)
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

    /// Creates the exercise from the wizard draft, then turns its plan into real
    /// dates. A failed date rolls the new exercise back, so the UI never reports
    /// one as ready without its dates and payment methods.
    @discardableResult
    func createTeam(from draft: TeamDraft) async throws -> FeedTeam {
        let name = draft.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw NSError(
                domain: "HomeStore.CreateTeam",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "اكتب اسم التمرين أولًا."]
            )
        }
        // A preview store has no backend behind it. Kept as its own guard so a
        // named exercise never reports the missing-name error instead.
        guard !isPreview else {
            throw NSError(
                domain: "HomeStore.CreateTeam",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "الإنشاء غير متاح في وضع المعاينة."]
            )
        }
        var createdWorkspace: WorkspaceRecord?
        do {
            let ws = try await WorkspaceService.shared.createWorkspace(
                name: name,
                symbol: draft.teamSymbol,
                color: draft.teamColor.rawValue
            )
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
                userInfo: [NSLocalizedDescriptionKey: "أضف وسيلة دفع صحيحة واحدة على الأقل قبل الحفظ."]
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
        guard isCurrentTeamOwner else { return .failure("هذا الإجراء متاح لمشرف التمرين فقط.") }
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
        guard isCurrentTeamOwner else { return .failure("هذا الإجراء متاح لمشرف التمرين فقط.") }
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
              let joinerId = member.paymentOwnerId,
              isCurrentTeamOwner else {
            return .failure("لا يمكن تأكيد هذه الدفعة.")
        }
        #if DEBUG
        if isDebugMemberFixtureEvent(occurrence.id) {
            guard var rows = rosterCache[occurrence.id] else { return .success }
            for index in rows.indices where
                rows[index].status == .paymentPending
                    && rows[index].paymentOwnerId == joinerId {
                rows[index].status = .registered
            }
            rosterCache[occurrence.id] = rows
            return .success
        }
        #endif
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
              let joinerId = member.paymentOwnerId,
              isCurrentTeamOwner else {
            return .failure("لا يمكن رفض هذه الدفعة.")
        }
        #if DEBUG
        if isDebugMemberFixtureEvent(occurrence.id) {
            rosterCache[occurrence.id]?.removeAll {
                $0.status == .paymentPending && $0.paymentOwnerId == joinerId
            }
            return .success
        }
        #endif
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

    /// Seats someone who does not use the app: the organizer types the name and
    /// the server creates a confirmed registration for them. On a paid exercise
    /// the money is settled with the organizer outside the app, so no payment
    /// request is raised.
    func addManualParticipant(named rawName: String, to occurrence: FeedOccurrence) async -> RegistrationOutcome {
        guard isCurrentTeamOwner else { return .failure("هذا الإجراء متاح لمشرف التمرين فقط.") }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure("اكتب اسم اللاعب أولًا.") }

        if isPreview || isDebugMemberFixtureEvent(occurrence.id) {
            appendManualParticipant(named: name, to: occurrence.id)
            return .success
        }

        do {
            let result = try await EventService.shared.addManualParticipant(
                eventId: occurrence.id,
                name: name
            )
            await reloadRoster(occurrence.id)
            switch result {
            case .added:
                return .success
            case .seatsFull:
                return .failure("اكتملت المقاعد لهذا الموعد.")
            case .duplicateName:
                return .failure("فيه لاعب مسجل بنفس الاسم. ميّزه باسم العائلة أو رقم.")
            case .registrationClosed:
                return .failure("التسجيل مقفل لهذا الموعد. افتحه من إعدادات الموعد ثم أضفه.")
            case .notPublished:
                return .failure("أرسل الموعد لأعضاء التمرين أولًا، بعدها تقدر تسجل لاعبين يدويًا.")
            case .cancelled:
                return .failure("هذا الموعد متخطى.")
            case .emptyName:
                return .failure("اكتب اسم اللاعب أولًا.")
            }
        } catch {
            await reloadRoster(occurrence.id)
            return .failure(error.localizedDescription)
        }
    }

    /// Frees any seat on this exercise. Removing a member who paid for guests
    /// takes those seats too — the server owns that rule.
    func removeParticipant(_ member: FeedMember, from occurrence: FeedOccurrence) async -> RegistrationOutcome {
        guard isCurrentTeamOwner else {
            return .failure("هذا الإجراء متاح لمشرف التمرين فقط.")
        }

        if isPreview || isDebugMemberFixtureEvent(occurrence.id) {
            rosterCache[occurrence.id]?.removeAll { $0.id == member.id }
            return .success
        }

        do {
            let result = try await EventService.shared.removeParticipant(participantId: member.id)
            await reloadRoster(occurrence.id)
            switch result {
            case .removed:
                return .success
            case .isCreator:
                return .failure("لا يمكن إزالة منظّم التمرين من قائمته.")
            case .notFound:
                return .success
            }
        } catch {
            await reloadRoster(occurrence.id)
            return .failure("تعذر إزالة اللاعب. حاول مرة أخرى.")
        }
    }

    /// Result of nudging one player about their share. On success the caller
    /// gets the moment the button may be pressed again.
    enum PaymentReminderOutcome {
        case sent(nextAllowedAt: Date)
        case tooSoon(nextAllowedAt: Date)
        case failure(String)
    }

    /// Sends the player a push reminding them to pay. The hour-long cooldown is
    /// the server's, and the refreshed roster carries it back so the button
    /// stays disabled across reopenings of the sheet and across devices.
    func remindPayment(_ member: FeedMember, on occurrence: FeedOccurrence) async -> PaymentReminderOutcome {
        guard isCurrentTeamOwner else {
            return .failure("هذا الإجراء متاح لمشرف التمرين فقط.")
        }

        if isPreview || isDebugMemberFixtureEvent(occurrence.id) {
            let nextAllowed = Date().addingTimeInterval(3600)
            updateRosterMember(member.id, on: occurrence.id) { $0.paymentReminderSentAt = Date() }
            return .sent(nextAllowedAt: nextAllowed)
        }

        do {
            let result = try await EventService.shared.remindParticipantPayment(
                eventId: occurrence.id,
                participantId: member.id
            )
            switch result {
            case .sent(let nextAllowedAt):
                updateRosterMember(member.id, on: occurrence.id) { $0.paymentReminderSentAt = Date() }
                return .sent(nextAllowedAt: nextAllowedAt)
            case .tooSoon(let nextAllowedAt):
                updateRosterMember(member.id, on: occurrence.id) {
                    $0.paymentReminderSentAt = nextAllowedAt.addingTimeInterval(-3600)
                }
                return .tooSoon(nextAllowedAt: nextAllowedAt)
            case .noAccount:
                return .failure("هذا اللاعب ما عنده حساب في التطبيق، فما يوصله تذكير.")
            case .isSelf:
                return .failure("هذا مقعدك أنت.")
            case .notFound:
                await reloadRoster(occurrence.id)
                return .failure("هذا اللاعب ما عاد مسجل في الموعد.")
            case .cancelled:
                return .failure("هذا الموعد متخطى.")
            }
        } catch {
            return .failure("تعذر إرسال التذكير. تحقق من اتصالك وحاول مرة أخرى.")
        }
    }

    /// Result of reminding the whole group, worded for a toast.
    enum MemberReminderOutcome {
        case sent(message: String)
        case failure(String)
    }

    /// One push to every member the reminder applies to. Recipients and the
    /// hour-long cooldown are the server's call.
    func remindMembers(
        _ kind: MemberReminderKind,
        on occurrence: FeedOccurrence
    ) async -> MemberReminderOutcome {
        guard isCurrentTeamOwner else {
            return .failure("هذا الإجراء متاح لمشرف التمرين فقط.")
        }

        if isPreview || isDebugMemberFixtureEvent(occurrence.id) {
            return .sent(message: "أُرسل التذكير إلى الأعضاء")
        }

        do {
            let result = try await EventService.shared.remindEventMembers(
                eventId: occurrence.id,
                kind: kind
            )
            switch result {
            case .sent(let recipients, _):
                if kind == .payment {
                    updateOccurrence(occurrence.id) { $0.paymentReminderSentAt = .now }
                }
                return .sent(message: "أُرسل التذكير إلى \(recipients.counted(.player))")
            case .tooSoon(let nextAllowedAt):
                let minutes = max(Int(nextAllowedAt.timeIntervalSinceNow / 60), 1)
                return .failure("أرسلت تذكيرًا قبل قليل. تقدر ترسل غيره بعد \(minutes) دقيقة.")
            case .noRecipients:
                return .failure(
                    kind == .register
                        ? "كل الأعضاء مسجلين في الموعد."
                        : "ما فيه لاعبين مسجلين لتذكيرهم."
                )
            case .notPublished:
                return .failure("انشر الموعد أولًا، بعدها تقدر تذكّر الأعضاء.")
            case .cancelled:
                return .failure("هذا الموعد متخطى.")
            }
        } catch {
            return .failure("تعذر إرسال التذكير. تحقق من اتصالك وحاول مرة أخرى.")
        }
    }

    private func updateRosterMember(
        _ memberID: UUID,
        on eventID: UUID,
        _ change: (inout FeedMember) -> Void
    ) {
        guard var list = rosterCache[eventID],
              let index = list.firstIndex(where: { $0.id == memberID }) else { return }
        change(&list[index])
        rosterCache[eventID] = list
    }

    /// Removes someone from the current group. The list is updated first so the
    /// sheet it was invoked from closes onto a roster that already reflects it.
    func removeMember(_ userId: UUID) async {
        let teamID = selectedTeamID
        let previous = membersByTeam[teamID] ?? []
        membersByTeam[teamID] = previous.filter { $0.id != userId }

        guard !isPreview, !isDebugMemberFixtureTeam(teamID) else { return }
        do {
            try await WorkspaceService.shared.removeMember(
                workspaceId: teamID,
                userId: userId
            )
        } catch {
            membersByTeam[teamID] = previous
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Player ratings

    /// True when this player can receive a rating from the current user:
    /// someone with an account who is not me. Reading one's own anonymous
    /// average is handled separately by `playerRating(for:)`.
    func canRate(_ member: FeedMember) -> Bool {
        guard let userId = member.userId else { return false }
        return userId != currentUserID
    }

    func playerRating(for member: FeedMember) async throws -> PlayerRatingSummary {
        guard let userId = member.userId else {
            throw NSError(
                domain: "HomeStore.Rating",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "هذا اللاعب بدون حساب."]
            )
        }

        #if DEBUG
        if HomeDebugMemberFixture.isFixturePlayer(userId) {
            return debugRatingSummary(for: userId, position: member.position)
        }
        #endif

        return try await RatingService.shared.getPlayerRating(
            workspaceId: selectedTeamID,
            userId: userId
        )
    }

    func submitPlayerRating(
        _ scores: PlayerRatingScores,
        for member: FeedMember
    ) async throws -> SubmitRatingResult {
        guard let userId = member.userId else { return .notAMember }

        #if DEBUG
        if HomeDebugMemberFixture.isFixturePlayer(userId) {
            HomeDebugMemberFixture.submittedRatings[userId] = scores
            return .saved(debugRatingSummary(for: userId, position: member.position))
        }
        #endif

        return try await RatingService.shared.submitPlayerRating(
            workspaceId: selectedTeamID,
            userId: userId,
            scores: scores
        )
    }

    #if DEBUG
    /// The fixture's rating backend: what I submitted, held in memory for the
    /// life of the session, blended with the seeded ratings so the average is
    /// a crowd's. Same shape and same arithmetic as the RPC, so the sheet
    /// cannot tell the two apart.
    private func debugRatingSummary(for playerID: UUID, position: String) -> PlayerRatingSummary {
        let resolved = PlayerPosition.resolved(from: position)
        let seeded = HomeDebugMemberFixture.seededRatings(for: playerID)
        let mine = HomeDebugMemberFixture.submittedRatings[playerID]

        let all = seeded + (mine.map { [$0] } ?? [])
        guard !all.isEmpty else {
            return PlayerRatingSummary(
                position: position,
                hasRated: mine != nil,
                ratingsCount: 0,
                mine: mine,
                average: nil,
                averageOverall: nil,
                myOverall: mine?.overall(for: resolved)
            )
        }

        var averaged = PlayerRatingScores.neutral
        for attribute in PlayerAttribute.allCases {
            let total = all.reduce(0) { $0 + $1[attribute] }
            averaged[attribute] = roundedMean(total: total, count: all.count)
        }

        let overallTotal = all.reduce(0) { $0 + $1.overall(for: resolved) }
        let averageOverall = roundedMean(total: overallTotal, count: all.count)

        return PlayerRatingSummary(
            position: position,
            hasRated: mine != nil,
            ratingsCount: all.count,
            mine: mine,
            average: averaged,
            averageOverall: averageOverall,
            myOverall: mine?.overall(for: resolved)
        )
    }

    /// PostgreSQL `round()` and the product rule both round a positive .5 up.
    /// Keeping the fixture in integer arithmetic makes it match the RPC exactly
    /// (Swift's default floating-point `.rounded()` is easy to change subtly).
    private func roundedMean(total: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((2 * total) + count) / (2 * count)
    }
    #endif

    func paymentDestination(for occurrence: FeedOccurrence) async throws -> PaymentDestination {
        #if DEBUG
        if isDebugMemberFixtureEvent(occurrence.id) {
            return HomeDebugMemberFixture.destination(for: occurrence)
        }
        #endif
        return try await ManualPaymentService.shared.getEventDestination(eventId: occurrence.id)
    }

    func guestPaymentDestination(for occurrence: FeedOccurrence) async throws -> PaymentDestination {
        #if DEBUG
        if isDebugMemberFixtureEvent(occurrence.id) {
            return HomeDebugMemberFixture.destination(for: occurrence)
        }
        #endif
        return try await ManualPaymentService.shared.getEventGuestDestination(eventId: occurrence.id)
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
            let status: FeedRegStatus = occurrence.price > 0 ? .awaitingPayment : .registered
            appendMe(to: occurrence, as: status)
            appendGuests(cleanGuests, to: occurrence.id, as: status, capacity: occurrence.capacity)
            return .success
        }
        #if DEBUG
        if isDebugMemberFixtureEvent(occurrence.id) {
            guard expectedDestination.eventId == occurrence.id else {
                return .failure("بيانات الموعد غير متطابقة.")
            }
            // No payment method is chosen at registration any more: a paid
            // seat is simply taken and left owing until «دفع القطة».
            let localStatus: FeedRegStatus = occurrence.price > 0
                ? .awaitingPayment
                : .registered
            appendMe(to: occurrence, as: localStatus)
            appendGuests(cleanGuests, to: occurrence.id, as: localStatus, capacity: occurrence.capacity)
            memberResponseByEvent[occurrence.id] = nil
            updateOccurrence(occurrence.id) { $0.memberResponse = nil }
            return .success
        }
        #endif
        guard currentUserID != nil else { return .failure("يجب تسجيل الدخول أولاً.") }
        do {
            // The seat first. Paying is its own act now, so no payment method
            // is chosen or snapshotted here.
            let status = try await EventService.shared.registerEventSeat(
                eventId: occurrence.id,
                guestNames: cleanGuests,
                expectedPricePerPerson: occurrence.price > 0 ? occurrence.price : nil
            )
            await reloadRoster(occurrence.id)
            switch status {
            case "submitted", "already_joined":
                memberResponseByEvent[occurrence.id] = nil
                updateOccurrence(occurrence.id) { $0.memberResponse = nil }
                return .success
            case "waitlisted":
                // The seat was gone, so the place is on the reserve list.
                memberResponseByEvent[occurrence.id] = nil
                updateOccurrence(occurrence.id) { $0.memberResponse = nil }
                return .success
            case "seats_full":
                return .failure("اكتملت المقاعد لهذا الموعد.")
            case "registration_closed":
                return .failure("التسجيل مقفل لهذا الموعد.")
            case "not_published":
                return .failure("لم يُنشر هذا الموعد بعد.")
            case "cancelled":
                return .failure("هذا الموعد متخطى.")
            case "event_terms_changed":
                return .failure("غيّر المشرف مبلغ الموعد. أغلق النافذة وافتحها مجددًا لمراجعة المبلغ الجديد.")
            default:
                return .failure("تعذر إكمال التسجيل.")
            }
        } catch {
            await reloadRoster(occurrence.id)
            return .failure(error.localizedDescription)
        }
    }

    /// «حوّلت المبلغ»: records that the player paid, for their own seat and any
    /// guest seats they still owe for. The organizer confirms it arrived.
    func declarePayment(
        for occurrence: FeedOccurrence,
        method: PaymentDestinationMethod
    ) async -> RegistrationOutcome {
        guard !isPreview else {
            setMyStatus(.paymentPending, on: occurrence)
            return .success
        }
        #if DEBUG
        if isDebugMemberFixtureEvent(occurrence.id) {
            setMyStatus(.paymentPending, on: occurrence)
            return .success
        }
        #endif
        do {
            let status = try await EventService.shared.declareEventPayment(
                eventId: occurrence.id,
                paymentMethodId: method.paymentMethodId
            )
            await reloadRoster(occurrence.id)
            switch status {
            case "declared", "nothing_due", "free_event":
                return .success
            case "payment_method_required", "event_terms_changed":
                return .failure("تغيّرت وسائل الدفع لهذا الموعد. أغلق النافذة وافتحها مجددًا.")
            default:
                return .failure("تعذر تسجيل التحويل.")
            }
        } catch {
            await reloadRoster(occurrence.id)
            return .failure(error.localizedDescription)
        }
    }

    /// Moves my own seat — and my unpaid guests' seats — to a new local state,
    /// for the paths that have no backend behind them.
    private func setMyStatus(_ status: FeedRegStatus, on occurrence: FeedOccurrence) {
        myEventStatus[occurrence.id] = status
        guard var roster = rosterCache[occurrence.id] else { return }
        for index in roster.indices where
            roster[index].paymentOwnerId == currentUserID
            && roster[index].status == .awaitingPayment {
            roster[index].status = status
        }
        rosterCache[occurrence.id] = roster
    }

    /// Adds only new guest seats for a member who is already confirmed. This
    /// keeps their own registration untouched and charges only for the names
    /// entered in this follow-up request.
    func addGuests(
        _ guests: [String],
        to occurrence: FeedOccurrence,
        expectedDestination: PaymentDestination,
        withoutSelf: Bool = false
    ) async -> RegistrationOutcome {
        let cleanGuests = guests
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanGuests.isEmpty else {
            return .failure("أضف اسم لاعب واحد على الأقل.")
        }

        let localStatus: FeedRegStatus = occurrence.price > 0
            ? .awaitingPayment
            : .registered
        guard !isPreview else {
            appendGuests(cleanGuests, to: occurrence.id, as: localStatus, capacity: occurrence.capacity)
            return .success
        }
        #if DEBUG
        if isDebugMemberFixtureEvent(occurrence.id) {
            if withoutSelf {
                guard myEventStatus[occurrence.id] == nil else {
                    return .failure("لديك تسجيل قائم في هذا الموعد.")
                }
            } else {
                guard myEventStatus[occurrence.id] == .registered
                        || myEventStatus[occurrence.id] == .awaitingPayment else {
                    return .failure("سجّل نفسك في الموعد أولًا.")
                }
            }
            guard expectedDestination.eventId == occurrence.id else {
                return .failure("بيانات الموعد غير متطابقة.")
            }
            appendGuests(cleanGuests, to: occurrence.id, as: localStatus, capacity: occurrence.capacity)
            return .success
        }
        #endif
        guard currentUserID != nil else { return .failure("يجب تسجيل الدخول أولاً.") }

        do {
            let result = try await ManualPaymentService.shared.registerGuests(
                eventId: occurrence.id,
                guestNames: cleanGuests,
                expectedDestination: expectedDestination,
                withoutSelf: withoutSelf
            )
            await reloadRoster(occurrence.id)
            switch result {
            case .submitted:
                return .success
            case .seatsFull:
                return .failure("المقاعد المتبقية لا تكفي لكل الضيوف.")
            case .notRegistered:
                return .failure("لازم يكون تسجيلك مؤكد قبل إضافة ضيوف.")
            case .selfAlreadyRegistered:
                return .failure("أنت مسجل في الموعد. استخدم «سجّل معك أحد» لإضافة ضيوف.")
            case .selfRegistrationPending:
                return .failure("طلب تسجيلك ما زال بانتظار التأكيد. انتظر حسمه قبل تسجيل ضيف بدونك.")
            case .emptyGuests:
                return .failure("أضف اسم لاعب واحد على الأقل.")
            case .duplicateName:
                return .failure("أحد هذه الأسماء مسجل معك مسبقًا.")
            case .pendingGuestRequest:
                return .failure("عندك طلب ضيوف بانتظار تأكيد المشرف. انتظر تأكيده قبل إضافة طلب جديد.")
            case .creatorMissingPaymentMethod:
                return .failure("منظّم التمرين لم يضف وسيلة دفع لهذا الموعد بعد.")
            case .registrationClosed:
                return .failure("التسجيل مقفل لهذا الموعد.")
            case .eventTermsChanged:
                return .failure("غيّر المشرف مبلغ الموعد أو وسيلة الدفع. ارجع خطوة وراجع البيانات الجديدة.")
            case .notPublished:
                return .failure("لم يُنشر هذا الموعد بعد.")
            case .cancelled:
                return .failure("هذا الموعد متخطى.")
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
                case .registered, .awaitingPayment:
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
        // Every seat that is not on the reserve list occupies capacity,
        // including one whose share is still owed. Counting only `.registered`
        // let an unpaid seat slip past the cap, and an explicit status used to
        // skip the check altogether — together they seated a nineteenth player
        // in eighteen places.
        let seated = list.filter { $0.status != .waitlisted }.count
        let isFull = occurrence.capacity > 0 && seated >= occurrence.capacity
        let status: FeedRegStatus = isFull ? .waitlisted : (explicitStatus ?? .registered)
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

    private func appendGuests(
        _ names: [String],
        to eventId: UUID,
        as status: FeedRegStatus = .registered,
        capacity: Int = 0
    ) {
        guard !names.isEmpty else { return }
        var list = rosterCache[eventId] ?? []
        for name in names {
            // A guest takes a seat like anyone else, and joins the reserve
            // list once there is none left.
            let seated = list.filter { $0.status != .waitlisted }.count
            let isFull = capacity > 0 && seated >= capacity
            list.append(
                FeedMember(
                    id: UUID(),
                    name: name,
                    status: isFull ? .waitlisted : status,
                    addedBy: currentUserID
                )
            )
        }
        rosterCache[eventId] = list
    }

    /// Local-only echo of `add_manual_participant`, for previews and the debug
    /// member fixture, which never reach the backend.
    private func appendManualParticipant(named name: String, to eventId: UUID) {
        var list = rosterCache[eventId] ?? []
        list.append(
            FeedMember(
                id: UUID(),
                name: name,
                status: .registered,
                addedBy: currentUserID,
                isManual: true
            )
        )
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
    /// What the profile sheet did to the photo. An optional `Data` could only
    /// say "here is a new one" or "nothing to report", and clearing the photo is
    /// neither — spelling the three cases out keeps "no new photo" from being
    /// mistaken for "remove the one on file".
    enum AvatarEdit {
        case unchanged
        case replaced(Data)
        case removed
    }

    /// Optimistically applies the profile edit, then persists name / position /
    /// avatar. STC Pay number is edited elsewhere.
    func saveProfile(name: String, avatar: AvatarEdit, playerPosition: String) {
        profileName = name
        self.playerPosition = playerPosition
        switch avatar {
        case .unchanged: break
        case .replaced(let data): avatarData = data
        case .removed: avatarData = nil
        }
        guard !isPreview else { return }
        Task {
            var newUrl: String? = avatarUrl
            switch avatar {
            case .unchanged:
                break
            case .replaced(let data):
                if let uid = currentUserID,
                   let uploaded = await AuthService.shared.uploadAvatar(userId: uid, imageData: data) {
                    newUrl = uploaded
                    avatarUrl = uploaded
                }
            case .removed:
                newUrl = nil
                avatarUrl = nil
            }
            try? await AuthService.shared.updateProfile(name: name, position: playerPosition, avatarUrl: newUrl)
            // The row is what every roster reads, so it goes first: if the file
            // outlives this call nobody can reach it, whereas a file deleted
            // ahead of a failed update would leave rosters on a dead URL.
            if case .removed = avatar, let uid = currentUserID {
                await AuthService.shared.deleteAvatar(userId: uid)
            }
        }
    }

    // MARK: Mappers
    private func mapTeam(_ ws: WorkspaceRecord) -> FeedTeam {
        FeedTeam(id: ws.id, name: ws.name, symbol: ws.symbol ?? "figure.soccer",
                 color: TeamColor(rawValue: ws.color ?? "") ?? TeamColor.allCases[0],
                 avatarData: nil,
                 memberCount: ws.memberCount ?? 0, inviteCode: ws.inviteCode ?? "",
                 inviteURL: ws.inviteURL)
    }

    private func mapMember(_ m: WorkspaceMemberRecord) -> FeedTeamMember {
        FeedTeamMember(id: m.userId, displayName: m.displayName ?? "عضو",
                       role: m.isOwner ? .admin : .member, isPending: false,
                       avatarUrl: m.avatarUrl, position: m.position ?? "")
    }

    private func mapOccurrence(_ ev: EventRecord) -> FeedOccurrence {
        let methodIDs = ev.paymentMethodIds.isEmpty
            ? ev.paymentMethodId.map { [$0] } ?? []
            : ev.paymentMethodIds
        return FeedOccurrence(id: ev.id, title: ev.name, startAt: ev.startDate,
                              locationName: ev.location, capacity: ev.maxParticipants ?? 0,
                              price: ev.pricePerPerson ?? Double(ev.totalPrice ?? 0),
                              isCancelled: ev.cancelledAt != nil, artIndex: Self.stableIndex(ev.id),
                              latitude: ev.latitude, longitude: ev.longitude,
                              isRecurring: ev.isRecurring ?? false, templateId: ev.templateId,
                              paymentMethodIds: methodIDs,
                              publishedAt: ev.publishedAt,
                              cancelledAt: ev.cancelledAt,
                              cancellationReasonCode: ev.cancellationReasonCode,
                              cancellationReasonText: ev.cancellationReasonText,
                              paymentReminderSentAt: ev.paymentReminderSentAt,
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
