import SwiftUI
import MapKit

/// Group details. The page answers three questions in this order, top to
/// bottom, with nothing between them: what the standing session is (day, time,
/// venue, venue cost, per-player share), who is in the group, and — for the
/// organizer only — how to invite more people.
struct TeamDetailView: View {
    @Bindable var feed: HomeStore
    @Environment(\.dismiss) private var dismiss
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedPlanID: UUID?
    @State private var didCopyCode = false
    @State private var showDeleteConfirm = false
    @State private var showAddSession = false

    // Read from `teams` directly (not `currentTeam`, which force-indexes) so the
    // delete → pop transition on the last team can't touch an empty array.
    private var team: FeedTeam? { feed.teams.first { $0.id == feed.selectedTeamID } }
    private var teamPlans: [FeedPlan] { feed.teamPlans }
    private var plan: FeedPlan? { teamPlans.first { $0.id == selectedPlanID } ?? teamPlans.first }
    private var members: [FeedTeamMember] {
        feed.teamMembers.sorted {
            if $0.role != $1.role { return $0.role == .admin }
            return $0.displayName < $1.displayName
        }
    }

    /// The roster drives the list, but the headline count falls back to the
    /// workspace record. get_workspace (roster) can fail while get_my_workspaces
    /// (count) succeeds, and showing ٠ beside the drawer's real count reads as a
    /// bug — both numbers come from workspace_members, so they must agree.
    private var memberCount: Int {
        members.isEmpty ? (team?.memberCount ?? 0) : members.count
    }

    /// The group has members, but this screen failed to load them.
    private var rosterUnavailable: Bool {
        members.isEmpty && (team?.memberCount ?? 0) > 0
    }

    /// Arabic counted-noun agreement: أعضاء for 3–10, عضوًا for 11–99, عضو otherwise.
    private func membersLabel(_ count: Int) -> String {
        let n = count % 100
        switch count {
        case 1: return "عضو واحد"
        case 2: return "عضوان"
        default:
            if (3...10).contains(n) { return "\(count.formatted()) أعضاء" }
            if (11...99).contains(n) { return "\(count.formatted()) عضوًا" }
            return "\(count.formatted()) عضو"
        }
    }

    private var dayText: String {
        guard let plan else { return "" }
        return plan.weekdays.compactMap { weekdayName($0) }.joined(separator: "، ")
    }

    /// A neutral surface rather than Home's blurred photograph. The artwork is
    /// warm, and behind this much text and this many cards it washed the whole
    /// page out to a muddy brown instead of letting the content read.
    private var backdrop: some View {
        ZStack {
            Color(white: 0.07)
            Circle()
                .fill(TamrinTheme.lime.opacity(0.14))
                .frame(width: 300, height: 300)
                .blur(radius: 120)
                .offset(y: -320)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Older plans stored only the per-player share, so rebuild the venue total
    /// from it rather than showing a zero.
    private func venueTotal(_ plan: FeedPlan) -> Double {
        plan.totalVenueCost > 0 ? plan.totalVenueCost : plan.price * Double(plan.capacity)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        heroHeader

                        if teamPlans.count > 1 {
                            planSwitcher
                        }

                        planSection
                        membersCard

                        if feed.isCurrentTeamOwner {
                            inviteCard
                            paymentsCard
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .refreshable { await feed.refresh() }
                // The navigation bar is transparent by design, so scrolling
                // content has to fade out beneath it instead of colliding.
                .mask {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: geo.safeAreaInsets.top)
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 18)
                        Color.black
                    }
                    .ignoresSafeArea()
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .colorScheme(.dark)
        .navigationTitle(team?.name ?? "المجموعة")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { centreMap(on: plan) }
        .onChange(of: plan?.id) { _, _ in centreMap(on: plan) }
        .toolbar {
            // Contextual actions live in an ellipsis menu (the designer's pattern).
            // Deleting the last group is allowed — Home falls back to WelcomeView.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Session editing is an owner (admin) action; the server
                    // enforces the same rule via creator-gated RLS/RPCs.
                    if feed.isCurrentTeamOwner {
                        if plan?.sourceEventID != nil {
                            Button("تعديل الموعد", systemImage: "pencil") {
                                showAddSession = true
                            }
                        } else {
                            // Nothing to edit yet — offer creating the first session.
                            Button("أضف موعد", systemImage: "calendar.badge.plus") {
                                showAddSession = true
                            }
                        }
                    }
                    // Owner deletes the group; a member leaves it.
                    Button(feed.isCurrentTeamOwner ? "حذف المجموعة" : "مغادرة المجموعة",
                           systemImage: feed.isCurrentTeamOwner ? "trash" : "rectangle.portrait.and.arrow.right",
                           role: .destructive) {
                        showDeleteConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel("خيارات المجموعة")
            }
        }
        .alert(feed.isCurrentTeamOwner ? "حذف «\(team?.name ?? "المجموعة")»؟" : "مغادرة «\(team?.name ?? "المجموعة")»؟",
               isPresented: $showDeleteConfirm) {
            Button(feed.isCurrentTeamOwner ? "حذف المجموعة" : "مغادرة المجموعة", role: .destructive) {
                if let id = team?.id { feed.deleteTeam(id) }
                dismiss()
            }
            Button("تراجع", role: .cancel) {}
        } message: {
            Text(feed.isCurrentTeamOwner
                 ? "بيتم حذف المجموعة وكل تمارينها وأعضائها وطرق الدفع من عندك. تقدر تنشئ مجموعة جديدة أي وقت."
                 : "بتغادر المجموعة وتختفي تمارينها من عندك. تقدر ترجع أي وقت برمز الدعوة.")
        }
        .sheet(isPresented: $showAddSession) {
            AddSessionSheet(feed: feed,
                            isPresented: $showAddSession,
                            editingEventID: plan?.sourceEventID,
                            editingTemplateID: plan?.sourceTemplateID,
                            initialPlan: plan.map(draft(from:)) ?? PlanDraft())
        }
    }

    private func centreMap(on plan: FeedPlan?) {
        guard let plan else { return }
        withAnimation(.easeOut(duration: 0.4)) {
            mapPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: plan.latitude, longitude: plan.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.018, longitudeDelta: 0.018)
            ))
        }
    }

    /// Prefills the composer from the displayed session (edit mode). Presented
    /// as a one-off on the event's actual date; the weekday stays selected in
    /// case the user switches to recurring.
    private func draft(from plan: FeedPlan) -> PlanDraft {
        var d = PlanDraft()
        d.name = plan.name
        d.weekdays = Set(plan.weekdays)
        d.startTime = plan.startTime
        d.endTime = plan.endTime
        d.locationName = plan.locationName
        d.locationAddress = plan.locationAddress
        d.latitude = plan.latitude
        d.longitude = plan.longitude
        d.capacity = plan.capacity
        d.capacityPolicy = plan.capacityPolicy
        d.totalVenueCost = venueTotal(plan)
        d.paymentMethods = plan.paymentMethods
        d.scheduleKind = .oneOff
        d.oneOffDate = plan.startDate
        return d
    }

    // MARK: - Hero

    private var heroHeader: some View {
        VStack(spacing: 14) {
            TeamAvatarView(
                avatarData: team?.avatarData ?? nil,
                symbol: team?.symbol ?? "figure.run",
                size: 78,
                cornerRadiusRatio: 0.5,
                fallbackBackground: AnyShapeStyle(TamrinTheme.lime),
                symbolColor: TamrinTheme.ink
            )
            .shadow(color: TamrinTheme.lime.opacity(0.3), radius: 24, y: 10)

            VStack(spacing: 4) {
                Text(team?.name ?? "المجموعة")
                    .font(TamrinFont.font(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(membersLabel(memberCount))
                    .font(TamrinFont.font(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var planSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(teamPlans, id: \.id) { item in
                    let isSelected = item.id == plan?.id
                    Button {
                        selectedPlanID = item.id
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Text(item.name)
                            .font(TamrinFont.font(size: 14, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? TamrinTheme.ink : .white)
                            .padding(.horizontal, 15)
                            .frame(height: 38)
                            .background(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.14)), in: .capsule)
                            .frame(minHeight: TamrinControlMetrics.touchTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - The standing session

    @ViewBuilder
    private var planSection: some View {
        if let plan {
            PlanGlassSection(title: "قالب التمرين", caption: plan.name) {
                VStack(spacing: 12) {
                    // The four facts the group actually asks about: which day,
                    // what time, what the pitch costs, what each player owes.
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 10
                    ) {
                        PlanGlassStat(
                            symbol: "calendar",
                            value: dayText.isEmpty ? "بدون تكرار" : dayText,
                            title: "يوم التمرين"
                        )
                        PlanGlassStat(
                            symbol: "clock.fill",
                            value: "\(plan.startTime.arabicTime) – \(plan.endTime.arabicTime)",
                            title: "وقت التمرين"
                        )
                        PlanGlassStat(
                            symbol: "banknote.fill",
                            value: venueTotal(plan) == 0 ? "بدون تكلفة" : "\(venueTotal(plan).cleanAmount) \(plan.currency)",
                            title: "قيمة الملعب"
                        )
                        PlanGlassStat(
                            symbol: "person.fill",
                            value: plan.price == 0 ? "مجاني" : "\(plan.price.cleanAmount) \(plan.currency)",
                            title: "قطة كل لاعب",
                            emphasised: true
                        )
                    }

                    venueBlock(plan)

                    PlanInfoRow(
                        symbol: "person.2.fill",
                        title: "سعة الموعد",
                        value: "\(plan.capacity.formatted()) لاعب"
                    )
                }
            }
        } else {
            PlanGlassSection(title: "قالب التمرين") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("ما فيه قالب تمرين بعد.")
                        .font(TamrinFont.subheadline)
                        .foregroundStyle(.white.opacity(0.6))

                    if feed.isCurrentTeamOwner {
                        Button {
                            showAddSession = true
                        } label: {
                            Label("أضف موعد التمرين", systemImage: "calendar.badge.plus")
                                .font(TamrinFont.font(size: 15, weight: .bold))
                                .foregroundStyle(TamrinTheme.ink)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: TamrinControlMetrics.actionHeight)
                                .background(TamrinTheme.lime, in: .capsule)
                        }
                        .buttonStyle(SpringCardPressStyle())
                    }
                }
            }
        }
    }

    private func venueBlock(_ plan: FeedPlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Map(position: $mapPosition) {
                Marker(plan.locationName, coordinate: CLLocationCoordinate2D(latitude: plan.latitude, longitude: plan.longitude))
                    .tint(TamrinTheme.lime)
            }
            .frame(height: 128)
            // MapKit draws into its own layer, which the enclosing clipShape
            // does not round — the corners have to be applied here.
            .clipShape(.rect(
                topLeadingRadius: 20,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 20,
                style: .continuous
            ))
            .allowsHitTesting(false)

            HStack(spacing: 11) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TamrinTheme.lime)

                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.locationName.isEmpty ? "الملعب غير محدد" : plan.locationName)
                        .font(TamrinFont.font(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !plan.locationAddress.isEmpty {
                        Text(plan.locationAddress)
                            .font(TamrinFont.font(size: 12, weight: .regular))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .background(.white.opacity(0.07), in: .rect(cornerRadius: 20, style: .continuous))
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("الملعب: \(plan.locationName)")
    }

    // MARK: - Members

    private var membersCard: some View {
        PlanGlassSection(
            title: "الأعضاء",
            caption: memberCount == 0 ? nil : membersLabel(memberCount)
        ) {
            if members.isEmpty {
                Text(rosterUnavailable
                     ? "تعذر تحميل قائمة الأعضاء. اسحب لتحديث الصفحة."
                     : "ما انضم أحد بعد. شارك رابط الدعوة عشان يدخلون.")
                    .font(TamrinFont.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(members) { member in
                        HStack(spacing: 12) {
                            PlanMemberAvatar(
                                name: member.displayName,
                                size: 40,
                                tint: member.role == .admin ? TamrinTheme.lime : Color.white.opacity(0.24)
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName)
                                    .font(TamrinFont.font(size: 16, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(member.isPending
                                     ? "بانتظار الانضمام"
                                     : (member.role == .admin ? "مشرف المجموعة" : "عضو"))
                                    .font(TamrinFont.font(size: 12, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.5))
                            }

                            Spacer(minLength: 6)

                            if member.role == .admin {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(TamrinTheme.lime)
                            } else if member.isPending {
                                Image(systemName: "clock")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 58)
                        .background(.white.opacity(0.06), in: .rect(cornerRadius: 18, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: - Invite (organizer only)

    @ViewBuilder
    private var inviteCard: some View {
        // Inviting is an owner (admin) action — members don't see the code/link.
        if let team {
            PlanGlassSection(title: "مشاركة المجموعة") {
                VStack(spacing: 12) {
                    // Share stays available even before the backend has issued
                    // a join URL — the invite code alone is enough to join.
                    ShareLink(
                        item: team.inviteURL?.absoluteString ?? team.inviteCode,
                        subject: Text("انضم لمجموعة \(team.name)"),
                        message: Text(team.inviteURL == nil
                                      ? "انضم لمجموعتنا في تمرين برمز الدعوة: \(team.inviteCode)"
                                      : "هذا رابط الانضمام لمجموعتنا في تمرين")
                    ) {
                        Label(team.inviteURL == nil ? "شارك رمز الدعوة" : "شارك رابط الانضمام",
                              systemImage: "square.and.arrow.up")
                            .font(TamrinFont.font(size: 16, weight: .bold))
                            .foregroundStyle(TamrinTheme.ink)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: TamrinControlMetrics.actionHeight)
                            .background(TamrinTheme.lime, in: .capsule)
                    }
                    .buttonStyle(SpringCardPressStyle())

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("رمز الدعوة")
                                .font(TamrinFont.font(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                            Text(team.inviteCode)
                                .font(TamrinFont.font(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .kerning(2)
                        }

                        Spacer(minLength: 8)

                        Button {
                            // Copy the full join link (same as the share button), not just the code.
                            UIPasteboard.general.string = team.inviteURL?.absoluteString ?? team.inviteCode
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            withAnimation(.snappy) { didCopyCode = true }
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                withAnimation(.snappy) { didCopyCode = false }
                            }
                        } label: {
                            Label(didCopyCode ? "نُسخ" : "نسخ", systemImage: didCopyCode ? "checkmark" : "doc.on.doc")
                                .font(TamrinFont.font(size: 13, weight: .medium))
                                .foregroundStyle(didCopyCode ? TamrinTheme.lime : .white)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(.white.opacity(0.13), in: .capsule)
                                .frame(minHeight: TamrinControlMetrics.touchTarget)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("نسخ رابط الانضمام")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.07), in: .rect(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }

    private var paymentsCard: some View {
        PlanGlassSection(title: "طرق الدفع") {
            let methods = feed.methodsForCurrentTeam()

            if methods.isEmpty {
                Text("ما أضفت طرق دفع بعد.")
                    .font(TamrinFont.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(methods) { method in
                        HStack(spacing: 12) {
                            PaymentProviderLogo(provider: method.provider, size: 38)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(method.provider.displayName)
                                    .font(TamrinFont.font(size: 15, weight: .medium))
                                    .foregroundStyle(.white)
                                Text(method.provider == .cash ? "الدفع في الملعب" : method.maskedSummary)
                                    .font(TamrinFont.font(size: 12, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.5))
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 56)
                        .background(.white.opacity(0.06), in: .rect(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        }
    }

    private func weekdayName(_ value: Int) -> String? {
        [1: "الأحد", 2: "الاثنين", 3: "الثلاثاء", 4: "الأربعاء", 5: "الخميس", 6: "الجمعة", 7: "السبت"][value]
    }
}

private struct PlanInfoRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TamrinTheme.lime)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.1), in: .circle)

            Text(title)
                .font(TamrinFont.font(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))

            Spacer(minLength: 8)

            Text(value)
                .font(TamrinFont.font(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 56)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 18, style: .continuous))
    }
}

private struct PlanGlassSection<Content: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(TamrinFont.font(size: 17, weight: .bold))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                if let caption {
                    Text(caption)
                        .font(TamrinFont.font(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.09), in: .rect(cornerRadius: 26, style: .continuous))
    }
}

private struct PlanGlassStat: View {
    let symbol: String
    let value: String
    let title: String
    /// The per-player share is the number the group asks about most, so it
    /// carries a heavier surface and a larger figure — no colour fill, which
    /// read as a loud slab against the rest of the card.
    var emphasised = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(emphasised ? 0.9 : 0.6))

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(TamrinFont.font(size: emphasised ? 19 : 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(title)
                    .font(TamrinFont.font(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(14)
        .background(
            .white.opacity(emphasised ? 0.14 : 0.07),
            in: .rect(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

private struct PlanMemberAvatar: View {
    let name: String
    let size: CGFloat
    var tint: Color
    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.prefix(1)))
                    .font(TamrinFont.font(size: size * 0.38, weight: .bold))
                    .foregroundStyle(TamrinTheme.ink)
            )
    }
}
