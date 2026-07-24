import SwiftUI
import MapKit

/// Team / plan details page — the designer's PlanTemplateDetailView (member
/// view) bound to HomeStore. Admin edit/publish affordances are omitted;
/// the plan switcher only appears when a team has more than one plan.
private enum PlanDetailTab: String, CaseIterable, Identifiable {
    case info, members, payments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: "التمرين"
        case .members: "الأعضاء"
        case .payments: "الدفع"
        }
    }
}

struct TeamDetailView: View {
    @Bindable var feed: HomeStore
    @Environment(\.dismiss) private var dismiss
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedTab: PlanDetailTab = .info
    @State private var selectedPlanID: UUID?
    @State private var isBarPinned = false
    @State private var isTabJumping = false
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
    private var dayText: String {
        guard let plan else { return "" }
        return plan.weekdays.compactMap { weekdayName($0) }.joined(separator: "، ")
    }
    private var artName: String {
        let seed = team?.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) } ?? 0
        return "ExerciseArt\((seed % 3) + 1)"
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                HomeArtBackdrop(artName: artName, hasArt: true)

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            heroHeader

                            if teamPlans.count > 1 {
                                planSwitcher
                            }

                            PlanPillTabBar(selection: $selectedTab) { tab in
                                jump(to: tab, proxy: proxy)
                            }
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.frame(in: .global).minY
                            } action: { minY in
                                let pinned = minY <= geo.safeAreaInsets.top + 1
                                if pinned != isBarPinned {
                                    withAnimation(.easeInOut(duration: 0.2)) { isBarPinned = pinned }
                                }
                            }

                            infoSection
                                .id(PlanDetailTab.info)
                                .onScrollVisibilityChange(threshold: 0.4) { visible in
                                    if visible, !isTabJumping { withAnimation(.snappy(duration: 0.25)) { selectedTab = .info } }
                                }

                            membersCard
                                .id(PlanDetailTab.members)
                                .onScrollVisibilityChange(threshold: 0.35) { visible in
                                    if visible, !isTabJumping { withAnimation(.snappy(duration: 0.25)) { selectedTab = .members } }
                                }

                            paymentsSection
                                .id(PlanDetailTab.payments)
                                .onScrollVisibilityChange(threshold: 0.5) { visible in
                                    if visible, !isTabJumping { withAnimation(.snappy(duration: 0.25)) { selectedTab = .payments } }
                                }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .padding(.bottom, 40)
                    }
                    .refreshable { await feed.refresh() }
                    .mask {
                        // Fades content passing behind the nav bar / pinned tabs.
                        VStack(spacing: 0) {
                            Color.clear
                                .frame(height: geo.safeAreaInsets.top + (isBarPinned ? 54 : 0))
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: 16)
                            Color.black
                        }
                        .ignoresSafeArea()
                    }
                    .overlay(alignment: .top) {
                        if isBarPinned {
                            PlanPillTabBar(selection: $selectedTab) { tab in
                                jump(to: tab, proxy: proxy)
                            }
                            .padding(.horizontal, 20)
                            .transition(.opacity)
                        }
                    }
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
        .onAppear {
            if let plan {
                mapPosition = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: plan.latitude, longitude: plan.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.018, longitudeDelta: 0.018)
                ))
            }
        }
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
        d.price = plan.price
        d.scheduleKind = .oneOff
        d.oneOffDate = plan.startDate
        return d
    }

    private var planSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(teamPlans, id: \.id) { item in
                    let isSelected = item.id == plan?.id
                    Button {
                        selectedPlanID = item.id
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.easeOut(duration: 0.4)) {
                            mapPosition = .region(MKCoordinateRegion(
                                center: CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude),
                                span: MKCoordinateSpan(latitudeDelta: 0.018, longitudeDelta: 0.018)
                            ))
                        }
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

    private func jump(to tab: PlanDetailTab, proxy: ScrollViewProxy) {
        UISelectionFeedbackGenerator().selectionChanged()
        isTabJumping = true
        withAnimation(.snappy(duration: 0.35)) {
            selectedTab = tab
            proxy.scrollTo(tab, anchor: UnitPoint(x: 0.5, y: 0.082))
        }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            isTabJumping = false
        }
    }

    private var heroHeader: some View {
        VStack(spacing: 16) {
            TeamAvatarView(
                avatarData: team?.avatarData ?? nil,
                symbol: team?.symbol ?? "figure.run",
                size: 84,
                cornerRadiusRatio: 0.5,
                fallbackBackground: AnyShapeStyle(TamrinTheme.lime),
                symbolColor: TamrinTheme.ink
            )
            .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
            .shadow(color: TamrinTheme.lime.opacity(0.35), radius: 26, y: 10)

            VStack(spacing: 5) {
                Text(plan?.name ?? "قالب التمرين")
                    .font(TamrinFont.font(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(heroSubtitle)
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var heroSubtitle: String {
        var parts: [String] = ["\(members.count.formatted()) عضوًا"]
        if !dayText.isEmpty { parts.append("كل \(dayText)") }
        return parts.joined(separator: " · ")
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let plan {
                quickStats(plan)
                scheduleCard(plan)
                locationCard(plan)
            } else {
                PlanGlassSection(title: "قالب التمرين") {
                    Text("لا يوجد قالب تمرين بعد.")
                        .font(TamrinFont.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private func quickStats(_ plan: FeedPlan) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            PlanGlassStat(
                symbol: "clock.fill",
                value: "\(plan.startTime.arabicTime) – \(plan.endTime.arabicTime)",
                title: "وقت التمرين"
            )
            PlanGlassStat(
                symbol: "person.2.fill",
                value: members.count.formatted(),
                title: "الأعضاء"
            )
            PlanGlassStat(
                symbol: "creditcard.fill",
                value: plan.price == 0 ? "مجاني" : "\(plan.price.cleanAmount) \(plan.currency)",
                title: "القَطّة"
            )
            PlanGlassStat(
                symbol: "figure.run",
                value: plan.capacity.formatted(),
                title: plan.capacityPolicy == .waitlist ? "السعة · قائمة انتظار" : "السعة · إغلاق التسجيل"
            )
        }
    }

    private func scheduleCard(_ plan: FeedPlan) -> some View {
        PlanGlassSection(title: "الجدول") {
            VStack(spacing: 0) {
                PlanInfoRow(symbol: "calendar", title: "أيام التمرين", value: dayText.isEmpty ? "بدون تكرار" : dayText)
                Divider().overlay(.white.opacity(0.08))
                PlanInfoRow(symbol: "play.circle", title: "تاريخ البداية", value: plan.startDate.arabicDate)
                Divider().overlay(.white.opacity(0.08))
                PlanInfoRow(
                    symbol: "flag.checkered",
                    title: "تاريخ النهاية",
                    value: plan.endDate.map { $0.arabicDate } ?? "مستمرة بدون نهاية"
                )
            }
        }
    }

    private func locationCard(_ plan: FeedPlan) -> some View {
        PlanGlassSection(title: "الموقع") {
            VStack(alignment: .leading, spacing: 12) {
                Map(position: $mapPosition) {
                    Marker(plan.locationName, coordinate: CLLocationCoordinate2D(latitude: plan.latitude, longitude: plan.longitude))
                        .tint(TamrinTheme.lime)
                }
                .frame(height: 168)
                .clipShape(.rect(cornerRadius: 18, style: .continuous))
                .allowsHitTesting(false)

                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TamrinTheme.lime)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.locationName)
                            .font(TamrinFont.font(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                        if !plan.locationAddress.isEmpty {
                            Text(plan.locationAddress)
                                .font(TamrinFont.font(size: 13, weight: .regular))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
            }
        }
    }

    private var membersCard: some View {
        PlanGlassSection(title: "الأعضاء · \(members.count.formatted())") {
            VStack(spacing: 0) {
                ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                    HStack(spacing: 12) {
                        PlanMemberAvatar(
                            name: member.displayName,
                            size: 40,
                            tint: member.role == .admin ? TamrinTheme.lime : Color.white.opacity(0.22)
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.displayName)
                                .font(TamrinFont.font(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                            Text(member.isPending ? "بانتظار الانضمام" : (member.role == .admin ? "مشرف المجموعة" : "عضو"))
                                .font(TamrinFont.font(size: 12, weight: .regular))
                                .foregroundStyle(.white.opacity(0.5))
                        }

                        Spacer()

                        if member.role == .admin {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(TamrinTheme.lime)
                        } else if member.isPending {
                            Image(systemName: "clock")
                                .font(.system(size: 14))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 10)

                    if index < members.count - 1 {
                        Divider().overlay(.white.opacity(0.08))
                    }
                }

                if members.isEmpty {
                    Text("لا يوجد أعضاء بعد.")
                        .font(TamrinFont.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private var paymentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            paymentsCard
            inviteCard
        }
    }

    private var paymentsCard: some View {
        PlanGlassSection(title: "طرق الدفع") {
            let methods = feed.methodsForCurrentTeam()

            VStack(spacing: 0) {
                if methods.isEmpty {
                    Text("لم تُضف طرق دفع بعد.")
                        .font(TamrinFont.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(methods.enumerated()), id: \.element.id) { index, method in
                        HStack(spacing: 12) {
                            Image(systemName: method.kind == .bank ? "building.columns.fill" : "banknote.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(TamrinTheme.lime)
                                .frame(width: 40, height: 40)
                                .background(.white.opacity(0.1), in: .circle)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(method.title)
                                    .font(TamrinFont.font(size: 16, weight: .medium))
                                    .foregroundStyle(.white)
                                Text(method.kind == .bank ? "تحويل بنكي" : "دفع نقدي")
                                    .font(TamrinFont.font(size: 12, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.5))
                            }

                            Spacer()
                        }
                        .padding(.vertical, 10)

                        if index < methods.count - 1 {
                            Divider().overlay(.white.opacity(0.08))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var inviteCard: some View {
        // Inviting is an owner (admin) action — members don't see the code/link.
        if let team, feed.isCurrentTeamOwner {
            PlanGlassSection(title: "الدعوة") {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Text(team.inviteCode)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .kerning(2)

                        Spacer()

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
                                .padding(.horizontal, 13)
                                .frame(height: 34)
                                .background(.white.opacity(0.12), in: .capsule)
                                .frame(minHeight: TamrinControlMetrics.touchTarget)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                    .background(.white.opacity(0.07), in: .rect(cornerRadius: 16, style: .continuous))

                    if let url = team.inviteURL {
                        ShareLink(item: url) {
                            Label("مشاركة رابط الانضمام", systemImage: "square.and.arrow.up")
                                .font(TamrinFont.headline)
                                .foregroundStyle(TamrinTheme.ink)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: TamrinControlMetrics.actionHeight)
                                .background(TamrinTheme.lime, in: .rect(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(SpringCardPressStyle())
                    }
                }
            }
        }
    }

    private func weekdayName(_ value: Int) -> String? {
        [1: "الأحد", 2: "الاثنين", 3: "الثلاثاء", 4: "الأربعاء", 5: "الخميس", 6: "الجمعة", 7: "السبت"][value]
    }
}

private struct PlanPillTabBar: View {
    @Binding var selection: PlanDetailTab
    let onTap: (PlanDetailTab) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(PlanDetailTab.allCases) { tab in
                pill(tab)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
    }

    // Plain buttons + capsule backgrounds (the planSwitcher pattern) — glass
    // buttons nested in a GlassEffectContainer were not receiving taps.
    private func pill(_ tab: PlanDetailTab) -> some View {
        let isSelected = selection == tab
        return Button { onTap(tab) } label: {
            Text(tab.title)
                .font(TamrinFont.font(size: 15, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? TamrinTheme.ink : .white.opacity(0.85))
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.14)), in: .capsule)
                .frame(minHeight: TamrinControlMetrics.touchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PlanInfoRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TamrinTheme.lime)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.1), in: .circle)

            Text(title)
                .font(TamrinFont.font(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))

            Spacer()

            Text(value)
                .font(TamrinFont.font(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 9)
    }
}

private struct PlanGlassSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(TamrinFont.font(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
        }
    }
}

private struct PlanGlassStat: View {
    let symbol: String
    let value: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TamrinTheme.lime)

            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(TamrinFont.font(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(title)
                    .font(TamrinFont.font(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
        }
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
            .overlay(Text(String(name.prefix(1))).font(TamrinFont.font(size: size * 0.38, weight: .bold)).foregroundStyle(TamrinTheme.ink))
            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 3))
            .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
    }
}
