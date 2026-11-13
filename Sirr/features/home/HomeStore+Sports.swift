import Foundation

/// The sports on my profile and my position in each.
///
/// Football is always there: its position has lived on the profile from the
/// start, in `playerPosition`. Another sport appears once I am in a group that
/// plays it, or once I add it myself from the profile.
extension HomeStore {
    /// The sport the selected group is rated in. Nil for a sport without
    /// positions or ratings.
    var currentRatingSport: RatingSport {
        RatingSport(sport: currentTeam?.sport) ?? .football
    }

    /// The sports my profile shows, football first.
    var profileSports: [RatingSport] {
        let fromGroups = Set(teams.compactMap { RatingSport(sport: $0.sport) })
        let added = Set(mySports.compactMap { RatingSport(sport: $0.sport) })
        return RatingSport.allCases.filter { $0 == .football || fromGroups.contains($0) || added.contains($0) }
    }

    /// Sports that can still be added from the profile.
    var addableSports: [RatingSport] {
        RatingSport.allCases.filter { !profileSports.contains($0) }
    }

    /// True for a sport I play because a group plays it; those cannot be
    /// taken off the profile while I am in the group.
    func playsThroughGroup(_ sport: RatingSport) -> Bool {
        sport == .football || teams.contains { RatingSport(sport: $0.sport) == sport }
    }

    func position(in sport: RatingSport) -> String? {
        if sport == .football { return playerPosition.isEmpty ? nil : playerPosition }
        return mySports.first { $0.sport == sport.rawValue }?.position
    }

    /// Football goes through `saveProfile`, which already writes the position;
    /// the others are saved here. Optimistic, like the rest of the profile.
    func saveSportPosition(_ sport: RatingSport, position: String?) {
        guard sport != .football else { return }
        applyLocally(sport, position: position)
        guard !isDebugSportsFixture else { return }
        Task {
            if let sports = try? await RatingService.shared.setMySport(sport, position: position) {
                mySports = sports
            }
        }
    }

    func addSport(_ sport: RatingSport) {
        saveSportPosition(sport, position: nil)
    }

    func removeSport(_ sport: RatingSport) {
        guard !playsThroughGroup(sport) else { return }
        mySports.removeAll { $0.sport == sport.rawValue }
        guard !isDebugSportsFixture else { return }
        Task {
            if let sports = try? await RatingService.shared.removeMySport(sport) { mySports = sports }
        }
    }

    private func applyLocally(_ sport: RatingSport, position: String?) {
        if let index = mySports.firstIndex(where: { $0.sport == sport.rawValue }) {
            if let position { mySports[index].position = position }
        } else {
            mySports.append(MySport(sport: sport.rawValue, position: position))
        }
    }

    /// The member fixture has no account behind it; my sports stay in memory.
    private var isDebugSportsFixture: Bool {
        #if DEBUG
        return HomeDebugMemberFixture.isEnabled
        #else
        return false
        #endif
    }
}
