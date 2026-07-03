//
//  UpcomingScheduleView.swift
//  Sirr
//
//  "التمارين القادمة" page: informational week strip (today highlighted, dot
//  on workout days), a detailed card for the next workout, then compact rows
//  for the rest. Reuses the already-loaded events — no fetching here.
//

import SwiftUI

struct UpcomingScheduleView: View {
    let events: [EventData]   // sorted by startDate ascending (home's order)
    var onSelect: (EventData) -> Void

    private static let arCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 1 // Sunday
        return c
    }()

    /// Day-name labels indexed by Calendar weekday (1=Sunday … 7=Saturday).
    private static let dayNames = ["", "أحد", "اثنين", "ثلاثاء", "أربعاء", "خميس", "جمعة", "سبت"]

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "ar")
        f.dateFormat = "MMMM"
        return f
    }()

    private static let cardDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "ar")
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "ar")
        f.timeStyle = .short
        return f
    }()

    private static func arDigits(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: "ar")).grouping(.never))
    }

    private var nextEvent: EventData? { events.first }
    private var laterEvents: [EventData] { Array(events.dropFirst()) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                weekStrip
                if let next = nextEvent {
                    sectionTitle("التمرين الجاي")
                    nextCard(next)
                    if !laterEvents.isEmpty {
                        sectionTitle("التمارين القادمة")
                            .padding(.top, 8)
                        VStack(spacing: 12) {
                            ForEach(laterEvents) { event in
                                compactRow(event)
                            }
                        }
                    }
                } else {
                    Text("لا توجد تمارين قادمة")
                        .font(.appBody)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Color(white: 0.95).ignoresSafeArea())
        .navigationTitle("التمارين القادمة")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.layoutDirection, .rightToLeft)
        // The page's surfaces are hardcoded light, so pin the scheme: in
        // device dark mode .primary/.secondary otherwise resolve to white
        // and the text disappears on the white cards.
        .environment(\.colorScheme, .light)
        .toolbarColorScheme(.light, for: .navigationBar)
    }

    // MARK: - Week strip (informational only)

    private var weekStrip: some View {
        let today = Date()
        let cal = Self.arCalendar
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        let workoutDays = Set(events.map { cal.startOfDay(for: $0.startDate) })

        return HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let isToday = cal.isDateInToday(day)
                let hasWorkout = workoutDays.contains(cal.startOfDay(for: day))
                VStack(spacing: 6) {
                    Text(Self.arDigits(cal.component(.day, from: day)))
                        .font(.appCallout)
                        .foregroundStyle(isToday ? .primary : .secondary)
                    Text(Self.dayNames[cal.component(.weekday, from: day)])
                        .font(.appCaption)
                        .foregroundStyle(isToday ? .primary : .secondary)
                    Circle()
                        .fill(hasWorkout ? Color.blue : Color.clear)
                        .frame(width: 5, height: 5)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isToday ? Color.black.opacity(0.06) : Color.clear)
                )
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Cards

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.appSubheadline)
            .foregroundStyle(.primary)
    }

    private func nextCard(_ event: EventData) -> some View {
        Button { onSelect(event) } label: {
            HStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text(daysRemainingValue(to: event.startDate))
                        .font(.appHeadline)
                        .foregroundStyle(.primary)
                    Text(daysRemainingUnit(to: event.startDate))
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 52)

                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1, height: 56)

                VStack(alignment: .leading, spacing: 6) {
                    Text(event.name)
                        .font(.appBodySemibold)
                        .foregroundStyle(.primary)
                    Text(Self.cardDateFormatter.string(from: event.startDate))
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    if let end = event.endDate {
                        Text("من \(Self.timeFormatter.string(from: event.startDate)) ← إلى \(Self.timeFormatter.string(from: end))")
                            .font(.appCaption)
                            .foregroundStyle(.primary.opacity(0.8))
                    }
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func compactRow(_ event: EventData) -> some View {
        Button { onSelect(event) } label: {
            HStack(spacing: 14) {
                VStack(spacing: 2) {
                    Text(Self.arDigits(Self.arCalendar.component(.day, from: event.startDate)))
                        .font(.appBodySemibold)
                        .foregroundStyle(.primary)
                    Text(Self.monthFormatter.string(from: event.startDate))
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 52)

                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1, height: 36)

                Text(event.name)
                    .font(.appBodyMedium)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Days remaining (Arabic plural forms)

    private func daysBetweenTodayAnd(_ date: Date) -> Int {
        let cal = Self.arCalendar
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
    }

    private func daysRemainingValue(to date: Date) -> String {
        let d = daysBetweenTodayAnd(date)
        switch d {
        case ...0: return "اليوم"
        case 1: return "غدًا"
        case 2: return "يومين"
        default: return Self.arDigits(d)
        }
    }

    private func daysRemainingUnit(to date: Date) -> String {
        let d = daysBetweenTodayAnd(date)
        switch d {
        case ...2: return ""
        case 3...10: return "أيام"
        default: return "يوم"
        }
    }
}

#Preview {
    NavigationStack {
        UpcomingScheduleView(
            events: [
                EventData(id: UUID(), name: "تمرين الأسبوع", date: "", startDate: Date().addingTimeInterval(86400 * 5), endDate: Date().addingTimeInterval(86400 * 5 + 7200)),
                EventData(id: UUID(), name: "تمرين الأسبوع", date: "", startDate: Date().addingTimeInterval(86400 * 12), endDate: nil)
            ],
            onSelect: { _ in }
        )
    }
}
