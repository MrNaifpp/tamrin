//
//  HomeStore+LineupTalk.swift
//  Sirr
//
//  The lineup's thoughts, reactions, replies and verdicts. A fixture or preview
//  exercise answers locally with the same shape the RPC returns, so the whole
//  experience can be tried without a backend.
//

import Foundation

extension HomeStore {
    func lineupTalk(for occurrence: FeedOccurrence) -> LineupTalk? {
        lineupTalkByEvent[occurrence.id]
    }

    /// Each thought keyed by the lineup slot it belongs to. The pitch knows
    /// players by their seat (a participant id) and a thought belongs to an
    /// account, so the roster joins the two.
    func lineupThoughtsBySeat(for occurrence: FeedOccurrence) -> [UUID: LineupThought] {
        guard let talk = lineupTalkByEvent[occurrence.id], talk.isOpen else { return [:] }
        var byAccount: [UUID: LineupThought] = [:]
        for thought in talk.thoughts { byAccount[thought.userID] = thought }
        var bySeat: [UUID: LineupThought] = [:]
        for member in roster(for: occurrence) {
            if let userID = member.userId, let thought = byAccount[userID] {
                bySeat[member.id] = thought
            }
        }
        return bySeat
    }

    /// Whether the signed-in person may write: the organizer, or a seat holder.
    func canJoinLineupTalk(for occurrence: FeedOccurrence) -> Bool {
        guard let uid = currentUserID else { return false }
        return isOwner(of: occurrence)
            || roster(for: occurrence).contains { $0.userId == uid && $0.status != .waitlisted }
    }

    func loadLineupTalk(for occurrence: FeedOccurrence) async {
        if usesLocalLineupTalk(for: occurrence.id) {
            #if DEBUG
            if lineupTalkByEvent[occurrence.id] == nil {
                lineupTalkByEvent[occurrence.id] = HomeDebugMemberFixture.lineupTalk(
                    roster: roster(for: occurrence),
                    excluding: currentUserID,
                    endsAt: occurrence.endAt ?? occurrence.startAt
                )
            }
            #endif
            return
        }
        do {
            lineupTalkByEvent[occurrence.id] = try await LineupTalkService.shared.get(eventID: occurrence.id)
        } catch {
            // Keep what is showing; the next open tries again.
        }
    }

    /// Nil on success, or what to tell the person.
    func setLineupThought(_ body: String?, for occurrence: FeedOccurrence) async -> String? {
        let text = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return await mutateLineupTalk(occurrence) { talk, me, myName in
            if text.isEmpty {
                talk.thoughts.removeAll { $0.userID == me }
            } else if let index = talk.thoughts.firstIndex(where: { $0.userID == me }) {
                guard talk.thoughts[index].body != text else { return }
                // A new text is a new thought; what answered the old one goes.
                talk.thoughts[index].body = text
                talk.thoughts[index].updatedAt = .now
                talk.thoughts[index].reactions = []
                talk.thoughts[index].replies = []
                talk.thoughts.insert(talk.thoughts.remove(at: index), at: 0)
            } else {
                talk.thoughts.insert(LineupThought(
                    userID: me, name: myName, body: text, updatedAt: .now,
                    reactions: [], replies: []
                ), at: 0)
            }
        } remote: {
            try await LineupTalkService.shared.setThought(text.isEmpty ? nil : text, eventID: occurrence.id)
        }
    }

    func reactToLineupThought(_ emoji: String?, authorID: UUID, for occurrence: FeedOccurrence) async -> String? {
        await mutateLineupTalk(occurrence) { talk, me, myName in
            guard let index = talk.thoughts.firstIndex(where: { $0.userID == authorID }) else { return }
            talk.thoughts[index].reactions.removeAll { $0.userID == me }
            if let emoji {
                talk.thoughts[index].reactions.append(
                    LineupThoughtReaction(userID: me, name: myName, emoji: emoji)
                )
            }
        } remote: {
            try await LineupTalkService.shared.react(emoji, to: authorID, eventID: occurrence.id)
        }
    }

    func replyToLineupThought(_ body: String, authorID: UUID, for occurrence: FeedOccurrence) async -> String? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return await mutateLineupTalk(occurrence) { talk, me, myName in
            guard let index = talk.thoughts.firstIndex(where: { $0.userID == authorID }) else { return }
            talk.thoughts[index].replies.append(LineupThoughtReply(
                id: UUID(), userID: me, name: myName, body: text, createdAt: .now
            ))
        } remote: {
            try await LineupTalkService.shared.reply(text, to: authorID, eventID: occurrence.id)
        }
    }

    func deleteLineupReply(_ replyID: UUID, for occurrence: FeedOccurrence) async -> String? {
        await mutateLineupTalk(occurrence) { talk, _, _ in
            for index in talk.thoughts.indices {
                talk.thoughts[index].replies.removeAll { $0.id == replyID }
            }
        } remote: {
            try await LineupTalkService.shared.deleteReply(replyID)
        }
    }

    func setLineupVerdict(_ verdict: LineupVerdict?, for occurrence: FeedOccurrence) async -> String? {
        await mutateLineupTalk(occurrence) { talk, _, _ in
            if let previous = talk.myVerdict {
                talk.verdicts[previous] = max((talk.verdicts[previous] ?? 0) - 1, 0)
            }
            if let verdict { talk.verdicts[verdict, default: 0] += 1 }
            talk.myVerdict = verdict
        } remote: {
            try await LineupTalkService.shared.setVerdict(verdict, eventID: occurrence.id)
        }
    }

    /// Applies the change at once, so a reaction lands under the finger, then
    /// takes the server's whole answer. A refusal puts back what was there.
    private func mutateLineupTalk(
        _ occurrence: FeedOccurrence,
        local: (inout LineupTalk, UUID, String) -> Void,
        remote: () async throws -> LineupTalk?
    ) async -> String? {
        guard let me = currentUserID, var talk = lineupTalkByEvent[occurrence.id] else {
            return String(localized: "تعذر إكمال العملية. حاول مرة أخرى.")
        }
        guard talk.isOpen else { return String(localized: "انتهت خواطر هذا التمرين.") }
        let before = talk
        let myName = profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "أنت") : profileName
        local(&talk, me, myName)
        lineupTalkByEvent[occurrence.id] = talk
        guard !usesLocalLineupTalk(for: occurrence.id) else { return nil }
        do {
            if let fresh = try await remote() { lineupTalkByEvent[occurrence.id] = fresh }
            return nil
        } catch {
            lineupTalkByEvent[occurrence.id] = before
            return ServerErrorMessage.arabic(for: error)
        }
    }
}
