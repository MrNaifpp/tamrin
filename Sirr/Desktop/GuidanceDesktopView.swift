import Charts
import SwiftUI

struct GuidanceDesktopView: View {
    @StateObject private var store = GuidanceDesktopStore()
    @Namespace private var roleAnimation

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store)
        } detail: {
            ZStack {
                AmbientBackground()

                VStack(spacing: 20) {
                    HeaderBar(store: store, roleAnimation: roleAnimation)

                    Group {
                        switch store.selectedSection ?? .overview {
                        case .overview:
                            OverviewPane(store: store)
                        case .sessions:
                            SessionsPane(store: store)
                        case .schedule:
                            SchedulePane(store: store)
                        case .students:
                            StudentsPane(store: store)
                        case .mentors:
                            MentorsPane(store: store)
                        case .centers:
                            CentersPane(store: store)
                        case .insights:
                            InsightsPane(store: store)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
                .padding(24)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "ar_SA"))
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: store.selectedSection)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: store.role)
    }
}

private struct Sidebar: View {
    @ObservedObject var store: GuidanceDesktopStore

    var body: some View {
        List(WorkspaceSection.allCases, selection: $store.selectedSection) { section in
            Label(section.rawValue, systemImage: section.icon)
                .font(.appBodySemibold)
                .padding(.vertical, 6)
                .tag(Optional(section))
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 10) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("منصة الإرشاد")
                            .font(.appBodySemibold)
                        Text(store.role.summary)
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Image(systemName: store.role.icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.blue.gradient)
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }
}

private struct HeaderBar: View {
    @ObservedObject var store: GuidanceDesktopStore
    var roleAnimation: Namespace.ID

    var body: some View {
        HStack(spacing: 16) {
            Button {
                store.selectedSection = .sessions
                store.selectedSessionID = store.filteredSessions.first?.id
            } label: {
                Label("جلسة جديدة", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()

            HStack(spacing: 10) {
                ForEach(WorkspaceRole.allCases) { role in
                    Button {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                            store.role = role
                        }
                    } label: {
                        Label(role.rawValue, systemImage: role.icon)
                            .font(.appCallout)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(minWidth: 122)
                            .background {
                                if store.role == role {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color.white.opacity(0.9))
                                        .matchedGeometryEffect(id: "role-pill", in: roleAnimation)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(store.role == role ? .black : .secondary)
                }
            }
            .padding(6)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(store.selectedSection?.rawValue ?? WorkspaceSection.overview.rawValue)
                    .font(.appLargeTitle)
                Text(store.selectedSection?.subtitle ?? WorkspaceSection.overview.subtitle)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OverviewPane: View {
    @ObservedObject var store: GuidanceDesktopStore
    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HeroPanel(role: store.role, liveCount: store.sessions.filter { $0.status == .inProgress }.count)

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.metrics) { metric in
                        MetricCard(metric: metric)
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    GlassPanel(title: "الحركة الأسبوعية", subtitle: "قراءة سريعة للجلسات والطلبات") {
                        Chart(store.trends) { point in
                            BarMark(
                                x: .value("اليوم", point.label),
                                y: .value("الجلسات", point.booked)
                            )
                            .foregroundStyle(.blue.gradient)
                            .cornerRadius(8)

                            LineMark(
                                x: .value("اليوم", point.label),
                                y: .value("طلبات", point.pending)
                            )
                            .foregroundStyle(.orange)
                            .lineStyle(.init(lineWidth: 3, lineCap: .round))

                            PointMark(
                                x: .value("اليوم", point.label),
                                y: .value("طلبات", point.pending)
                            )
                            .foregroundStyle(.orange)
                        }
                        .frame(height: 220)
                    }

                    GlassPanel(title: "أقرب الجلسات", subtitle: "تجهيز أسرع لليوم") {
                        VStack(spacing: 12) {
                            ForEach(store.filteredSessions.prefix(4)) { session in
                                SessionRow(session: session, highlighted: store.selectedSessionID == session.id)
                                    .onTapGesture {
                                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                            store.selectedSection = .sessions
                                            store.selectedSessionID = session.id
                                        }
                                    }
                            }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    GlassPanel(title: "أبرز المرشدين", subtitle: "حمل العمل ورضا المستفيدين") {
                        VStack(spacing: 12) {
                            ForEach(store.mentors.prefix(3)) { mentor in
                                HStack(spacing: 12) {
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(mentor.name)
                                            .font(.appBodySemibold)
                                        Text(mentor.specialty)
                                            .font(.appCaption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(mentor.workload) جلسات")
                                            .font(.appCallout)
                                        Text("%\(mentor.satisfaction)")
                                            .font(.appCaption)
                                            .foregroundStyle(.green)
                                    }
                                }
                                .padding(14)
                                .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        }
                    }

                    GlassPanel(title: "ملخص الجدول", subtitle: "نوافذ الحجز المتاحة هذا الأسبوع") {
                        VStack(alignment: .trailing, spacing: 16) {
                            StatStrip(title: "الأيام المفعّلة", value: "\(store.availability.filter(\.isEnabled).count)")
                            StatStrip(title: "عدد الفتحات", value: "\(store.weeklySlotsEstimate)")
                            StatStrip(title: "نمط الحضور المباشر", value: "\(store.availability.filter(\.acceptsWalkIns).count) أيام")

                            Button("الانتقال لبناء الجدول") {
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                    store.selectedSection = .schedule
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
    }
}

private struct SessionsPane: View {
    @ObservedObject var store: GuidanceDesktopStore

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            GlassPanel(title: "الجلسات", subtitle: "قائمة حية قابلة للبحث") {
                VStack(spacing: 14) {
                    TextField("ابحث باسم الطالب أو التخصص أو الموضوع", text: $store.searchText)
                        .textFieldStyle(.roundedBorder)

                    List(selection: $store.selectedSessionID) {
                        ForEach(store.filteredSessions) { session in
                            SessionRow(session: session, highlighted: store.selectedSessionID == session.id)
                                .tag(session.id)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 520)
                }
            }
            .frame(maxWidth: .infinity)

            GlassPanel(title: "تفاصيل الجلسة", subtitle: "قراءة مركزة بدل نوافذ كثيرة") {
                if let session = store.selectedSession {
                    SessionInspector(session: session)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    ContentUnavailableView(
                        "لا توجد جلسة محددة",
                        systemImage: "tray",
                        description: Text("اختر عنصرًا من القائمة لعرض الملاحظات والتوصيات.")
                    )
                }
            }
            .frame(width: 430)
        }
    }
}

private struct SchedulePane: View {
    @ObservedObject var store: GuidanceDesktopStore

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            GlassPanel(title: "الجدول الأسبوعي", subtitle: "استبدال واجهة البناء الويب بنموذج أصلي أبسط") {
                Form {
                    ForEach(store.availability) { day in
                        AvailabilityEditor(day: day) { updatedDay in
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.84)) {
                                store.updateAvailability(updatedDay)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }

            GlassPanel(title: "الجاهزية", subtitle: "حالة النشر والتغطية") {
                VStack(alignment: .trailing, spacing: 18) {
                    Chart(store.availability.filter(\.isEnabled)) { day in
                        BarMark(
                            x: .value("اليوم", day.name),
                            y: .value("المدة", day.closesAt.timeIntervalSince(day.opensAt) / 3600)
                        )
                        .foregroundStyle(day.acceptsWalkIns ? AnyShapeStyle(.mint.gradient) : AnyShapeStyle(.blue.gradient))
                        .cornerRadius(8)
                    }
                    .frame(height: 220)

                    StatStrip(title: "الأيام النشطة", value: "\(store.availability.filter(\.isEnabled).count)/\(store.availability.count)")
                    StatStrip(title: "إجمالي الفتحات", value: "\(store.weeklySlotsEstimate)")
                    StatStrip(title: "استقبال مباشر", value: "\(store.availability.filter(\.acceptsWalkIns).count)")

                    Button("نشر التحديث") { }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            .frame(width: 420)
        }
    }
}

private struct StudentsPane: View {
    @ObservedObject var store: GuidanceDesktopStore

    var body: some View {
        GlassPanel(title: "الطلاب", subtitle: "عرض أصلي سريع بدل بطاقات ويب متكدسة") {
            Table(store.students) {
                TableColumn("الاسم") { student in
                    Text(student.name)
                        .font(.appBodySemibold)
                }
                TableColumn("التخصص") { student in
                    Text(student.major)
                }
                TableColumn("المعسكر") { student in
                    Text(student.camp)
                }
                TableColumn("الجلسات") { student in
                    Text("\(student.sessionsCount)")
                }
                TableColumn("التركيز القادم") { student in
                    Text(student.nextFocus)
                }
                TableColumn("التقييم") { student in
                    Text(student.rating.formatted(.number.precision(.fractionLength(1))))
                }
            }
            .frame(minHeight: 520)
        }
    }
}

private struct MentorsPane: View {
    @ObservedObject var store: GuidanceDesktopStore

    var body: some View {
        GlassPanel(title: "المرشدون", subtitle: "محتوى مختصر وواضح ومناسب للمكتب") {
            VStack(spacing: 14) {
                ForEach(store.mentors) { mentor in
                    HStack(spacing: 14) {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(mentor.name)
                                .font(.appBodySemibold)
                            Text(mentor.specialty)
                                .font(.appCaption)
                                .foregroundStyle(.secondary)
                            HStack {
                                ForEach(mentor.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.appCaption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(.blue.opacity(0.08), in: Capsule())
                                }
                            }
                        }

                        Spacer()

                        VStack(alignment: .leading, spacing: 8) {
                            Label("\(mentor.workload) جلسات", systemImage: "calendar")
                            Label("%\(mentor.satisfaction) رضا", systemImage: "star.fill")
                        }
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }
}

private struct CentersPane: View {
    @ObservedObject var store: GuidanceDesktopStore

    var body: some View {
        GlassPanel(title: "المراكز", subtitle: "لوحة تشغيلية مختصرة") {
            Table(store.centers) {
                TableColumn("المركز") { center in
                    Text(center.name)
                }
                TableColumn("المدينة") { center in
                    Text(center.city)
                }
                TableColumn("الأيام") { center in
                    Text(center.openDays)
                }
                TableColumn("الغرف النشطة") { center in
                    Text("\(center.activeRooms)")
                }
            }
            .frame(minHeight: 520)
        }
    }
}

private struct InsightsPane: View {
    @ObservedObject var store: GuidanceDesktopStore

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            GlassPanel(title: "تحليل التوزيع", subtitle: "نسبة الحالات حسب الوضع") {
                Chart {
                    ForEach(SessionStatus.allCases) { status in
                        let count = store.sessions.filter { $0.status == status }.count
                        SectorMark(
                            angle: .value("العدد", count),
                            innerRadius: .ratio(0.58),
                            angularInset: 2
                        )
                        .foregroundStyle(status.color.gradient)
                    }
                }
                .frame(height: 240)

                VStack(spacing: 10) {
                    ForEach(SessionStatus.allCases) { status in
                        HStack {
                            Text("\(store.sessions.filter { $0.status == status }.count)")
                                .font(.appBodySemibold)
                            Spacer()
                            Label(status.rawValue, systemImage: status.icon)
                                .foregroundStyle(status.color)
                        }
                        .padding(12)
                        .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }

            GlassPanel(title: "خط زمني", subtitle: "آخر ما يجب متابعته") {
                VStack(spacing: 12) {
                    ForEach(store.filteredSessions.prefix(5)) { session in
                        HStack(alignment: .top, spacing: 12) {
                            Circle()
                                .fill(session.status.color)
                                .frame(width: 10, height: 10)
                                .padding(.top, 6)

                            VStack(alignment: .trailing, spacing: 6) {
                                Text(session.studentName)
                                    .font(.appBodySemibold)
                                Text(session.topic)
                                    .font(.appCaption)
                                    .foregroundStyle(.secondary)
                                Text(session.startAt.formatted(.dateTime.weekday(.wide).hour().minute()))
                                    .font(.appCaption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .frame(width: 420)
        }
    }
}

private struct HeroPanel: View {
    let role: WorkspaceRole
    let liveCount: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.07, green: 0.12, blue: 0.26),
                            Color(red: 0.16, green: 0.38, blue: 0.44),
                            Color(red: 0.85, green: 0.91, blue: 0.96).opacity(0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .trailing, spacing: 16) {
                HStack {
                    if liveCount > 0 {
                        Label("\(liveCount) جلسة مباشرة", systemImage: "waveform.path.ecg")
                            .font(.appCaption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.18), in: Capsule())
                            .symbolEffect(.pulse.byLayer, value: liveCount)
                    }

                    Spacer()
                }

                VStack(alignment: .trailing, spacing: 8) {
                    Text("نسخة Desktop أصلية مبنية على الفكرة الأساسية")
                        .font(.appLargeTitle)
                        .foregroundStyle(.white)
                    Text(role.summary)
                        .font(.appBody)
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(maxWidth: 640, alignment: .trailing)
                }

                HStack(spacing: 12) {
                    Label("Animations ناعمة", systemImage: "sparkles")
                    Label("تنقل أصلي", systemImage: "macwindow.on.rectangle")
                    Label("عناصر Native", systemImage: "switch.2")
                }
                .font(.appCaption)
                .foregroundStyle(.white.opacity(0.92))
            }
            .padding(26)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .shadow(color: .black.opacity(0.12), radius: 30, y: 16)
    }
}

private struct MetricCard: View {
    let metric: DashboardMetric
    @State private var appears = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            HStack {
                Text(metric.value.formatted())
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Spacer()
                Image(systemName: metric.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(metric.accent)
                    .frame(width: 40, height: 40)
                    .background(metric.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Text(metric.title)
                .font(.appCallout)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 124)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .scaleEffect(appears ? 1 : 0.96)
        .opacity(appears ? 1 : 0.6)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                appears = true
            }
        }
    }
}

private struct GlassPanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .trailing, spacing: 18) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(title)
                    .font(.appHeadline)
                Text(subtitle)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topTrailing)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct SessionRow: View {
    let session: SessionRecord
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Text(session.studentName)
                        .font(.appBodySemibold)
                    StatusBadge(status: session.status)
                }
                Text(session.topic)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 10) {
                    Label(session.track, systemImage: "graduationcap.fill")
                    Label(session.startAt.formatted(.dateTime.hour().minute()), systemImage: "clock")
                }
                .font(.appCaption)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Image(systemName: session.status.icon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(session.status.color)
                .symbolEffect(.bounce, value: highlighted)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(highlighted ? session.status.color.opacity(0.12) : Color.white.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(highlighted ? session.status.color.opacity(0.35) : .clear, lineWidth: 1.5)
        )
    }
}

private struct SessionInspector: View {
    let session: SessionRecord

    var body: some View {
        VStack(alignment: .trailing, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.startAt.formatted(.dateTime.weekday(.wide).hour().minute()))
                        .font(.appCallout)
                    Text("\(session.durationMinutes) دقيقة")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(session.studentName)
                        .font(.appHeadline)
                    Text(session.topic)
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            Divider()

            LabeledContent("المرشد") {
                Text(session.mentorName)
            }
            LabeledContent("المركز") {
                Text(session.centerName)
            }
            LabeledContent("المسار") {
                Text(session.track)
            }
            LabeledContent("الحالة") {
                StatusBadge(status: session.status)
            }

            Divider()

            VStack(alignment: .trailing, spacing: 8) {
                Text("ملاحظات")
                    .font(.appBodySemibold)
                Text(session.notes)
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .trailing, spacing: 8) {
                Text("التوصية")
                    .font(.appBodySemibold)
                Text(session.recommendation)
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }
}

private struct AvailabilityEditor: View {
    @State var day: AvailabilityDay
    var onCommit: (AvailabilityDay) -> Void

    var body: some View {
        Section(day.name) {
            Toggle("تفعيل اليوم", isOn: $day.isEnabled)
                .onChange(of: day.isEnabled) { _, _ in onCommit(day) }

            if day.isEnabled {
                DatePicker("يبدأ", selection: $day.opensAt, displayedComponents: .hourAndMinute)
                    .onChange(of: day.opensAt) { _, _ in onCommit(day) }

                DatePicker("ينتهي", selection: $day.closesAt, displayedComponents: .hourAndMinute)
                    .onChange(of: day.closesAt) { _, _ in onCommit(day) }

                Stepper("مدة الجلسة: \(day.slotMinutes) دقيقة", value: $day.slotMinutes, in: 15...90, step: 15)
                    .onChange(of: day.slotMinutes) { _, _ in onCommit(day) }

                Toggle("قبول حضور مباشر", isOn: $day.acceptsWalkIns)
                    .onChange(of: day.acceptsWalkIns) { _, _ in onCommit(day) }
            }
        }
    }
}

private struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        Label(status.rawValue, systemImage: status.icon)
            .font(.appCaption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(status.color.opacity(0.12), in: Capsule())
            .foregroundStyle(status.color)
    }
}

private struct StatStrip: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(value)
                .font(.appBodySemibold)
            Spacer()
            Text(title)
                .font(.appCaption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AmbientBackground: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.97, blue: 1.0),
                    Color(red: 0.97, green: 0.98, blue: 0.99),
                    Color.white
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.blue.opacity(0.13))
                .frame(width: 320, height: 320)
                .blur(radius: 18)
                .offset(x: animate ? 260 : 160, y: animate ? -120 : -190)

            Circle()
                .fill(Color.mint.opacity(0.12))
                .frame(width: 300, height: 300)
                .blur(radius: 22)
                .offset(x: animate ? -290 : -170, y: animate ? 180 : 110)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}

#Preview {
    GuidanceDesktopView()
}
