#if DEBUG
import Foundation

extension HomeDebugMemberFixture {
    /// A conversation already under way on a fixture lineup: three thoughts,
    /// reactions from the others, one reply, and a split of verdicts with a
    /// clear lead, so the organizer's summary has something to say.
    static func lineupTalk(roster: [FeedMember], excluding me: UUID?, endsAt: Date) -> LineupTalk {
        let others = roster.filter { $0.userId != nil && $0.userId != me && $0.status != .waitlisted }
        let lines = ["فريقنا أقوى 😤", "أبي أكون حارس اليوم 🧤", "الدفاع عندنا جدار 🧱"]
        let emoji = ["🔥", "😂", "💪", "👍"]

        var thoughts: [LineupThought] = []
        for (index, line) in lines.enumerated() where index < others.count {
            let author = others[index]
            let reactors = others.enumerated()
                .filter { $0.offset != index }
                .prefix(3 - index)
                .map { offset, member in
                    LineupThoughtReaction(
                        userID: member.userId!,
                        name: member.name,
                        emoji: emoji[(offset + index) % emoji.count]
                    )
                }
            var replies: [LineupThoughtReply] = []
            if index == 0, others.count > 1 {
                replies.append(LineupThoughtReply(
                    id: UUID(),
                    userID: others[1].userId!,
                    name: others[1].name,
                    body: "نشوف في الملعب 😏",
                    createdAt: .now.addingTimeInterval(-600)
                ))
            }
            thoughts.append(LineupThought(
                userID: author.userId!,
                name: author.name,
                body: line,
                updatedAt: .now.addingTimeInterval(TimeInterval(-1800 * (index + 1))),
                reactions: Array(reactors),
                replies: replies
            ))
        }

        return LineupTalk(
            isOpen: Date.now < endsAt.addingTimeInterval(24 * 60 * 60),
            thoughts: thoughts,
            verdicts: [.balanced: 5, .fire: 2, .unfair: 1],
            myVerdict: nil
        )
    }
}
#endif
