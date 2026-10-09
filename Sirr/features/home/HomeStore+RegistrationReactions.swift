//
//  HomeStore+RegistrationReactions.swift
//  Sirr
//
//  Reactions on each seat of an exercise. A fixture or preview exercise
//  answers locally with the same shape the RPC returns.
//

import Foundation

extension HomeStore {
    /// Keyed by seat (participant id).
    func registrationReactions(for occurrence: FeedOccurrence) -> [UUID: SeatReactions] {
        registrationReactionsByEvent[occurrence.id] ?? [:]
    }

    /// Open from registration until a day after the exercise ends, the same
    /// window the server enforces.
    func canReactToRegistrations(in occurrence: FeedOccurrence) -> Bool {
        guard currentUserID != nil, !occurrence.isCancelled,
              registrationReactionsByEvent[occurrence.id] != nil else { return false }
        return Date.now < (occurrence.endAt ?? occurrence.startAt).addingTimeInterval(24 * 60 * 60)
    }

    func loadRegistrationReactions(for occurrence: FeedOccurrence) async {
        if usesLocalLineupTalk(for: occurrence.id) {
            #if DEBUG
            var current = registrationReactionsByEvent[occurrence.id] ?? [:]
            let seeded = HomeDebugMemberFixture.registrationReactions(
                roster: roster(for: occurrence),
                capacity: occurrence.capacity,
                excluding: currentUserID
            )
            // New seats get their seed; seats already reacted to keep theirs.
            for (seat, reactions) in seeded where current[seat] == nil {
                current[seat] = reactions
            }
            registrationReactionsByEvent[occurrence.id] = current
            #endif
            return
        }
        do {
            if let seats = try await RegistrationReactionsService.shared.get(eventID: occurrence.id) {
                registrationReactionsByEvent[occurrence.id] = Self.keyed(seats)
            }
        } catch {
            // Keep what is showing; the next open tries again.
        }
    }

    /// Nil on success, or what to tell the person. Applied at once so the
    /// emoji lands under the finger; a refusal puts back what was there.
    func reactToRegistration(_ emoji: String?, seat: FeedMember, in occurrence: FeedOccurrence) async -> String? {
        guard let me = currentUserID, var all = registrationReactionsByEvent[occurrence.id] else {
            return String(localized: "تعذر إكمال العملية. حاول مرة أخرى.")
        }
        let before = all
        var entry = all[seat.id] ?? SeatReactions(participantID: seat.id, context: nil, reactions: [])
        entry.reactions.removeAll { $0.userID == me }
        if let emoji {
            let myName = profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "أنت") : profileName
            entry.reactions.append(LineupThoughtReaction(userID: me, name: myName, emoji: emoji))
        }
        all[seat.id] = entry
        registrationReactionsByEvent[occurrence.id] = all

        guard !usesLocalLineupTalk(for: occurrence.id) else { return nil }
        do {
            if let seats = try await RegistrationReactionsService.shared.react(emoji, to: seat.id) {
                registrationReactionsByEvent[occurrence.id] = Self.keyed(seats)
            }
            return nil
        } catch {
            registrationReactionsByEvent[occurrence.id] = before
            return ServerErrorMessage.arabic(for: error)
        }
    }

    private static func keyed(_ seats: [SeatReactions]) -> [UUID: SeatReactions] {
        Dictionary(seats.map { ($0.participantID, $0) }, uniquingKeysWith: { _, latest in latest })
    }
}
