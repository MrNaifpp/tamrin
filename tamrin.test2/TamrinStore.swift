import Foundation
import SwiftData
import Observation
import UserNotifications

enum ExperienceMode: String, CaseIterable, Identifiable {
    case member, admin

    var id: String { rawValue }
    var title: String { self == .member ? "مستخدم" : "مشرف" }
    var subtitle: String { self == .member ? "أسجّل وأدفع" : "أدير المجموعة" }
    var symbol: String { self == .member ? "person.fill" : "crown.fill" }
}

enum ScheduleEngine {
    static func dates(for plan: TrainingPlan, horizonWeeks: Int = 12, calendar: Calendar = .current) -> [(Date, Date)] {
        let dayStart = max(calendar.startOfDay(for: plan.startDate), calendar.startOfDay(for: .now))
        let naturalEnd = calendar.date(byAdding: .weekOfYear, value: horizonWeeks, to: dayStart) ?? dayStart
        let limit = min(plan.endDate ?? naturalEnd, naturalEnd)
        let startParts = calendar.dateComponents([.hour, .minute], from: plan.startTime)
        let endParts = calendar.dateComponents([.hour, .minute], from: plan.endTime)
        if plan.scheduleKind == .oneOff {
            guard let start = calendar.date(bySettingHour: startParts.hour ?? 0, minute: startParts.minute ?? 0, second: 0, of: plan.startDate),
                  var end = calendar.date(bySettingHour: endParts.hour ?? 0, minute: endParts.minute ?? 0, second: 0, of: plan.startDate) else { return [] }
            if end <= start { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }
            return [(start, end)]
        }
        var result: [(Date, Date)] = []
        var cursor = dayStart
        while cursor <= limit {
            let weekday = calendar.component(.weekday, from: cursor)
            if plan.weekdays.contains(weekday),
               let start = calendar.date(bySettingHour: startParts.hour ?? 0, minute: startParts.minute ?? 0, second: 0, of: cursor),
               var end = calendar.date(bySettingHour: endParts.hour ?? 0, minute: endParts.minute ?? 0, second: 0, of: cursor) {
                if end <= start { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }
                if start >= plan.startDate || calendar.isDate(start, inSameDayAs: plan.startDate) { result.append((start, end)) }
            }
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? limit.addingTimeInterval(1)
        }
        return result
    }
}

enum LocalNotificationScheduler {
    static func schedule(occurrence: Occurrence, plan: TrainingPlan, requestAuthorization: Bool = false) {
        let calendar = Calendar.current
        let reminderDay = calendar.date(byAdding: .day, value: -plan.publishLeadDays, to: occurrence.startAt) ?? occurrence.startAt
        let time = calendar.dateComponents([.hour, .minute], from: plan.publishTime)
        guard let date = calendar.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0, second: 0, of: reminderDay), date > .now else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            if requestAuthorization {
                guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
            } else {
                let settings = await center.notificationSettings()
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            }
            let content = UNMutableNotificationContent()
            content.title = "التمرين جاهز ترسله"
            content.body = "راجع تفاصيل \(plan.name) وأرسله للمجموعة."
            content.sound = .default
            content.userInfo = ["occurrenceID": occurrence.id.uuidString]
            let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date), repeats: false)
            let request = UNNotificationRequest(identifier: occurrence.id.uuidString, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    static func cancel(_ occurrenceID: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [occurrenceID.uuidString])
    }
}

@MainActor @Observable
final class TamrinStore {
    private let context: ModelContext

    var profile: UserProfile?
    var teams: [Team] = []
    var memberships: [Membership] = []
    var plans: [TrainingPlan] = []
    var occurrences: [Occurrence] = []
    var registrations: [Registration] = []
    var paymentMethods: [PaymentMethod] = []
    var paymentRecords: [PaymentRecord] = []
    var notifications: [AppNotification] = []
    var selectedTeamID: UUID?
    var experienceMode: ExperienceMode = .member

    init(context: ModelContext) {
        self.context = context
        reload()
    }

    var currentTeam: Team? { teams.first { $0.id == selectedTeamID } ?? teams.first }
    var currentPlan: TrainingPlan? { teamPlans.first }
    var teamPlans: [TrainingPlan] { guard let id = currentTeam?.id else { return [] }; return plans.filter { $0.teamID == id } }
    func plan(for occurrence: Occurrence) -> TrainingPlan? { plans.first { $0.id == occurrence.planID } }
    var currentRole: MemberRole {
        // Prototype switch intentionally overrides the persisted membership so both journeys are always testable.
        experienceMode == .admin ? .admin : .member
    }
    var isAdmin: Bool { currentRole == .admin }
    var teamOccurrences: [Occurrence] {
        guard let id = currentTeam?.id else { return [] }
        return occurrences.filter {
            $0.teamID == id && $0.endAt > .now && (isAdmin || $0.publicationStatus == .published)
        }.sorted { $0.startAt < $1.startAt }
    }
    var unreadCount: Int {
        guard let id = profile?.id else { return 0 }
        return notifications.filter { $0.userID == id && !$0.isRead }.count
    }

    func reload() {
        profile = try? context.fetch(FetchDescriptor<UserProfile>(sortBy: [SortDescriptor(\UserProfile.createdAt)])).first
        teams = (try? context.fetch(FetchDescriptor<Team>(sortBy: [SortDescriptor(\Team.createdAt)]))) ?? []
        memberships = (try? context.fetch(FetchDescriptor<Membership>())) ?? []
        plans = (try? context.fetch(FetchDescriptor<TrainingPlan>())) ?? []
        occurrences = (try? context.fetch(FetchDescriptor<Occurrence>())) ?? []
        registrations = (try? context.fetch(FetchDescriptor<Registration>())) ?? []
        paymentMethods = (try? context.fetch(FetchDescriptor<PaymentMethod>())) ?? []
        paymentRecords = (try? context.fetch(FetchDescriptor<PaymentRecord>())) ?? []
        notifications = (try? context.fetch(FetchDescriptor<AppNotification>(sortBy: [SortDescriptor(\AppNotification.createdAt, order: .reverse)]))) ?? []
        if selectedTeamID == nil { selectedTeamID = teams.first?.id }
        replenishRecurringSchedules()
        refreshOccurrenceLifecycle()
    }

    func saveProfile(name: String, avatarData: Data? = nil, playerPosition: String? = nil) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let profile {
            profile.name = value
            if let avatarData { profile.avatarData = avatarData }
            if let playerPosition { profile.playerPosition = playerPosition }
        } else { context.insert(UserProfile(name: value, avatarData: avatarData, playerPosition: playerPosition ?? "")) }
        saveAndReload()
    }

    func createTeam(from draft: TeamDraft) -> Team {
        let code = String(UUID().uuidString.prefix(6)).uppercased()
        let team = Team(name: draft.teamName, inviteCode: code, symbol: draft.teamSymbol, avatarData: draft.avatarData)
        context.insert(team)
        if let profile {
            context.insert(Membership(teamID: team.id, userID: profile.id, displayName: profile.name, role: .admin))
        }
        draft.invitedNames.forEach { context.insert(Membership(teamID: team.id, displayName: $0, role: .member, isPending: true)) }
        context.insert(Invite(teamID: team.id, code: code))
        for planDraft in draft.plans {
            let plan = makePlan(from: planDraft, teamID: team.id, fallbackStartDate: draft.startDate)
            context.insert(plan)
            insertOccurrences(for: plan, requestNotificationPermission: true)
        }
        for method in draft.paymentMethods {
            context.insert(PaymentMethod(teamID: team.id, kind: method.kind, title: method.title,
                                         accountHolder: method.accountHolder, iban: method.iban,
                                         accountNumber: method.accountNumber, appURL: method.appURL))
        }
        selectedTeamID = team.id
        saveAndReload()
        return team
    }

    func createPlan(from draft: PlanDraft) {
        guard let team = currentTeam else { return }
        let plan = makePlan(from: draft, teamID: team.id, fallbackStartDate: .now)
        context.insert(plan)
        insertOccurrences(for: plan, requestNotificationPermission: true)
        saveAndReload()
    }

    func join(code rawCode: String) -> Bool {
        guard let profile else { return false }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code == "MOVE24", !teams.contains(where: { $0.inviteCode == code }) { createDemoTeam(code: code) }
        guard let team = teams.first(where: { $0.inviteCode == code }) else { return false }
        if !memberships.contains(where: { $0.teamID == team.id && $0.userID == profile.id }) {
            context.insert(Membership(teamID: team.id, userID: profile.id, displayName: profile.name, role: .member))
        }
        selectedTeamID = team.id
        saveAndReload()
        return true
    }

    func registrations(for occurrence: Occurrence) -> [Registration] {
        registrations.filter { $0.occurrenceID == occurrence.id }.sorted { $0.createdAt < $1.createdAt }
    }
    func myRegistration(for occurrence: Occurrence) -> Registration? {
        guard let id = profile?.id else { return nil }
        return registrations.first { $0.occurrenceID == occurrence.id && $0.userID == id }
    }
    func payment(for occurrence: Occurrence, userID: UUID? = nil) -> PaymentRecord? {
        guard let id = userID ?? profile?.id else { return nil }
        return paymentRecords.first { $0.occurrenceID == occurrence.id && $0.userID == id }
    }
    func methodsForCurrentTeam() -> [PaymentMethod] {
        guard let id = currentTeam?.id else { return [] }; return paymentMethods.filter { $0.teamID == id }
    }

    /// Keeps the prototype useful immediately after onboarding without replacing any real local data.
    func ensureDemoExperience() {
        guard profile != nil, teams.isEmpty else { return }
        _ = join(code: "MOVE24")
    }

    func register(for occurrence: Occurrence) {
        guard let profile, myRegistration(for: occurrence) == nil, !occurrence.isCancelled else { return }
        let confirmed = registrations(for: occurrence).filter { $0.status == .registered }.count
        let status: RegistrationStatus
        if confirmed < occurrence.capacity { status = .registered }
        else if occurrence.capacityPolicy == .waitlist { status = .waitlisted }
        else { return }
        let registration = Registration(occurrenceID: occurrence.id, userID: profile.id, displayName: profile.name, status: status)
        context.insert(registration)
        if status == .registered, occurrence.price > 0 { context.insert(PaymentRecord(occurrenceID: occurrence.id, userID: profile.id)) }
        saveAndReload()
    }

    func cancelRegistration(for occurrence: Occurrence) {
        guard let registration = myRegistration(for: occurrence) else { return }
        let wasRegistered = registration.status == .registered
        if let record = payment(for: occurrence) { context.delete(record) }
        context.delete(registration)
        if wasRegistered, let promoted = registrations(for: occurrence).first(where: { $0.status == .waitlisted }) {
            promoted.statusRaw = RegistrationStatus.registered.rawValue
            if occurrence.price > 0 { context.insert(PaymentRecord(occurrenceID: occurrence.id, userID: promoted.userID)) }
            context.insert(AppNotification(userID: promoted.userID, title: "صار لك مكان", message: "تم نقلك من الانتظار إلى قائمة الحضور."))
        }
        saveAndReload()
    }

    func registerGuests(names: [String], for occurrence: Occurrence) {
        guard !occurrence.isCancelled else { return }
        var confirmed = registrations(for: occurrence).filter { $0.status == .registered }.count
        var inserted = false
        for rawName in names {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let status: RegistrationStatus
            if confirmed < occurrence.capacity { status = .registered; confirmed += 1 }
            else if occurrence.capacityPolicy == .waitlist { status = .waitlisted }
            else { continue }
            context.insert(Registration(occurrenceID: occurrence.id, userID: UUID(), displayName: name, status: status))
            inserted = true
        }
        if inserted { saveAndReload() }
    }

    func declarePaid(_ occurrence: Occurrence) {
        guard let record = payment(for: occurrence) else { return }
        record.statusRaw = PaymentStatus.declared.rawValue; record.updatedAt = .now; saveAndReload()
    }
    func confirmPayment(_ record: PaymentRecord) {
        guard record.status == .declared else { return }
        record.statusRaw = PaymentStatus.confirmed.rawValue; record.updatedAt = .now; saveAndReload()
    }
    func rejectPayment(_ record: PaymentRecord) {
        record.statusRaw = PaymentStatus.unpaid.rawValue; record.updatedAt = .now
        context.insert(AppNotification(userID: record.userID, title: "الدفع غير مكتمل", message: "لم يتم تأكيد دفعتك. راجع عملية التحويل ثم حاول مجدداً."))
        saveAndReload()
    }
    func remind(_ record: PaymentRecord) {
        context.insert(AppNotification(userID: record.userID, title: "تذكير بالقَطّة", message: "باقي عليك دفع قَطّة موعد التمرين القادم."))
        saveAndReload()
    }
    func approve(_ membership: Membership) {
        membership.isPending = false
        saveAndReload()
    }
    func reject(_ membership: Membership) {
        context.delete(membership)
        saveAndReload()
    }
    func publish(_ occurrence: Occurrence) {
        occurrence.publicationStatusRaw = PublicationStatus.published.rawValue
        occurrence.publishedAt = .now
        notifyTeam(title: "التمرين نزل", message: "فتحنا التسجيل لـ\(plan(for: occurrence)?.name ?? "التمرين الجاي").", occurrence: occurrence)
        saveAndReload()
    }
    func cancel(_ occurrence: Occurrence, reason: String = "ظرف طارئ") {
        let wasPublished = occurrence.publicationStatus == .published
        occurrence.isCancelled = true; occurrence.isOverride = true
        occurrence.publicationStatusRaw = PublicationStatus.cancelled.rawValue
        occurrence.cancellationReason = reason
        if wasPublished {
            notifyTeam(title: "للأسف، تمرين هالأسبوع ملغي", message: reason, occurrence: occurrence)
        }
        LocalNotificationScheduler.cancel(occurrence.id)
        saveAndReload()
    }
    func undoCancellation(_ occurrence: Occurrence) {
        occurrence.isCancelled = false
        occurrence.cancellationReason = ""
        occurrence.publicationStatusRaw = (occurrence.publishedAt == nil ? PublicationStatus.ready : .published).rawValue
        saveAndReload()
    }
    func update(_ occurrence: Occurrence, startAt: Date, endAt: Date, location: String, capacity: Int, price: Double, capacityPolicy: CapacityPolicy? = nil) {
        let wasPublished = occurrence.publicationStatus == .published
        occurrence.startAt = startAt; occurrence.endAt = endAt; occurrence.locationName = location
        occurrence.capacity = capacity; occurrence.price = price; occurrence.isOverride = true
        if let capacityPolicy { occurrence.capacityPolicyRaw = capacityPolicy.rawValue }
        if wasPublished { notifyTeam(title: "تغيّر موعد التمرين", message: "راجع الوقت والمكان الجديد قبل لا تطلع.", occurrence: occurrence) }
        saveAndReload()
    }
    func markNotificationsRead() {
        guard let id = profile?.id else { return }
        notifications.filter { $0.userID == id }.forEach { $0.isRead = true }; saveAndReload()
    }

    func resetDemoExperience() {
        paymentRecords.forEach(context.delete)
        registrations.forEach(context.delete)
        notifications.forEach(context.delete)
        paymentMethods.forEach(context.delete)
        occurrences.forEach { LocalNotificationScheduler.cancel($0.id); context.delete($0) }
        plans.forEach(context.delete)
        memberships.forEach(context.delete)
        teams.forEach(context.delete)
        try? context.save()
        reload()
        ensureDemoExperience()
    }

    private func makePlan(from draft: PlanDraft, teamID: UUID, fallbackStartDate: Date) -> TrainingPlan {
        TrainingPlan(teamID: teamID, name: draft.name, weekdays: draft.weekdays.sorted(),
                     startTime: draft.startTime, endTime: draft.endTime,
                     startDate: draft.scheduleKind == .oneOff ? draft.oneOffDate : fallbackStartDate,
                     endDate: nil, locationName: draft.locationName, locationAddress: draft.locationAddress,
                     latitude: draft.latitude, longitude: draft.longitude, capacity: draft.capacity,
                     capacityPolicy: draft.capacityPolicy, price: draft.price, scheduleKind: draft.scheduleKind,
                     publishLeadDays: draft.publishLeadDays, publishTime: draft.publishTime)
    }

    private func insertOccurrences(for plan: TrainingPlan, requestNotificationPermission: Bool = false) {
        var shouldRequestPermission = requestNotificationPermission
        for item in ScheduleEngine.dates(for: plan) {
            let occurrence = Occurrence(teamID: plan.teamID, planID: plan.id, startAt: item.0, endAt: item.1,
                                        locationName: plan.locationName, locationAddress: plan.locationAddress,
                                        capacity: plan.capacity, capacityPolicy: plan.capacityPolicy, price: plan.price)
            context.insert(occurrence)
            LocalNotificationScheduler.schedule(occurrence: occurrence, plan: plan, requestAuthorization: shouldRequestPermission)
            shouldRequestPermission = false
        }
    }

    private func refreshOccurrenceLifecycle() {
        var changed = false
        for occurrence in occurrences where occurrence.publicationStatus == .draft && occurrence.startAt > .now {
            guard let plan = plan(for: occurrence) else { continue }
            if reminderDate(for: occurrence, plan: plan) <= .now {
                occurrence.publicationStatusRaw = PublicationStatus.ready.rawValue
                changed = true
                if let profile, !notifications.contains(where: { $0.occurrenceID == occurrence.id && $0.title == "التمرين جاهز ترسله" }) {
                    context.insert(AppNotification(userID: profile.id, title: "التمرين جاهز ترسله", message: "راجع تفاصيله وأرسله للمجموعة.", occurrenceID: occurrence.id))
                }
            } else {
                LocalNotificationScheduler.schedule(occurrence: occurrence, plan: plan)
            }
        }
        if changed { try? context.save() }
    }

    private func replenishRecurringSchedules() {
        var inserted = false
        for plan in plans where plan.scheduleKind == .recurring {
            for pair in ScheduleEngine.dates(for: plan) where !occurrences.contains(where: { $0.planID == plan.id && Calendar.current.isDate($0.startAt, equalTo: pair.0, toGranularity: .minute) }) {
                let occurrence = Occurrence(teamID: plan.teamID, planID: plan.id, startAt: pair.0, endAt: pair.1,
                                            locationName: plan.locationName, locationAddress: plan.locationAddress,
                                            capacity: plan.capacity, capacityPolicy: plan.capacityPolicy, price: plan.price)
                context.insert(occurrence)
                occurrences.append(occurrence)
                LocalNotificationScheduler.schedule(occurrence: occurrence, plan: plan)
                inserted = true
            }
        }
        if inserted { try? context.save() }
    }

    private func reminderDate(for occurrence: Occurrence, plan: TrainingPlan) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -plan.publishLeadDays, to: occurrence.startAt) ?? occurrence.startAt
        let parts = calendar.dateComponents([.hour, .minute], from: plan.publishTime)
        return calendar.date(bySettingHour: parts.hour ?? 12, minute: parts.minute ?? 0, second: 0, of: day) ?? day
    }

    private func notifyTeam(title: String, message: String, occurrence: Occurrence) {
        guard let teamID = currentTeam?.id else { return }
        var ids = Set(memberships.filter { $0.teamID == teamID }.compactMap(\Membership.userID))
        if let profile { ids.insert(profile.id) }
        ids.forEach { context.insert(AppNotification(userID: $0, title: title, message: message, occurrenceID: occurrence.id)) }
    }

    private func createDemoTeam(code: String) {
        let team = Team(name: "رفاق الملعب", inviteCode: code, symbol: "figure.soccer")
        context.insert(team)
        let plan = TrainingPlan(teamID: team.id, name: "كورة الثلاثاء", weekdays: [3, 5],
                                startTime: Calendar.current.date(from: DateComponents(hour: 20)) ?? .now,
                                endTime: Calendar.current.date(from: DateComponents(hour: 21, minute: 30)) ?? .now,
                                startDate: .now, endDate: nil, locationName: "ملعب الحي الرياضي",
                                locationAddress: "طريق الأمير تركي، الرياض", capacity: 12,
                                capacityPolicy: .waitlist, price: 35)
        context.insert(plan); context.insert(Invite(teamID: team.id, code: code))
        let morningPlan = TrainingPlan(teamID: team.id, name: "لياقة السبت", weekdays: [7],
                                       startTime: Calendar.current.date(from: DateComponents(hour: 7)) ?? .now,
                                       endTime: Calendar.current.date(from: DateComponents(hour: 8)) ?? .now,
                                       startDate: .now, endDate: nil, locationName: "حديقة السلام",
                                       locationAddress: "حي الملقا، الرياض", capacity: 8,
                                       capacityPolicy: .closed, price: 0)
        context.insert(morningPlan)
        for pair in ScheduleEngine.dates(for: morningPlan) {
            context.insert(Occurrence(teamID: team.id, planID: morningPlan.id, startAt: pair.0, endAt: pair.1,
                                      locationName: morningPlan.locationName, locationAddress: morningPlan.locationAddress,
                                      capacity: morningPlan.capacity, capacityPolicy: morningPlan.capacityPolicy, price: morningPlan.price))
        }
        context.insert(PaymentMethod(teamID: team.id, kind: .bank, title: "مصرف الراجحي",
                                     accountHolder: "سلمان محمد", iban: "SA0380000000608010167519", appURL: "alrajhi://"))
        context.insert(PaymentMethod(teamID: team.id, kind: .cash, title: "نقدًا في الملعب"))
        let demoPeople = ["سلمان", "فيصل", "عبدالله", "مازن", "تركي", "وليد", "خالد"]
        let demoUserIDs = Dictionary(uniqueKeysWithValues: demoPeople.map { ($0, UUID()) })
        demoPeople.forEach { context.insert(Membership(teamID: team.id, userID: demoUserIDs[$0], displayName: $0, role: $0 == "سلمان" ? .admin : .member)) }
        ["نواف", "راكان"].forEach { context.insert(Membership(teamID: team.id, displayName: $0, role: .member, isPending: true)) }
        for (index, pair) in ScheduleEngine.dates(for: plan).enumerated() {
            let demoPublication: PublicationStatus = {
                switch index {
                case 0: .published
                case 1: .ready
                case 3: .cancelled
                default: .draft
                }
            }()
            let occurrence = Occurrence(teamID: team.id, planID: plan.id, startAt: pair.0, endAt: pair.1,
                                        locationName: plan.locationName, locationAddress: plan.locationAddress,
                                        capacity: plan.capacity, capacityPolicy: plan.capacityPolicy, price: plan.price,
                                        publicationStatus: demoPublication)
            switch index {
            case 0:
                occurrence.publishedAt = .now
            case 3:
                occurrence.isCancelled = true
                occurrence.cancellationReason = "الملعب غير متاح"
            default: break
            }
            context.insert(occurrence)
            if index < 3 {
                demoPeople.prefix(index == 0 ? 7 : 4).enumerated().forEach { offset, name in
                    let userID = demoUserIDs[name] ?? UUID()
                    context.insert(Registration(occurrenceID: occurrence.id, userID: userID, displayName: name, status: .registered))
                    let state: PaymentStatus = offset < 2 ? .confirmed : (offset == 2 ? .declared : .unpaid)
                    context.insert(PaymentRecord(occurrenceID: occurrence.id, userID: userID, status: state))
                }
            }
        }
        let oneOffStart = Calendar.current.date(byAdding: .day, value: 10, to: .now) ?? .now
        let oneOffPlan = TrainingPlan(teamID: team.id, name: "ودية آخر الأسبوع", weekdays: [],
                                      startTime: Calendar.current.date(from: DateComponents(hour: 21)) ?? .now,
                                      endTime: Calendar.current.date(from: DateComponents(hour: 22, minute: 30)) ?? .now,
                                      startDate: oneOffStart, endDate: oneOffStart, locationName: "ملعب النخبة",
                                      locationAddress: "حي الياسمين، الرياض", capacity: 14,
                                      capacityPolicy: .closed, price: 40, scheduleKind: .oneOff)
        context.insert(oneOffPlan)
        if let pair = ScheduleEngine.dates(for: oneOffPlan).first {
            context.insert(Occurrence(teamID: team.id, planID: oneOffPlan.id, startAt: pair.0, endAt: pair.1,
                                      locationName: oneOffPlan.locationName, locationAddress: oneOffPlan.locationAddress,
                                      capacity: oneOffPlan.capacity, capacityPolicy: oneOffPlan.capacityPolicy,
                                      price: oneOffPlan.price, publicationStatus: .draft))
        }
        if let profile {
            context.insert(AppNotification(userID: profile.id, title: "تمرين قريب", message: "كورة الثلاثاء بعد يومين — باقي 5 أماكن."))
        }
        try? context.save(); reload()
    }

    private func saveAndReload() { try? context.save(); reload() }
}
