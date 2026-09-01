import SwiftUI
import UIKit

/// The group-level details that sit behind one occurrence. This is presented
/// inside EventDetailView's translucent in-tree overlay so the exercise art
/// remains visible beneath the page, like the declined-responses surface.
struct ExerciseDetailsOverlayPage: View {
    @Bindable var feed: HomeStore
    let occurrence: FeedOccurrence
    let teamID: UUID
    /// The page's moving shell ignores the safe area so its silhouette reaches
    /// the physical display corners. Preserve the host's original top inset so
    /// the header itself still clears the status bar and Dynamic Island.
    let screenTopInset: CGFloat
    let onClose: () -> Void

    @State private var memberInDetails: FeedTeamMember?
    @State private var showsTemplateEditor = false

    /// False until the group's members and payment destinations have been
    /// asked for. Home's launch request does not carry either, so before this
    /// turns true the two sections below have nothing to show — and saying
    /// «تعذر تحميل» then is a lie: nothing has been attempted yet.
    @State private var hasLoadedGroupDetails = false
    @State private var showsDeleteConfirm = false
    @State private var showsSkipSheet = false

    /// The editor refreshes HomeStore before it dismisses. Reading the event
    /// back by id keeps this still-present details page in sync instead of
    /// continuing to render the immutable navigation snapshot it opened with.
    private var currentOccurrence: FeedOccurrence {
        feed.allOccurrences.first { $0.id == occurrence.id } ?? occurrence
    }

    private var team: FeedTeam? {
        feed.teams.first { $0.id == teamID }
    }

    private var usesFootballFeatures: Bool {
        LineupSportStyle(sport: team?.sport).usesFootballFeatures
    }

    private var plans: [FeedPlan] {
        feed.plans(for: teamID)
    }

    /// Only use a template that produced this occurrence. Production may hold
    /// one synthesized plan from another upcoming date; borrowing its time or
    /// coordinates here would make this page confidently show the wrong venue.
    private var plan: FeedPlan? {
        if let exact = plans.first(where: { $0.sourceEventID == currentOccurrence.id }) {
            return exact
        }
        if let templateID = currentOccurrence.templateId,
           let template = plans.first(where: { $0.sourceTemplateID == templateID }) {
            return template
        }
        return nil
    }

    private var members: [FeedTeamMember] {
        feed.members(for: teamID).sorted(by: FeedTeamMember.nameComesBefore)
    }

    private var memberCount: Int {
        members.isEmpty ? (team?.memberCount ?? 0) : members.count
    }

    private var isOwner: Bool {
        feed.isOwner(ofTeamID: teamID)
    }

    /// A historical occurrence is an immutable receipt of what happened. The
    /// main-template editor is therefore offered only from the live/current
    /// occurrence, where there is still a future template to change.
    private var canEditTemplate: Bool {
        isOwner && !currentOccurrence.isPast()
    }

    /// A date already called off cannot be called off again, and a date that
    /// has happened is a receipt rather than a plan.
    private var canSkipOccurrence: Bool {
        isOwner && !currentOccurrence.isPast() && !currentOccurrence.isCancelled
    }

    private var paymentMethods: [PaymentMethodRecord] {
        guard isOwner, !currentOccurrence.paymentMethodIds.isEmpty else { return [] }
        let availableByID = Dictionary(
            uniqueKeysWithValues: feed.methods(for: teamID).map { ($0.id, $0) }
        )
        return currentOccurrence.paymentMethodIds.compactMap { availableByID[$0] }
    }

    private var dayText: String {
        guard currentOccurrence.isRecurring,
              let plan,
              !plan.weekdays.isEmpty else {
            return currentOccurrence.startAt.arabicDay
        }
        return plan.weekdays.compactMap(weekdayName).joined(separator: "، ")
    }

    private var timeText: String {
        guard let plan else { return currentOccurrence.startAt.arabicTime }
        return "\(plan.startTime.arabicTime) – \(plan.endTime.arabicTime)"
    }

    private var currency: String {
        plan?.currency ?? "ر.س"
    }

    private var playerShare: Double {
        plan?.price ?? currentOccurrence.price
    }

    private var templateCapacity: Int {
        plan?.capacity ?? currentOccurrence.capacity
    }

    private var venueName: String {
        let templateVenue = plan?.locationName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !templateVenue.isEmpty { return templateVenue }
        let occurrenceVenue = currentOccurrence.locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return occurrenceVenue
    }

    private var directionsDestination: EventDirectionsDestination {
        EventDirectionsDestination(
            latitude: plan?.latitude ?? currentOccurrence.latitude,
            longitude: plan?.longitude ?? currentOccurrence.longitude,
            name: venueName
        )
    }

    private var hasDirections: Bool {
        directionsDestination.coordinate != nil || directionsDestination.query != nil
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                templateSection
                membersSection

                if isOwner {
                    paymentMethodsSection
                } else if playerShare > 0 {
                    participantPaymentSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 44)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            topBar.padding(.top, screenTopInset)
        }
        .task {
            await feed.loadGroupDetails(teamID)
            hasLoadedGroupDetails = true
        }
        .alert("حذف «\(team?.name ?? "التمرين")»؟", isPresented: $showsDeleteConfirm) {
            Button("حذف التمرين", role: .destructive) {
                feed.deleteTeam(teamID)
                onClose()
            }
            Button("تراجع", role: .cancel) {}
        } message: {
            Text("بيُحذف التمرين وكل مواعيده وأعضائه وطرق الدفع من عندك. تقدر تنشئ تمرينًا جديدًا أي وقت.")
        }
        // Pull still does the full refresh, occurrences and rosters included.
        .refreshable { await feed.loadTeamData(teamID) }
        .sheet(isPresented: $showsSkipSheet) {
            AdminSkipEventSheet { reasonCode, reasonText in
                // EventResponseFlow renders whatever this throws, through
                // ServerErrorMessage, so the failure is reported where the
                // person is already looking rather than behind a second alert.
                if case .failure(let message) = await feed.skip(
                    currentOccurrence,
                    reasonCode: reasonCode,
                    reasonText: reasonText
                ) {
                    throw NSError(
                        domain: "ExerciseDetailsOverlayPage.Skip",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }
            }
        }
        .sheet(item: $memberInDetails) { member in
            let player = rosterShape(of: member)
            PlayerDetailsSheet(
                member: player,
                avatarImageData: member.id == feed.currentUserID ? feed.avatarData : nil,
                share: 0,
                loadRating: usesFootballFeatures && feed.canRate(player)
                    ? { try await feed.playerRating(for: player) }
                    : nil,
                submitRating: usesFootballFeatures && feed.canRate(player)
                    ? { try await feed.submitPlayerRating($0, for: player) }
                    : nil
            )
        }
        .fullScreenCover(isPresented: $showsTemplateEditor) {
            EditExerciseTemplateSheet(
                feed: feed,
                isPresented: $showsTemplateEditor,
                teamID: teamID,
                eventID: currentOccurrence.id,
                templateID: currentOccurrence.templateId,
                existingPaymentMethodIDs: currentOccurrence.paymentMethodIds,
                initialSymbol: team?.symbol ?? "figure.soccer",
                teamColor: team?.color ?? .blue,
                initialPlan: editorPlan
            )
        }
        .environment(\.layoutDirection, .rightToLeft)
        .colorScheme(.dark)
    }

    private var topBar: some View {
        ZStack {
            Text("تفاصيل التمرين")
                .font(TamrinFont.font(size: 17, weight: .bold))
                .foregroundStyle(.white)

            HStack {
                // Contextual actions live in an ellipsis menu, the same
                // pattern the exercise's own page uses. Circular glass to match
                // the close button opposite it rather than the capsule the lone
                // edit button used to wear.
                if isOwner {
                    Menu {
                        // A past occurrence is a receipt: there is no future
                        // template left to change, so only the deletion stays.
                        if canEditTemplate {
                            Button("تعديل التمرين", systemImage: "pencil") {
                                Haptics.impact(.light)
                                showsTemplateEditor = true
                            }
                        }

                        // Skipping calls off one date and leaves the exercise
                        // running, so it sits above the deletion that ends the
                        // whole thing. A past or already-skipped date has
                        // nothing left to call off.
                        if canSkipOccurrence {
                            Button("تخطي هذا الموعد", systemImage: "forward.end.fill") {
                                Haptics.impact(.light)
                                showsSkipSheet = true
                            }
                        }

                        Button("حذف التمرين", systemImage: "trash", role: .destructive) {
                            showsDeleteConfirm = true
                        }
                    } label: {
                        Label("خيارات التمرين", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(
                                width: TamrinControlMetrics.glassIconContent,
                                height: TamrinControlMetrics.glassIconContent
                            )
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.regular)
                    .accessibilityLabel("خيارات التمرين")
                    .accessibilityHint("تعديل التمرين أو حذفه")
                }

                Spacer(minLength: 0)

                Button {
                    onClose()
                } label: {
                    Label("إغلاق", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(
                            width: TamrinControlMetrics.glassIconContent,
                            height: TamrinControlMetrics.glassIconContent
                        )
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .accessibilityLabel("إغلاق تفاصيل التمرين")
            }
            // Physical placement is part of this page's transition: edit stays
            // where the old close button was (left), while close moves right.
            .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.12)
            }
            .mask {
                LinearGradient(
                    colors: [.black, .black, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    private var templateSection: some View {
        ExerciseDetailsSection(title: "قالب التمرين", showsContainer: false) {
            VStack(spacing: 10) {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    ExerciseDetailStat(
                        symbol: "calendar",
                        value: dayText,
                        title: "يوم التمرين"
                    )
                    ExerciseDetailStat(
                        symbol: "clock.fill",
                        value: timeText,
                        title: "وقت التمرين"
                    )
                    ExerciseDetailStat(
                        symbol: "person.fill",
                        value: playerShare == 0
                            ? "مجاني"
                            : "\(playerShare.cleanAmount) \(currency)",
                        title: "قطة كل لاعب"
                    )
                    ExerciseDetailStat(
                        symbol: "person.2.fill",
                        value: templateCapacity.counted(.player),
                        title: "سعة التمرين"
                    )
                }

                venueRow
            }
        }
    }

    @ViewBuilder
    private var venueRow: some View {
        if hasDirections {
            Menu {
                Button {
                    openDirections(.hudhud)
                } label: {
                    Label { Text("هدهد") } icon: { Image("MapAppHudhud") }
                }

                Button {
                    openDirections(.googleMaps)
                } label: {
                    Label { Text("خرائط قوقل") } icon: { Image("MapAppGoogleMaps") }
                }
            } label: {
                ExerciseDetailInfoRow(
                    symbol: "sportscourt.fill",
                    title: "الملعب",
                    value: venueName.isEmpty ? "غير محدد" : venueName,
                    showsDisclosure: true
                )
            }
            .accessibilityLabel(venueName.isEmpty ? "الاتجاهات" : "الاتجاهات إلى \(venueName)")
            .accessibilityHint("يفتح قائمة تطبيقات الخرائط")
        } else {
            ExerciseDetailInfoRow(
                symbol: "sportscourt.fill",
                title: "الملعب",
                value: venueName.isEmpty ? "غير محدد" : venueName
            )
        }
    }

    @ViewBuilder
    private var membersSection: some View {
        ExerciseDetailsSection(
            title: "الأعضاء",
            // Counted the way Arabic counts, so 2 reads «عضوان» and 32 reads
            // «32 عضو» rather than a number bolted onto a plural.
            caption: members.isEmpty ? nil : members.count.counted(.member),
            showsContainer: false
        ) {
            if members.isEmpty, !hasLoadedGroupDetails {
                loadingRow("يجهّز قائمة الأعضاء…")
            } else if members.isEmpty {
                Text(memberCount > 0
                     ? "تعذر تحميل قائمة الأعضاء الآن. اسحب لتحديث الصفحة."
                     : "ما انضم أحد إلى التمرين بعد.")
                    .font(TamrinFont.subheadline)
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(members) { member in
                        MemberRowCard(
                            name: member.displayName,
                            subtitle: member.isPending
                                ? "بانتظار الانضمام"
                                : (member.role == .admin ? "مشرف التمرين" : "عضو"),
                            avatarImageData: member.id == feed.currentUserID ? feed.avatarData : nil,
                            avatarImageUrl: member.avatarUrl,
                            // The organizer's disc is the same neutral one
                            // everybody else gets. The crown beside the row
                            // already says who he is, and tinting the avatar as
                            // well said it twice — the second time in a colour
                            // that pulled the eye to the one row nobody needs
                            // to find.
                            avatarTint: .white.opacity(0.28),
                            avatarForeground: .white
                        ) {
                            if member.role == .admin {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.5))
                            } else if member.isPending {
                                Image(systemName: "clock")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .contentShape(.rect)
                        .onTapGesture { memberInDetails = member }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("يفتح تفاصيل اللاعب وتقييمه")
                        .accessibilityAction { memberInDetails = member }
                    }
                }
            }
        }
    }

    /// What a section shows while its data is still on its way. Deliberately
    /// the same shape as the text it replaces, so the section does not change
    /// height when the answer arrives.
    private func loadingRow(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.58))
            Text(title)
                .font(TamrinFont.subheadline)
                .foregroundStyle(.white.opacity(0.58))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var paymentMethodsSection: some View {
        ExerciseDetailsSection(title: "طرق الدفع", showsContainer: false) {
            if playerShare == 0 {
                Label("هذا التمرين مجاني ولا يحتاج إلى طريقة دفع.", systemImage: "checkmark.circle.fill")
                    .font(TamrinFont.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if paymentMethods.isEmpty, !hasLoadedGroupDetails,
                      !currentOccurrence.paymentMethodIds.isEmpty {
                loadingRow("يجهّز طريقة الدفع…")
            } else if paymentMethods.isEmpty {
                Text(currentOccurrence.paymentMethodIds.isEmpty
                     ? "لا توجد طريقة دفع مرتبطة بهذا الموعد."
                     : "تعذر تحميل طريقة الدفع المرتبطة بهذا الموعد الآن.")
                    .font(TamrinFont.subheadline)
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(paymentMethods) { method in
                        TamrinRowCard(
                            title: method.provider.displayName,
                            subtitle: method.provider == .cash
                                ? "الدفع في الملعب"
                                : method.maskedSummary
                        ) {
                            PaymentProviderLogo(
                                provider: method.provider,
                                size: TamrinRowCard<EmptyView, EmptyView>.leadingSize
                            )
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var participantPaymentSection: some View {
        ExerciseDetailsSection(title: "الدفع", showsContainer: false) {
            HStack(spacing: 12) {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.10), in: .circle)

                Text("تظهر لك تفاصيل التحويل الآمنة ضمن خطوات التسجيل في هذا الموعد.")
                    .font(TamrinFont.font(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func weekdayName(_ value: Int) -> String? {
        [
            1: "الأحد", 2: "الاثنين", 3: "الثلاثاء", 4: "الأربعاء",
            5: "الخميس", 6: "الجمعة", 7: "السبت"
        ][value]
    }

    private var editorPlan: PlanDraft {
        if var draft = feed.editDraft(for: currentOccurrence) {
            // The workspace is the exercise identity. Repair any historical
            // drift between its name and the event before presenting one field.
            draft.name = team?.name ?? draft.name
            return draft
        }

        let calendar = Calendar(identifier: .gregorian)
        var draft = PlanDraft()
        draft.name = team?.name ?? currentOccurrence.title
        draft.weekdays = Set(plan?.weekdays ?? [calendar.component(.weekday, from: currentOccurrence.startAt)])
        draft.startTime = plan?.startTime ?? currentOccurrence.startAt
        draft.endTime = plan?.endTime
            ?? currentOccurrence.endAt
            ?? calendar.date(byAdding: .hour, value: 1, to: currentOccurrence.startAt)
            ?? currentOccurrence.startAt
        draft.locationName = venueName
        draft.locationAddress = plan?.locationAddress ?? ""
        draft.latitude = plan?.latitude ?? currentOccurrence.latitude ?? draft.latitude
        draft.longitude = plan?.longitude ?? currentOccurrence.longitude ?? draft.longitude
        draft.capacity = templateCapacity
        draft.capacityPolicy = plan?.capacityPolicy ?? currentOccurrence.capacityPolicy
        draft.totalVenueCost = plan?.totalVenueCost
            ?? (currentOccurrence.price * Double(max(currentOccurrence.capacity, 1)))
        draft.paymentMethods = plan?.paymentMethods ?? []
        draft.scheduleKind = currentOccurrence.isRecurring ? .recurring : .oneOff
        draft.oneOffDate = currentOccurrence.startAt
        return draft
    }

    private func openDirections(_ provider: EventDirectionsProvider) {
        guard let url = provider.url(for: directionsDestination) else { return }
        Haptics.impact(.light)
        UIApplication.shared.open(url)
    }

    private func rosterShape(of member: FeedTeamMember) -> FeedMember {
        FeedMember(
            id: member.id,
            name: member.displayName,
            status: .registered,
            userId: member.id,
            avatarUrl: member.avatarUrl,
            position: member.position
        )
    }
}

private struct ExerciseDetailsSection<Content: View>: View {
    let title: String
    var caption: String?
    var showsContainer = true
    @ViewBuilder var content: Content

    @ViewBuilder
    var body: some View {
        if showsContainer {
            sectionContent
                .padding(16)
                .tamrinGlassCard()
        } else {
            sectionContent
        }
    }

    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(TamrinFont.font(size: 17, weight: .bold))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                if let caption {
                    Text(caption)
                        .font(TamrinFont.font(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExerciseDetailStat: View {
    let symbol: String
    let value: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))

            // Label first, answer under it: the tile is read as a question
            // being answered, and the four of them line up down the same
            // column so the eye can run the answers without re-reading which
            // is which. The same order the pitch row below already uses.
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TamrinFont.font(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
                Text(value)
                    .font(TamrinFont.font(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(14)
        .background(
            .white.opacity(0.08),
            in: .rect(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

private struct ExerciseDetailInfoRow: View {
    let symbol: String
    let title: String
    let value: String
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                // The same weight of white the day and time icons carry: one
                // accent among a page of neutral glyphs reads as a status
                // rather than as an icon.
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.10), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TamrinFont.font(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                Text(value)
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 8)

            if showsDisclosure {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 60)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 20, style: .continuous))
        .contentShape(.rect)
    }
}
