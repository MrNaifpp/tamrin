#if DEBUG
import Foundation

extension HomeDebugMemberFixture {
    /// Every context the server can report, spread over the fixture roster,
    /// with a few reactions already in so the pills have something to show.
    static func registrationReactions(
        roster: [FeedMember],
        capacity: Int,
        excluding me: UUID?
    ) -> [UUID: SeatReactions] {
        let seated = roster.filter { $0.status != .waitlisted }
            .sorted { ($0.joinedAt ?? .distantPast) < ($1.joinedAt ?? .distantPast) }
        let reactors = seated.filter { $0.userId != nil && $0.userId != me }
        let emoji = ["👏", "🔥", "💪", "😂", "❤️"]

        var result: [UUID: SeatReactions] = [:]
        for (index, seat) in seated.enumerated() {
            var context: RegistrationContext?
            if index == 0 {
                context = .first
            } else if seated.count >= capacity, index == seated.count - 1 {
                context = .lastSeat
            } else if seat.userId != nil {
                switch index {
                case 1: context = .newcomer
                case 2: context = .returning
                case 3: context = .withGuests
                default: context = nil
                }
            }

            // The first few seats arrive already answered; later ones wait
            // for the person trying the app.
            let count = max(0, 4 - index)
            let reactions = reactors
                .filter { $0.id != seat.id }
                .prefix(count)
                .enumerated()
                .map { offset, member in
                    LineupThoughtReaction(
                        userID: member.userId!,
                        name: member.name,
                        emoji: offset == 0 ? (context?.emoji ?? emoji[0]) : emoji[(offset + index) % emoji.count]
                    )
                }
            result[seat.id] = SeatReactions(participantID: seat.id, context: context, reactions: Array(reactions))
        }
        return result
    }
}
#endif
