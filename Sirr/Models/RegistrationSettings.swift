//
//  RegistrationSettings.swift
//  Sirr
//
//  The organizer's registration settings for an exercise: when registration
//  opens, whether a seat is granted on sight, and whether guests may come.
//  Saved on the exercise and on the group, so every later exercise starts
//  from the organizer's last choice.
//

import Foundation

enum RegistrationApprovalMode: String, Codable, Hashable {
    /// Seats are granted in registration order until the session fills.
    case auto
    /// Registering sends a request, and only the organizer grants the seat.
    case manual
}

/// "Two days before, at 12:00", read in the group's own time zone. A rule
/// rather than a timestamp, so it carries over to next week's session.
struct RegistrationOpeningRule: Hashable {
    var daysBefore: Int
    /// Minutes after midnight.
    var minuteOfDay: Int

    static let timeZone = TimeZone(identifier: "Asia/Riyadh") ?? .current

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    func opensAt(for start: Date) -> Date {
        let calendar = Self.calendar
        let day = calendar.startOfDay(for: start)
        let openingDay = calendar.date(byAdding: .day, value: -daysBefore, to: day) ?? day
        return calendar.date(byAdding: .minute, value: minuteOfDay, to: openingDay) ?? openingDay
    }

    /// The time of day as a date the time picker can bind to.
    var timeOfDay: Date {
        let calendar = Self.calendar
        return calendar.date(byAdding: .minute, value: minuteOfDay, to: calendar.startOfDay(for: .now)) ?? .now
    }

    static func minuteOfDay(from date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

struct RegistrationSettings: Hashable {
    /// Nil keeps registration open from the moment the exercise is published.
    var opening: RegistrationOpeningRule?
    var approvalMode: RegistrationApprovalMode = .auto
    var guestsAllowed = true

    static let standard = RegistrationSettings()
}

/// One person waiting on the organizer: a member, or a guest a member asked
/// to bring. Each is decided on its own. Carries no timestamp on purpose: the
/// order people asked in is not something anyone gets to see.
struct FeedRegistrationRequest: Identifiable, Hashable {
    let id: UUID
    /// The member themselves; nil on a guest's request.
    var userId: UUID?
    let requestedBy: UUID
    let name: String
    /// Who asked for this guest. Only read on a guest's request.
    var requesterName: String = ""
    var avatarUrl: String? = nil
    var position: String = ""

    var isGuest: Bool { userId == nil }
}

enum MyRegistrationRequestStatus: String {
    case pending
    case declined
}
