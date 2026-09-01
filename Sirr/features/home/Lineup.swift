//
//  Lineup.swift
//  Sirr
//
//  «التشكيلة»: the organizer splits the people who booked a seat into two
//  sides. The rules are the ones the team-builder site settled on — group by
//  position, hand each next player to the side that needs him most, then trade
//  players until the two levels meet — with the app's own four positions and
//  its 0…100 Overall in place of the site's three positions and five stars.
//

import SwiftUI

// MARK: - Player

/// One candidate as the split sees him: who he is, where he plays, and how
/// strong the group rates him.
///
/// Deliberately not `FeedMember`: a lineup only ever needs these four things,
/// and keeping it separate means the balancer can be reasoned about (and
/// previewed) without a roster, a store, or a network behind it.
struct LineupPlayer: Identifiable, Equatable {
    /// The roster row's id — the same id the saved plan stores.
    let id: UUID
    let name: String
    var avatarUrl: String?
    /// Nil is carried only by sports that do not use football positions.
    /// Football candidates are normalized to midfield before they reach the
    /// lineup, and `row` keeps that fallback as a final safety boundary.
    var position: PlayerPosition?
    /// True when this is the organizer's choice for tonight rather than the
    /// position on the player's own profile.
    var isPositionOverridden = false
    /// The crowd's Overall, 0…100. `LineupStrength.neutral` when nobody has
    /// rated him yet, so an unrated player neither drags a side down nor
    /// carries it.
    var strength: Int

    /// The small line above the bold one on the pitch. A single-word name has
    /// no first/family split, so it is drawn whole and this stays empty.
    var firstName: String {
        let parts = nameParts
        return parts.count > 1 ? parts[0] : ""
    }

    /// What the pitch shows in bold: the family name when there is one, and
    /// otherwise the single name he goes by.
    var displayName: String {
        nameParts.last ?? name
    }

    private var nameParts: [String] {
        name.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Which band of the pitch he is drawn in.
    var row: LineupRow { LineupRow(position) }
}

enum LineupStrength {
    /// Where an unrated player sits: exactly the midpoint the rating flow
    /// itself starts every attribute on.
    static let neutral = 50
}

// MARK: - Rows

/// The bands of the half-pitch, in the order they are drawn — the opponent's
/// goal is off the top edge, ours is at the bottom.
enum LineupRow: Int, CaseIterable, Identifiable {
    case forward
    case midfield
    case defense
    case goalkeeper

    init(_ position: PlayerPosition?) {
        switch position {
        case .forward: self = .forward
        case .midfielder: self = .midfield
        case .defender: self = .defense
        case .goalkeeper: self = .goalkeeper
        case nil: self = .midfield
        }
    }

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .forward: return "هجوم"
        case .midfield: return "وسط"
        case .defense: return "دفاع"
        case .goalkeeper: return "حارس"
        }
    }

    /// The position that puts a player in this band — the inverse of
    /// `init(_ position:)`, which is what a drop between bands writes back.
    var position: PlayerPosition {
        switch self {
        case .forward: return .forward
        case .midfield: return .midfielder
        case .defense: return .defender
        case .goalkeeper: return .goalkeeper
        }
    }

    /// The dot's colour. The four positions borrow the palette the rating card
    /// already taught the group.
    var tint: Color {
        switch self {
        case .forward: return PlayerPosition.forward.tint
        case .midfield: return PlayerPosition.midfielder.tint
        case .defense: return PlayerPosition.defender.tint
        case .goalkeeper: return PlayerPosition.goalkeeper.tint
        }
    }
}

// MARK: - Sides

enum LineupSide: String, Codable, CaseIterable, Identifiable {
    case first
    case second

    var id: String { rawValue }

    var title: String {
        switch self {
        case .first: return "الفريق الأول"
        case .second: return "الفريق الثاني"
        }
    }

    /// The accent each side is known by — the two colours the design gives the
    /// team cards. Used as a marker beside the name, not as a fill: the cards
    /// themselves stay on the app's dark glass.
    var tint: Color {
        switch self {
        case .first: return Color(red: 0.91, green: 0.36, blue: 0.24)
        case .second: return Color(red: 0.96, green: 0.78, blue: 0.25)
        }
    }

    var other: LineupSide { self == .first ? .second : .first }
}

// MARK: - Teams

/// The two sides, and everything the review screen reads off them.
struct LineupTeams: Equatable {
    var first: [LineupPlayer]
    var second: [LineupPlayer]

    init(first: [LineupPlayer] = [], second: [LineupPlayer] = []) {
        self.first = first
        self.second = second
    }

    subscript(side: LineupSide) -> [LineupPlayer] {
        get { side == .first ? first : second }
        set { if side == .first { first = newValue } else { second = newValue } }
    }

    var allPlayers: [LineupPlayer] { first + second }

    /// Whether `place` would actually change anything. The pitch now commits a
    /// move the moment it is decided rather than on release, so this runs many
    /// times a second — and re-writing the same arrangement would restart the
    /// animation on every frame of the drag.
    func needsMove(_ playerID: UUID, inRow row: LineupRow, at index: Int) -> Bool {
        guard let side = side(of: playerID) else { return false }
        let band = self[side].filter { $0.row == row }
        let current = band.firstIndex { $0.id == playerID }
        return current != min(max(index, 0), max(band.count - 1, 0))
    }

    /// Puts `playerID` at `index` among the players of `row` on his own side.
    ///
    /// A band has no order of its own — it is `players.filter { $0.row == row }`
    /// — so placing someone within it means placing him in the side's array
    /// relative to the others in that band. Dropping into a different band is
    /// the same move; what changes the band is the position written alongside.
    mutating func place(_ playerID: UUID, inRow row: LineupRow, at index: Int) {
        guard let side = side(of: playerID) else { return }
        var roster = self[side]
        guard let from = roster.firstIndex(where: { $0.id == playerID }) else { return }
        let player = roster.remove(at: from)

        let band = roster.enumerated().filter { $0.element.row == row }
        let target = min(max(index, 0), band.count)
        // Past the end of the band, he goes directly after its last player, so
        // he stays inside it rather than in front of whatever follows.
        let insertion = target < band.count
            ? band[target].offset
            : (band.last.map { $0.offset + 1 } ?? roster.count)
        roster.insert(player, at: min(insertion, roster.count))
        self[side] = roster
    }

    func side(of playerID: UUID) -> LineupSide? {
        if first.contains(where: { $0.id == playerID }) { return .first }
        if second.contains(where: { $0.id == playerID }) { return .second }
        return nil
    }

    /// The one number the organizer watches: how far apart the two levels are.
    var strengthGap: Int {
        abs(LineupStats(players: first).totalStrength - LineupStats(players: second).totalStrength)
    }

    /// Trades two players between the sides. Ignored unless they really are on
    /// opposite sides, so a double tap on the same card cannot corrupt the plan.
    mutating func swap(_ playerID: UUID, with otherID: UUID) {
        guard
            let sideA = side(of: playerID),
            let sideB = side(of: otherID),
            sideA != sideB,
            let indexA = self[sideA].firstIndex(where: { $0.id == playerID }),
            let indexB = self[sideB].firstIndex(where: { $0.id == otherID })
        else { return }

        let playerA = self[sideA][indexA]
        self[sideA][indexA] = self[sideB][indexB]
        self[sideB][indexB] = playerA
    }

    /// Puts one player in another position, wherever he is standing.
    mutating func setPosition(
        _ position: PlayerPosition,
        overridden: Bool,
        for playerID: UUID
    ) {
        for side in LineupSide.allCases {
            guard let index = self[side].firstIndex(where: { $0.id == playerID }) else { continue }
            self[side][index].position = position
            self[side][index].isPositionOverridden = overridden
        }
    }

    /// Moves one player across on his own, which is the only edit that can
    /// leave the sides uneven — the organizer sometimes wants exactly that.
    mutating func move(_ playerID: UUID) {
        guard
            let from = side(of: playerID),
            let index = self[from].firstIndex(where: { $0.id == playerID })
        else { return }

        let player = self[from].remove(at: index)
        self[from.other].append(player)
    }
}

/// What one side adds up to.
struct LineupStats {
    let count: Int
    let totalStrength: Int
    /// How many of each band, for the line under the team's name.
    let countsByRow: [LineupRow: Int]

    init(players: [LineupPlayer]) {
        count = players.count
        totalStrength = players.reduce(0) { $0 + $1.strength }
        countsByRow = players.reduce(into: [:]) { result, player in
            result[player.row, default: 0] += 1
        }
    }

    /// Rounded the way the rest of the app rounds a mean of integers.
    var averageStrength: Int {
        guard count > 0 else { return 0 }
        return ((2 * totalStrength) + count) / (2 * count)
    }

    func count(of row: LineupRow) -> Int { countsByRow[row] ?? 0 }
}

// MARK: - Balancer

/// Builds two sides: football is balanced by position and level, while sports
/// without either concept use an even random deal.
enum LineupBalancer {
    /// Positions are filled from the back, because the scarce ones decide the
    /// shape of the split: there is rarely more than one keeper, and a side
    /// left without a defender cannot be fixed by a later trade of forwards.
    private static let fillOrder: [LineupRow] = [
        .goalkeeper, .defense, .midfield, .forward
    ]

    /// A gap this small is noise — the Overall itself is a rounded average —
    /// so the optimiser stops rather than trading players to chase it.
    private static let acceptableGap = 2
    private static let maxIterations = 100

    static func split(_ players: [LineupPlayer]) -> LineupTeams {
        var teams = LineupTeams()

        for row in fillOrder {
            let group = players
                .filter { $0.row == row }
                .sorted { levelDescending($0, $1) }

            for player in group {
                teams[preferredSide(for: row, in: teams)].append(player)
            }
        }

        optimise(&teams)

        for side in LineupSide.allCases {
            teams[side].sort { positionAscending($0, $1) }
        }
        return teams
    }

    /// Splits sports that have neither player positions nor ratings.
    ///
    /// The roster is shuffled exactly once, then dealt alternately between the
    /// two sides. Alternating preserves the shuffled order inside each team and
    /// guarantees their sizes differ by no more than one without smuggling a
    /// football position or strength back into the decision.
    static func randomSplit(_ players: [LineupPlayer]) -> LineupTeams {
        let shuffled = players.shuffled()
        var teams = LineupTeams()

        for (index, player) in shuffled.enumerated() {
            teams[index.isMultiple(of: 2) ? .first : .second].append(player)
        }
        return teams
    }

    /// Where the next player of this band goes. The order of the three tests
    /// is the whole rule: shape first, then size, then level.
    ///
    /// Size is tested before level — the site's version compared only the band
    /// and the level, which let every band start on the same side and hand it
    /// four extra players over a full roster.
    private static func preferredSide(for row: LineupRow, in teams: LineupTeams) -> LineupSide {
        let firstStats = LineupStats(players: teams.first)
        let secondStats = LineupStats(players: teams.second)

        if firstStats.count(of: row) != secondStats.count(of: row) {
            return firstStats.count(of: row) < secondStats.count(of: row) ? .first : .second
        }
        if firstStats.count != secondStats.count {
            return firstStats.count < secondStats.count ? .first : .second
        }
        return firstStats.totalStrength <= secondStats.totalStrength ? .first : .second
    }

    /// Trades players until the two levels meet. Every trade is one-for-one, so
    /// the sizes settled above are never disturbed.
    private static func optimise(_ teams: inout LineupTeams) {
        for _ in 0..<maxIterations {
            let gap = teams.strengthGap
            if gap <= acceptableGap { return }

            var bestGap = gap
            var bestTrade: (UUID, UUID)?
            let signedGap = LineupStats(players: teams.first).totalStrength
                - LineupStats(players: teams.second).totalStrength

            for playerA in teams.first {
                for playerB in teams.second {
                    // The gap moves by twice the difference between the two:
                    // one leaves a side exactly as the other arrives.
                    let newGap = abs(signedGap - 2 * (playerA.strength - playerB.strength))

                    guard newGap < bestGap else { continue }
                    guard playerA.row == playerB.row || keepsShape(teams, playerA, playerB) else {
                        continue
                    }

                    bestGap = newGap
                    bestTrade = (playerA.id, playerB.id)
                }
            }

            guard let bestTrade else { return }
            teams.swap(bestTrade.0, with: bestTrade.1)
        }
    }

    /// True when trading these two across bands leaves every band no more
    /// lopsided than it already was.
    private static func keepsShape(
        _ teams: LineupTeams,
        _ playerA: LineupPlayer,
        _ playerB: LineupPlayer
    ) -> Bool {
        let firstStats = LineupStats(players: teams.first)
        let secondStats = LineupStats(players: teams.second)

        for row in LineupRow.allCases {
            var inFirst = firstStats.count(of: row)
            var inSecond = secondStats.count(of: row)
            let before = abs(inFirst - inSecond)

            if playerA.row == row { inFirst -= 1; inSecond += 1 }
            if playerB.row == row { inSecond -= 1; inFirst += 1 }

            if abs(inFirst - inSecond) > before { return false }
        }
        return true
    }

    /// Strongest first, and by name when two players rate the same, so the
    /// same roster always splits the same way.
    private static func levelDescending(_ lhs: LineupPlayer, _ rhs: LineupPlayer) -> Bool {
        if lhs.strength != rhs.strength { return lhs.strength > rhs.strength }
        return lhs.name.localizedCompare(rhs.name) == .orderedAscending
    }

    /// Back to front, the way a squad list is read.
    private static func positionAscending(_ lhs: LineupPlayer, _ rhs: LineupPlayer) -> Bool {
        if lhs.row != rhs.row { return lhs.row.rawValue > rhs.row.rawValue }
        return lhs.strength > rhs.strength
    }
}

// MARK: - Per-exercise positions

/// Where the organizer put a player *for this exercise*.
///
/// A player's profile says where he plays in general; on the night, the
/// organizer moves people around — a midfielder goes in goal because nobody
/// else will, a defender is pushed up front. That decision belongs to the one
/// exercise and must not touch the profile, which is also what the rating's
/// Overall is weighted by: overriding a position here changes where he is
/// drawn and how the sides are balanced by shape, and nothing else.
struct LineupPositions: Codable, Equatable {
    /// Row id → the organizer's explicit position for this occurrence.
    private var byPlayer: [String: String] = [:]

    init(byPlayer: [String: String] = [:]) {
        self.byPlayer = byPlayer
    }

    /// What the server stores. Only LineupStore should need this.
    var rawValues: [String: String] { byPlayer }

    var isEmpty: Bool { byPlayer.isEmpty }

    func has(_ playerID: UUID) -> Bool { byPlayer[playerID.uuidString] != nil }

    /// Missing and legacy invalid values resolve differently: a missing key
    /// means there is no override, while a saved empty/unknown value came from
    /// the removed «غير محدد» state and is migrated to midfield.
    func position(for playerID: UUID) -> PlayerPosition? {
        guard let raw = byPlayer[playerID.uuidString] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlayerPosition(rawValue: trimmed) ?? .midfielder
    }

    mutating func set(_ position: PlayerPosition, for playerID: UUID) {
        byPlayer[playerID.uuidString] = position.rawValue
    }

    /// Canonicalizes values written by builds that offered «غير محدد». This
    /// keeps old local lineups from reviving a fifth state after the UI is gone.
    @discardableResult
    mutating func normalizeLegacyValues() -> Bool {
        var changed = false
        for (playerID, raw) in byPlayer {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = PlayerPosition(rawValue: trimmed) ?? .midfielder
            guard raw != resolved.rawValue else { continue }
            byPlayer[playerID] = resolved.rawValue
            changed = true
        }
        return changed
    }

    /// Hands the player back to whatever his profile says.
    mutating func clear(_ playerID: UUID) {
        byPlayer.removeValue(forKey: playerID.uuidString)
    }
}

// MARK: - Saved plan

/// What survives the screen closing: who was on which side, and when it was
/// last decided. Only the roster-row ids are stored — names, positions and
/// ratings are read fresh from the roster every time it is drawn, so a player
/// who changed his position does not carry a stale one into the next exercise.
struct LineupPlan: Codable, Equatable {
    var first: [UUID]
    var second: [UUID]
    var updatedAt: Date

    init(teams: LineupTeams, updatedAt: Date = .now) {
        first = teams.first.map(\.id)
        second = teams.second.map(\.id)
        self.updatedAt = updatedAt
    }

    init(first: [UUID], second: [UUID], updatedAt: Date = .now) {
        self.first = first
        self.second = second
        self.updatedAt = updatedAt
    }

    /// Rebuilds the two sides from the current roster. Players who left the
    /// exercise fall out; anyone who registered after the split was saved is
    /// returned separately so the organizer can be told about him rather than
    /// finding him silently missing.
    func resolve(against candidates: [LineupPlayer]) -> (teams: LineupTeams, unplaced: [LineupPlayer]) {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let teams = LineupTeams(
            first: first.compactMap { byID[$0] },
            second: second.compactMap { byID[$0] }
        )
        let placed = Set(first + second)
        return (teams, candidates.filter { !placed.contains($0.id) })
    }
}

/// Where a saved split lives: the group's database, through LineupService.
///
/// A read-through cache sits in front of it for one reason. `lineupCandidates`
/// is synchronous and is called while the pitch is being drawn, which is no
/// place to await a request; it reads `positions(for:)` off the cache instead.
/// Every screen that shows a lineup calls `load` before drawing one, so by the
/// time a candidate list is built the cache is warm. A cold read returns no
/// overrides, which is exactly what an exercise with no saved split looks like.
///
/// Writes go to the cache first and to the server behind them. The organizer
/// dragging a player sees the pitch move at once, and a failed write leaves the
/// screen right and the row stale rather than the other way round.
///
/// The debug fixture exercises exist on no server at all. They work here
/// because the cache answers for them and the write that follows simply fails.
@MainActor
enum LineupStore {
    private static var plans: [UUID: LineupPlan] = [:]
    private static var positionsByEvent: [UUID: LineupPositions] = [:]
    private static var published: Set<UUID> = []

    /// The overrides this exercise carries, as far as the last load knows.
    static func positions(for eventID: UUID) -> LineupPositions {
        positionsByEvent[eventID] ?? LineupPositions()
    }

    static func isPublished(eventID: UUID) -> Bool { published.contains(eventID) }

    /// Reads the split from the server and warms the cache. Nil means there is
    /// no lineup to show: either none was saved, or one exists as a draft that
    /// this reader is not entitled to yet.
    @discardableResult
    static func load(eventID: UUID) async -> LineupPlan? {
        let fetched: LineupRecord?
        do {
            fetched = try await LineupService.shared.get(eventID: eventID)
        } catch {
            // A failed read must not empty a split the screen is already
            // showing. Keep what is cached and let the next load correct it.
            return plans[eventID]
        }
        guard let record = fetched else {
            plans[eventID] = nil
            positionsByEvent[eventID] = nil
            published.remove(eventID)
            return nil
        }

        var positions = LineupPositions(byPlayer: record.positions)
        // Values written by a build that offered «غير محدد» are canonicalized
        // on the way in, the same as they were when this read from the device.
        positions.normalizeLegacyValues()
        positionsByEvent[eventID] = positions

        let plan = LineupPlan(first: record.first, second: record.second)
        plans[eventID] = plan
        if record.isPublished { published.insert(eventID) } else { published.remove(eventID) }
        return plan
    }

    /// The cached split, without going to the server. For a screen that has
    /// already loaded one and is redrawing.
    static func cached(eventID: UUID) -> LineupPlan? { plans[eventID] }

    static func save(_ plan: LineupPlan, positions: LineupPositions, eventID: UUID) {
        plans[eventID] = plan
        positionsByEvent[eventID] = positions
        Task {
            _ = try? await LineupService.shared.save(
                eventID: eventID,
                first: plan.first,
                second: plan.second,
                positions: positions.rawValues
            )
        }
    }

    /// Saves the positions against the split already held. Called when the
    /// organizer changes one player's position without moving anybody.
    static func savePositions(_ positions: LineupPositions, eventID: UUID) {
        positionsByEvent[eventID] = positions
        guard let plan = plans[eventID] else { return }
        save(plan, positions: positions, eventID: eventID)
    }

    /// Hands the split to everyone holding a seat.
    static func publish(eventID: UUID) async {
        published.insert(eventID)
        _ = try? await LineupService.shared.publish(eventID: eventID)
    }

    static func clear(eventID: UUID) {
        plans[eventID] = nil
        positionsByEvent[eventID] = nil
        published.remove(eventID)
    }
}

// MARK: - Roster → candidates

extension HomeStore {
    /// The people a split can draw on: everyone holding a seat. The reserve
    /// list is left out — someone waiting for a seat is not in the exercise
    /// yet, which is the same line the roster itself draws. Football reads the
    /// player's profile position and this exercise's override; other sports
    /// deliberately carry neither, so a stale football choice cannot affect
    /// their split or their court layout.
    func lineupCandidates(
        for occurrence: FeedOccurrence,
        usesFootballPositions: Bool = true
    ) -> [LineupPlayer] {
        let positions = usesFootballPositions
            ? LineupStore.positions(for: occurrence.id)
            : LineupPositions()

        return roster(for: occurrence)
            .filter { $0.status != .waitlisted }
            .map { member in
                let position: PlayerPosition?
                let isPositionOverridden: Bool

                if usesFootballPositions {
                    // The organizer's choice for tonight wins over the profile.
                    position = positions.position(for: member.id)
                        ?? PlayerPosition.exact(from: member.position)
                        ?? .midfielder
                    isPositionOverridden = positions.has(member.id)
                } else {
                    position = nil
                    isPositionOverridden = false
                }

                return LineupPlayer(
                    id: member.id,
                    name: member.name,
                    avatarUrl: member.avatarUrl,
                    position: position,
                    isPositionOverridden: isPositionOverridden,
                    strength: LineupStrength.neutral
                )
            }
    }

    /// The crowd's Overall for each of these players, read in parallel because
    /// the rating RPC answers for one player at a time and a full exercise is
    /// sixteen of them. A player nobody has rated — and every guest, who has no
    /// account to rate — is simply absent from the result and keeps the neutral
    /// level the balancer gave him.
    func lineupStrengths(for occurrence: FeedOccurrence) async -> [UUID: Int] {
        let members = roster(for: occurrence).filter { $0.status != .waitlisted && $0.userId != nil }

        return await withTaskGroup(of: (UUID, Int?).self) { group in
            for member in members {
                group.addTask { @MainActor in
                    let summary = try? await self.playerRating(for: member)
                    return (member.id, summary?.averageOverall)
                }
            }

            var result: [UUID: Int] = [:]
            for await (id, overall) in group {
                if let overall { result[id] = overall }
            }
            return result
        }
    }
}

// MARK: - Zoom source

/// Which card the lineup page grows out of.
///
/// `Identifiable` because it is what drives the presentation itself. Holding it
/// in a separate `@State` beside a boolean does not work: the cover reads the
/// source id from the render *before* the one that opened it, so every press
/// zoomed from whichever card was pressed last — and from nothing at all the
/// first time, which UIKit answers with a plain slide.
enum LineupZoomSource: Hashable, Identifiable {
    /// One of the two team cards.
    case card(LineupSide)
    /// The row that stands in for them before there is a lineup at all.
    case entry

    var id: String {
        switch self {
        case .card(let side): return "card.\(side.rawValue)"
        case .entry: return "entry"
        }
    }
}
