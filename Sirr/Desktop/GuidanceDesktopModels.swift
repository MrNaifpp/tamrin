import Foundation
import SwiftUI
import Combine

enum WorkspaceRole: String, CaseIterable, Identifiable {
    case counselor = "المرشد"
    case student = "الطالب"
    case admin = "المشرف"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .counselor:
            return "person.crop.circle.badge.checkmark"
        case .student:
            return "graduationcap.fill"
        case .admin:
            return "slider.horizontal.3"
        }
    }

    var summary: String {
        switch self {
        case .counselor:
            return "إدارة الجلسات اليومية والطلبات الجديدة ومتابعة الحالة المباشرة."
        case .student:
            return "حجز جلسات مناسبة، متابعة التوصيات، ورؤية التقدم الشخصي بشكل أوضح."
        case .admin:
            return "إشراف على المرشدين، الفئات، والمراكز مع قراءة صحية للمنصة بالكامل."
        }
    }
}

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case overview = "نظرة عامة"
    case sessions = "الجلسات"
    case schedule = "الجدول"
    case students = "الطلاب"
    case mentors = "المرشدون"
    case centers = "المراكز"
    case insights = "التحليلات"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview:
            return "square.grid.2x2.fill"
        case .sessions:
            return "rectangle.stack.badge.person.crop"
        case .schedule:
            return "calendar.badge.clock"
        case .students:
            return "person.3.sequence.fill"
        case .mentors:
            return "person.text.rectangle.fill"
        case .centers:
            return "building.2.crop.circle.fill"
        case .insights:
            return "chart.xyaxis.line"
        }
    }

    var subtitle: String {
        switch self {
        case .overview:
            return "ملخص حيّ للحالة العامة"
        case .sessions:
            return "قائمة الجلسات والمتابعة"
        case .schedule:
            return "بناء الساعات المتاحة"
        case .students:
            return "الملفات وحالة الحجز"
        case .mentors:
            return "الكوادر والتخصصات"
        case .centers:
            return "الفروع وتغطية الأيام"
        case .insights:
            return "قراءة الاتجاهات والأداء"
        }
    }
}

enum SessionStatus: String, CaseIterable, Identifiable {
    case scheduled = "قادم"
    case inProgress = "جارية"
    case followUp = "متابعة"
    case completed = "مكتملة"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .scheduled:
            return Color(red: 0.32, green: 0.33, blue: 0.84)
        case .inProgress:
            return Color(red: 0.06, green: 0.64, blue: 0.47)
        case .followUp:
            return Color(red: 0.91, green: 0.56, blue: 0.16)
        case .completed:
            return Color.secondary
        }
    }

    var icon: String {
        switch self {
        case .scheduled:
            return "clock.fill"
        case .inProgress:
            return "dot.radiowaves.left.and.right"
        case .followUp:
            return "arrow.triangle.2.circlepath"
        case .completed:
            return "checkmark.seal.fill"
        }
    }
}

struct SessionRecord: Identifiable, Hashable {
    let id: UUID
    var studentName: String
    var track: String
    var topic: String
    var startAt: Date
    var durationMinutes: Int
    var status: SessionStatus
    var mentorName: String
    var centerName: String
    var notes: String
    var recommendation: String
}

struct StudentProfile: Identifiable, Hashable {
    let id: UUID
    var name: String
    var major: String
    var camp: String
    var sessionsCount: Int
    var nextFocus: String
    var rating: Double
}

struct MentorProfile: Identifiable, Hashable {
    let id: UUID
    var name: String
    var specialty: String
    var tags: [String]
    var workload: Int
    var satisfaction: Int
}

struct CenterProfile: Identifiable, Hashable {
    let id: UUID
    var name: String
    var city: String
    var openDays: String
    var activeRooms: Int
}

struct AvailabilityDay: Identifiable, Hashable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var opensAt: Date
    var closesAt: Date
    var slotMinutes: Int
    var acceptsWalkIns: Bool
}

struct TrendPoint: Identifiable, Hashable {
    let id: UUID
    var label: String
    var booked: Int
    var pending: Int
}

struct DashboardMetric: Identifiable, Hashable {
    let id: UUID
    var title: String
    var value: Int
    var accent: Color
    var symbol: String
}

final class GuidanceDesktopStore: ObservableObject {
    @Published var role: WorkspaceRole = .counselor
    @Published var selectedSection: WorkspaceSection? = .overview
    @Published var searchText: String = ""
    @Published var selectedSessionID: SessionRecord.ID?
    @Published var sessions: [SessionRecord]
    @Published var students: [StudentProfile]
    @Published var mentors: [MentorProfile]
    @Published var centers: [CenterProfile]
    @Published var availability: [AvailabilityDay]
    @Published var trends: [TrendPoint]

    init() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())

        func date(
            dayOffset: Int,
            hour: Int,
            minute: Int
        ) -> Date {
            let base = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(
                bySettingHour: hour,
                minute: minute,
                second: 0,
                of: base
            ) ?? base
        }

        sessions = [
            SessionRecord(
                id: UUID(),
                studentName: "عبدالمحسن القحطاني",
                track: "تطوير الويب",
                topic: "اختيار المسار المهني بعد المعسكر",
                startAt: date(dayOffset: 0, hour: 9, minute: 0),
                durationMinutes: 30,
                status: .inProgress,
                mentorName: "سعيد بن علي",
                centerName: "المركز الرئيسي",
                notes: "يميل الطالب إلى الواجهات وبناء منتجات سريعة الإيقاع، لكنه متردد بين التخصص والعمومية.",
                recommendation: "التركيز على Frontend Product Engineering مع مشروعين عمليين خلال 6 أسابيع."
            ),
            SessionRecord(
                id: UUID(),
                studentName: "سارة الغامدي",
                track: "علوم البيانات",
                topic: "ترتيب أولويات التعلم بعد التخرج",
                startAt: date(dayOffset: 0, hour: 11, minute: 30),
                durationMinutes: 45,
                status: .scheduled,
                mentorName: "نورة الشهري",
                centerName: "مركز جدة",
                notes: "تحتاج خارطة واضحة بين Python، الإحصاء، والـ portfolio.",
                recommendation: "البدء بثلاث دراسات حالة مختصرة بدل التوسع في الأدوات دفعة واحدة."
            ),
            SessionRecord(
                id: UUID(),
                studentName: "ريم الدوسري",
                track: "الحوسبة السحابية",
                topic: "الاستعداد لشهادة AWS Cloud Practitioner",
                startAt: date(dayOffset: 1, hour: 10, minute: 0),
                durationMinutes: 30,
                status: .followUp,
                mentorName: "خالد العتيبي",
                centerName: "مركز الدمام",
                notes: "التقدم جيد لكن التطبيق العملي أقل من المطلوب.",
                recommendation: "بناء mini architecture على AWS وكتابة rationale مختصر لكل خدمة."
            ),
            SessionRecord(
                id: UUID(),
                studentName: "خالد الشمري",
                track: "الأمن السيبراني",
                topic: "اختيار أول شهادة احترافية",
                startAt: date(dayOffset: -1, hour: 13, minute: 0),
                durationMinutes: 30,
                status: .completed,
                mentorName: "د. خالد العتيبي",
                centerName: "المركز الرئيسي",
                notes: "الطالب واضح في ميوله إلى الـ blue team ولديه أساس جيد في الشبكات.",
                recommendation: "التركيز على SOC fundamentals ثم Security+ بدل القفز المبكر للمسارات المتقدمة."
            ),
            SessionRecord(
                id: UUID(),
                studentName: "لمى السبيعي",
                track: "UX/UI",
                topic: "الانتقال من التصميم إلى Frontend",
                startAt: date(dayOffset: 2, hour: 12, minute: 30),
                durationMinutes: 45,
                status: .scheduled,
                mentorName: "سعيد بن علي",
                centerName: "مركز جدة",
                notes: "خلفية تصميم ممتازة وتحتاج ترتيب رحلة تعلم تقنية.",
                recommendation: "البدء بـ HTML/CSS ثم React fundamentals مع مشروع portfolio حي."
            ),
        ]

        students = [
            StudentProfile(id: UUID(), name: "عبدالمحسن القحطاني", major: "علوم الحاسب", camp: "تطوير الويب", sessionsCount: 4, nextFocus: "بناء بورتفوليو", rating: 4.8),
            StudentProfile(id: UUID(), name: "سارة الغامدي", major: "الإحصاء", camp: "علوم البيانات", sessionsCount: 2, nextFocus: "دراسات حالة", rating: 4.6),
            StudentProfile(id: UUID(), name: "ريم الدوسري", major: "هندسة الحاسب", camp: "الحوسبة السحابية", sessionsCount: 3, nextFocus: "اختبار شهادات", rating: 4.9),
            StudentProfile(id: UUID(), name: "لمى السبيعي", major: "التصميم الرقمي", camp: "UX/UI", sessionsCount: 1, nextFocus: "التحول التقني", rating: 4.7),
        ]

        mentors = [
            MentorProfile(id: UUID(), name: "سعيد بن علي", specialty: "تجربة المستخدم والمنتجات", tags: ["UX", "Frontend"], workload: 8, satisfaction: 96),
            MentorProfile(id: UUID(), name: "نورة الشهري", specialty: "إدارة المشاريع", tags: ["قيادة", "تنظيم"], workload: 6, satisfaction: 92),
            MentorProfile(id: UUID(), name: "د. خالد العتيبي", specialty: "هندسة البرمجيات", tags: ["iOS", "AI"], workload: 7, satisfaction: 94),
            MentorProfile(id: UUID(), name: "ريم العنزي", specialty: "الحوسبة السحابية", tags: ["AWS", "DevOps"], workload: 5, satisfaction: 90),
        ]

        centers = [
            CenterProfile(id: UUID(), name: "المركز الرئيسي", city: "الرياض", openDays: "الأحد - الخميس", activeRooms: 8),
            CenterProfile(id: UUID(), name: "مركز جدة", city: "جدة", openDays: "الأحد - الأربعاء", activeRooms: 5),
            CenterProfile(id: UUID(), name: "مركز الدمام", city: "الدمام", openDays: "الأحد - الخميس", activeRooms: 4),
        ]

        availability = [
            AvailabilityDay(id: UUID(), name: "الأحد", isEnabled: true, opensAt: date(dayOffset: 0, hour: 8, minute: 30), closesAt: date(dayOffset: 0, hour: 14, minute: 0), slotMinutes: 30, acceptsWalkIns: false),
            AvailabilityDay(id: UUID(), name: "الاثنين", isEnabled: true, opensAt: date(dayOffset: 1, hour: 9, minute: 0), closesAt: date(dayOffset: 1, hour: 15, minute: 0), slotMinutes: 30, acceptsWalkIns: true),
            AvailabilityDay(id: UUID(), name: "الثلاثاء", isEnabled: true, opensAt: date(dayOffset: 2, hour: 10, minute: 0), closesAt: date(dayOffset: 2, hour: 16, minute: 0), slotMinutes: 45, acceptsWalkIns: false),
            AvailabilityDay(id: UUID(), name: "الأربعاء", isEnabled: false, opensAt: date(dayOffset: 3, hour: 9, minute: 0), closesAt: date(dayOffset: 3, hour: 13, minute: 0), slotMinutes: 30, acceptsWalkIns: false),
            AvailabilityDay(id: UUID(), name: "الخميس", isEnabled: true, opensAt: date(dayOffset: 4, hour: 8, minute: 0), closesAt: date(dayOffset: 4, hour: 12, minute: 30), slotMinutes: 30, acceptsWalkIns: true),
        ]

        trends = [
            TrendPoint(id: UUID(), label: "الأحد", booked: 8, pending: 2),
            TrendPoint(id: UUID(), label: "الاثنين", booked: 11, pending: 1),
            TrendPoint(id: UUID(), label: "الثلاثاء", booked: 7, pending: 3),
            TrendPoint(id: UUID(), label: "الأربعاء", booked: 9, pending: 2),
            TrendPoint(id: UUID(), label: "الخميس", booked: 6, pending: 1),
        ]

        selectedSessionID = sessions.first?.id
    }

    var filteredSessions: [SessionRecord] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return sessions.sorted(by: { $0.startAt < $1.startAt })
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { record in
            [
                record.studentName,
                record.track,
                record.topic,
                record.mentorName,
                record.centerName
            ]
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(query)
        }
        .sorted(by: { $0.startAt < $1.startAt })
    }

    var selectedSession: SessionRecord? {
        if let selectedSessionID {
            return sessions.first(where: { $0.id == selectedSessionID })
        }
        return sessions.first
    }

    var metrics: [DashboardMetric] {
        switch role {
        case .counselor:
            return [
                DashboardMetric(id: UUID(), title: "جلسات اليوم", value: sessions.filter { Calendar.current.isDateInToday($0.startAt) }.count, accent: .blue, symbol: "calendar"),
                DashboardMetric(id: UUID(), title: "جلسة مباشرة", value: sessions.filter { $0.status == .inProgress }.count, accent: .green, symbol: "waveform.path.ecg"),
                DashboardMetric(id: UUID(), title: "متابعات", value: sessions.filter { $0.status == .followUp }.count, accent: .orange, symbol: "arrow.clockwise"),
                DashboardMetric(id: UUID(), title: "مرشدون نشطون", value: mentors.count, accent: .indigo, symbol: "person.2.fill"),
            ]
        case .student:
            return [
                DashboardMetric(id: UUID(), title: "جلسات محجوزة", value: sessions.filter { $0.status == .scheduled || $0.status == .inProgress }.count, accent: .blue, symbol: "bookmark.fill"),
                DashboardMetric(id: UUID(), title: "توصيات جاهزة", value: sessions.filter { !$0.recommendation.isEmpty }.count, accent: .green, symbol: "doc.text.fill"),
                DashboardMetric(id: UUID(), title: "مرشدون متاحون", value: mentors.count, accent: .purple, symbol: "person.badge.plus"),
                DashboardMetric(id: UUID(), title: "مراكز قريبة", value: centers.count, accent: .orange, symbol: "building.2.fill"),
            ]
        case .admin:
            return [
                DashboardMetric(id: UUID(), title: "إجمالي الجلسات", value: sessions.count, accent: .blue, symbol: "rectangle.stack.fill"),
                DashboardMetric(id: UUID(), title: "الطلاب النشطون", value: students.count, accent: .green, symbol: "person.3.fill"),
                DashboardMetric(id: UUID(), title: "الفروع", value: centers.count, accent: .mint, symbol: "map.fill"),
                DashboardMetric(id: UUID(), title: "رضا عام", value: 94, accent: .pink, symbol: "heart.fill"),
            ]
        }
    }

    var weeklySlotsEstimate: Int {
        availability
            .filter(\.isEnabled)
            .reduce(into: 0) { partial, day in
                let minutes = day.closesAt.timeIntervalSince(day.opensAt) / 60
                let count = max(Int(minutes) / max(day.slotMinutes, 1), 0)
                partial += count
            }
    }

    func updateAvailability(_ updatedDay: AvailabilityDay) {
        guard let index = availability.firstIndex(where: { $0.id == updatedDay.id }) else { return }
        availability[index] = updatedDay
    }
}
