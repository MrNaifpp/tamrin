//
//  LineupPitchView.swift
//  Sirr
//
//  How a side is drawn: a half-pitch seen from behind our own goal, the bands
//  stacked from the opponent's half at the top down to the keeper in the box.
//  A player is a coloured dot with his first name small above his family name,
//  which is how the group already reads a squad sheet.
//

import SwiftUI

/// The part of a lineup that changes with the exercise's sport.
///
/// Football is deliberately the only style that understands ratings and
/// positions. Volleyball and the temporary generic treatment draw the roster
/// without interpreting a player's football profile position.
enum LineupSportStyle: Equatable {
    case football
    case volleyball
    case generic

    init(symbol: String?) {
        switch symbol {
        case "figure.soccer": self = .football
        case "figure.volleyball": self = .volleyball
        default: self = .generic
        }
    }

    var usesFootballFeatures: Bool { self == .football }
}

// MARK: - Pitch

/// One place along a band: a player standing in it, or the space held open for
/// the one being carried in.
private enum LineupPitchSlot: Identifiable {
    case player(LineupPlayer)
    case gap

    var id: String {
        switch self {
        case .player(let player): return player.id.uuidString
        case .gap: return "gap"
        }
    }

    var player: LineupPlayer? {
        if case .player(let player) = self { return player }
        return nil
    }
}

/// Where a dragged player would land: which band, and how far along it.
private struct LineupDropSlot: Equatable {
    var row: LineupRow
    var index: Int
}

/// One drawn player's slot, measured in the pitch's own space.
private struct LineupNodeFrame: Equatable {
    let id: UUID
    let row: LineupRow
    /// Position within its band, so the frames can be read back in the order
    /// they were laid out rather than in whatever order the preference
    /// collected them.
    let order: Int
    let frame: CGRect
}

private struct LineupNodeFramesKey: PreferenceKey {
    static let defaultValue: [LineupNodeFrame] = []
    static func reduce(value: inout [LineupNodeFrame], nextValue: () -> [LineupNodeFrame]) {
        value.append(contentsOf: nextValue())
    }
}

private struct LineupRowFrame: Equatable {
    let row: LineupRow
    let frame: CGRect
}

private struct LineupRowFramesKey: PreferenceKey {
    static let defaultValue: [LineupRowFrame] = []
    static func reduce(value: inout [LineupRowFrame], nextValue: () -> [LineupRowFrame]) {
        value.append(contentsOf: nextValue())
    }
}

struct LineupPitchView: View {
    let players: [LineupPlayer]
    /// The editor shows both teams together. Its narrower pitches use the same
    /// interaction model with tighter, still tappable typography and spacing.
    var compact = false
    var pitchHeight: CGFloat = 288
    var sportStyle: LineupSportStyle = .football
    /// Non-position sports use one colour for everyone on this side. The team
    /// card supplies its own accent; the neutral default keeps direct callers
    /// honest when no side is known.
    var teamTint: Color = Color(white: 0.62)
    /// The player waiting for someone to trade with, if any. Drawn with a ring
    /// so the half-finished action is visible from either card.
    var selectedID: UUID?
    /// Nil on the read-only card shown inside the exercise page.
    var onSelect: ((LineupPlayer) -> Void)?
    var onMove: ((LineupPlayer) -> Void)?
    /// Commits a drag: this player, into this band, at this place along it.
    /// Nil leaves the pitch read-only.
    var onReorder: ((UUID, LineupRow, Int) -> Void)?
    /// Raised while a player is in hand, so the page around the pitch can stop
    /// scrolling. Without it the scroll view claims the vertical part of the
    /// drag and cancels this gesture — see `reorderGesture`.
    var onDraggingChanged: ((Bool) -> Void)?

    /// Who was picked up. The full long-press-then-drag gesture belongs to the
    /// pitch, which never gets re-parented while the bands rearrange beneath
    /// the carried player. A plain pan fails the long press quickly and remains
    /// available to the enclosing `ScrollView`.
    @State private var draggingID: UUID?
    @State private var dragLocation: CGPoint?
    /// Where inside the player the finger first held him. Keeping this offset
    /// avoids the node snapping its centre underneath an off-centre touch.
    @State private var dragGrabOffset: CGSize = .zero
    @State private var dropSlot: LineupDropSlot?
    /// Frames as they were when the player was picked up. Drop decisions must
    /// be made against fixed goalposts: reading the animated frames makes the
    /// target move underneath the finger and can alternate forever between two
    /// players.
    @State private var dragNodeFrames: [LineupNodeFrame] = []
    @State private var dragRowFrames: [LineupRowFrame] = []
    /// Absolute SwiftUI layout positions are mirrored in an RTL hierarchy,
    /// while the gesture and measured frames use physical screen coordinates.
    /// The carried overlay accounts for that difference explicitly.
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var nodeFrames: [LineupNodeFrame] = []
    @State private var rowFrames: [LineupRowFrame] = []

    private static let space = "lineup.pitch"
    private static let slotHysteresis: CGFloat = 8

    /// Nil the moment the gesture lets go, however it ended. Everything that
    /// draws the in-flight pitch reads this, so nothing can outlive the drag.
    private var dragging: LineupPlayer? {
        guard let draggingID else { return nil }
        return players.first { $0.id == draggingID }
    }

    /// The pitch as it should look *right now* — which during a drag is not the
    /// pitch the model holds. Everyone steps aside for the player being carried
    /// in, so releasing him changes nothing that was not already on screen.
    ///
    /// The carried view never moves between these HStacks. Its source becomes
    /// a gap, its proposed destination gets that gap, and one overlay follows
    /// the hand. This keeps both view identity and gesture ownership stable.
    private var arrangedRows: [(row: LineupRow, slots: [LineupPitchSlot])] {
        var byRow: [LineupRow: [LineupPitchSlot]] = [:]
        for player in players {
            // The carried player is drawn once in an overlay. His ordinary
            // slot becomes the placeholder that keeps the row from collapsing
            // when the lift begins.
            let slot: LineupPitchSlot = player.id == dragging?.id ? .gap : .player(player)
            byRow[player.row, default: []].append(slot)
        }

        // Move only the placeholder while the finger travels. The underlying
        // teams stay untouched until release, so measuring this preview can
        // never feed back into the model and start a ping-pong reorder loop.
        if let dragging, let slot = dropSlot {
            if slot.row == dragging.row {
                var band = byRow[slot.row] ?? []
                if let from = band.firstIndex(where: { $0.player == nil }) {
                    band.remove(at: from)
                    band.insert(.gap, at: min(max(slot.index, 0), band.count))
                    byRow[slot.row] = band
                }
            } else {
                var band = byRow[slot.row] ?? []
                band.insert(.gap, at: min(max(slot.index, 0), band.count))
                byRow[slot.row] = band
            }
        }

        // Read-only cards show only occupied bands. The editor keeps every
        // position alive as a drop target, including a position that is empty
        // in this team right now; otherwise the organizer could never move the
        // first player into that position.
        //
        // Except while a drag is in flight, when the band the player just left
        // is held open even though it is empty. The bands share the pitch's
        // height between them, so letting one disappear re-sizes every other
        // one — under the finger, mid-drag. The band being aimed at slides out
        // from under it, the next reading lands back on the old one, and the
        // player chases himself between the two and is dropped where he began.
        // That is the "it will not take a new position" this fixes.
        let modelRows = Set(players.map(\.row))
        return LineupRow.allCases.compactMap { row in
            let band = byRow[row] ?? []
            let held = dragging != nil && modelRows.contains(row)
            let isEditableDropTarget = onReorder != nil
            guard !band.isEmpty || held || isEditableDropTarget else { return nil }
            return (row, band)
        }
    }

    @ViewBuilder
    var body: some View {
        switch sportStyle {
        case .football:
            footballPitch
        case .volleyball, .generic:
            rosterCourt
        }
    }

    /// Football keeps its position bands and its drag-to-change-position
    /// interaction exactly as before. Other sports never enter this branch,
    /// so they cannot accidentally write a football position.
    private var footballPitch: some View {
        // The bands share the height of the pitch rather than stacking to
        // whatever they happen to need, so the back line always stands in
        // front of its own box instead of on top of it.
        VStack(spacing: compact ? 6 : 10) {
            ForEach(arrangedRows, id: \.row) { entry in
                HStack(alignment: .center, spacing: compact ? 3 : 6) {
                    ForEach(Array(entry.slots.enumerated()), id: \.element.id) { order, slot in
                        if let player = slot.player {
                            node(for: player)
                                .frame(maxWidth: .infinity)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: LineupNodeFramesKey.self,
                                            value: [LineupNodeFrame(
                                                id: player.id,
                                                row: entry.row,
                                                order: order,
                                                frame: proxy.frame(in: .named(Self.space))
                                            )]
                                        )
                                    }
                                }
                        } else {
                            // The room being held open. Same share of the band
                            // as a player, so the others step aside by exactly
                            // the width he will take.
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: LineupRowFramesKey.self,
                            value: [LineupRowFrame(row: entry.row, frame: proxy.frame(in: .named(Self.space)))]
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: pitchHeight)
        .padding(.horizontal, compact ? 5 : 12)
        .padding(.top, compact ? 10 : 16)
        .padding(.bottom, compact ? 12 : 20)
        .background {
            PitchMarkings()
                .stroke(.white.opacity(0.16), lineWidth: 1)
                .padding(2)
        }
        .background(.white.opacity(0.04), in: .rect(cornerRadius: 18))
        .overlay {
            GeometryReader { proxy in
                carriedPlayer(containerWidth: proxy.size.width)
            }
            .allowsHitTesting(false)
        }
        .coordinateSpace(name: Self.space)
        // A normal vertical pan belongs to the page. The pitch starts claiming
        // the touch only after a deliberate long press has succeeded; once a
        // player is actually in hand the page is locked by `onDraggingChanged`.
        .simultaneousGesture(
            reorderGesture,
            including: onReorder == nil ? .none : .all
        )
        .onPreferenceChange(LineupNodeFramesKey.self) { nodeFrames = $0 }
        .onPreferenceChange(LineupRowFramesKey.self) { rowFrames = $0 }
    }

    /// A sport-neutral roster laid over the chosen court. Three is both the
    /// official width of a volleyball line and the most names an iPhone card
    /// can keep comfortably legible. Rows are balanced rather than chunked so
    /// four players become 2+2 and seven become 3+2+2, never 3+1 or 3+3+1.
    private var rosterCourt: some View {
        VStack(spacing: compact ? 6 : 10) {
            ForEach(Array(rosterRows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(alignment: .center, spacing: compact ? 3 : 6) {
                    ForEach(row) { player in
                        rosterNode(for: player)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // With the ordinary two volleyball lines, the first row's
                // surname otherwise lands directly on the regulation attack
                // line. Lift only its drawing; the two equal hit regions and
                // the court's one-third marking remain untouched.
                .offset(
                    y: rosterRows.count == 2 && rowIndex == 0
                        ? (compact ? -8 : -14)
                        : 0
                )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: rosterCourtHeight)
        .padding(.horizontal, compact ? 5 : 12)
        .padding(.top, sportStyle == .volleyball ? (compact ? 18 : 28) : (compact ? 10 : 16))
        .padding(.bottom, compact ? 12 : 20)
        .background {
            if sportStyle == .volleyball {
                VolleyballHalfCourtMarkings()
                    .stroke(.white.opacity(0.16), lineWidth: 1)
                    .padding(2)
            } else {
                // Temporary treatment for sports whose own court has not been
                // designed yet. Their players remain neutral and positionless.
                PitchMarkings()
                    .stroke(.white.opacity(0.16), lineWidth: 1)
                    .padding(2)
            }
        }
        .background(.white.opacity(0.04), in: .rect(cornerRadius: 18))
    }

    private var rosterRows: [[LineupPlayer]] {
        guard !players.isEmpty else { return [] }

        let rowCount = max(1, (players.count + 2) / 3)
        let baseCount = players.count / rowCount
        let extraCount = players.count % rowCount
        var start = 0

        return (0..<rowCount).map { row in
            let count = baseCount + (row < extraCount ? 1 : 0)
            defer { start += count }
            return Array(players[start..<(start + count)])
        }
    }

    /// The ordinary six-player court retains the familiar card height. Large
    /// social rosters grow the scrollable card instead of squeezing names or
    /// shrinking interactive player slots below the existing minimum.
    private var rosterCourtHeight: CGFloat {
        let rowCount = max(rosterRows.count, 1)
        let minimumNodeHeight: CGFloat = compact ? 40 : 44
        let spacing: CGFloat = compact ? 6 : 10
        let contentHeight = CGFloat(rowCount) * minimumNodeHeight
            + CGFloat(max(rowCount - 1, 0)) * spacing
        return max(pitchHeight, contentHeight)
    }

    private var rosterMarkerTint: Color {
        sportStyle == .volleyball ? teamTint : Color(white: 0.62)
    }

    /// Selection and the long-press move menu still belong to the lineup, not
    /// to football. The only interaction omitted here is position editing.
    @ViewBuilder
    private func rosterNode(for player: LineupPlayer) -> some View {
        let node = LineupPlayerNode(
            player: player,
            isSelected: player.id == selectedID,
            markerTint: rosterMarkerTint,
            compact: compact
        )
            .frame(maxWidth: .infinity, minHeight: compact ? 40 : 44)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(player.name)

        if let onSelect {
            let tappable = node
                .contentShape(.rect)
                .onTapGesture { onSelect(player) }
                .accessibilityAddTraits(.isButton)

            if let onMove {
                tappable.contextMenu {
                    Button("نقل إلى الفريق الآخر", systemImage: "arrow.left.arrow.right") {
                        onMove(player)
                    }
                }
            } else {
                tappable
            }
        } else {
            node
        }
    }

    /// The band and place under the finger.
    private func slot(at location: CGPoint, dragging: LineupPlayer) -> LineupDropSlot? {
        let measuredRows = dragRowFrames.isEmpty ? rowFrames : dragRowFrames
        let measuredNodes = dragNodeFrames.isEmpty ? nodeFrames : dragNodeFrames

        let band = measuredRows.first { $0.frame.contains(location) }
            ?? measuredRows.min { abs($0.frame.midY - location.y) < abs($1.frame.midY - location.y) }
        guard let band else { return nil }

        let others = measuredNodes
            .filter { $0.row == band.row && $0.id != dragging.id }
            .sorted { $0.order < $1.order }
        guard !others.isEmpty else {
            return LineupDropSlot(row: band.row, index: 0)
        }

        // With two players, excluding the one in hand leaves a single frame.
        // Comparing first and last would then always report LTR even on this
        // Arabic screen, which was the direct cause of the two-player loop.
        let isRightToLeft = layoutDirection == .rightToLeft
        let ahead = others.filter {
            isRightToLeft ? $0.frame.midX > location.x : $0.frame.midX < location.x
        }
        let proposedIndex = ahead.count

        // Keep the current slot while the finger is close to its boundary.
        // This small dead zone absorbs hand jitter without making a deliberate
        // move feel delayed.
        if
            let current = dropSlot,
            current.row == band.row,
            abs(current.index - proposedIndex) == 1
        {
            let boundaryIndex = min(current.index, proposedIndex)
            if others.indices.contains(boundaryIndex),
               abs(location.x - others[boundaryIndex].frame.midX) < Self.slotHysteresis {
                return current
            }
        }

        return LineupDropSlot(row: band.row, index: proposedIndex)
    }

    /// A scroll-sized movement cancels the first phase before the drag phase
    /// exists, so swiping from anywhere on the pitch scrolls naturally. Holding
    /// a player deliberately promotes the same touch into the carrying drag.
    private var reorderGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.28, maximumDistance: 10)
            .sequenced(before: DragGesture(
                minimumDistance: 0,
                coordinateSpace: .named(Self.space)
            ))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                let player = dragging ?? beginDragging(at: drag.startLocation)
                guard let player else { return }

                dragLocation = drag.location
                let next = slot(at: drag.location, dragging: player)
                guard next != dropSlot else { return }
                let hadDestination = dropSlot != nil
                withAnimation(.smooth(duration: 0.18)) {
                    dropSlot = next
                }
                if hadDestination { Haptics.selection() }
            }
            .onEnded { _ in
                finishDragging()
            }
    }

    /// Starts only when the completed long press began inside a measured player
    /// node. Holding an empty part of the pitch therefore never invents a drag.
    private func beginDragging(at touch: CGPoint) -> LineupPlayer? {
        guard
            onReorder != nil,
            let measured = nodeFrames.first(where: { $0.frame.contains(touch) }),
            let player = players.first(where: { $0.id == measured.id })
        else { return nil }

        dragNodeFrames = nodeFrames
        dragRowFrames = rowFrames
        dragGrabOffset = CGSize(
            width: touch.x - measured.frame.midX,
            height: touch.y - measured.frame.midY
        )
        let rowPlayers = players.filter { $0.row == player.row }
        let sourceIndex = rowPlayers.firstIndex { $0.id == player.id } ?? 0
        draggingID = player.id
        dropSlot = LineupDropSlot(row: player.row, index: sourceIndex)
        Haptics.impact(.light)
        onDraggingChanged?(true)
        return player
    }

    private func finishDragging() {
        guard let playerID = draggingID else {
            dragLocation = nil
            return
        }

        let destination = dropSlot
        withAnimation(.smooth(duration: 0.20)) {
            if let destination, let onReorder {
                onReorder(playerID, destination.row, destination.index)
            }
            draggingID = nil
            dropSlot = nil
        }
        dragLocation = nil
        dragGrabOffset = .zero
        dragNodeFrames = []
        dragRowFrames = []
        onDraggingChanged?(false)
    }

    /// A single lifted copy follows the hand. The slot inside the HStack is a
    /// transparent placeholder, so neither the gesture nor the player's visual
    /// identity is re-parented while the drag is active.
    @ViewBuilder
    private func carriedPlayer(containerWidth: CGFloat) -> some View {
        if let dragging {
            let originalFrame = dragNodeFrames.first { $0.id == dragging.id }?.frame
            let location = dragLocation ?? originalFrame.map {
                CGPoint(x: $0.midX, y: $0.midY)
            }
            if let location {
                let visualLocation = CGPoint(
                    x: location.x - dragGrabOffset.width,
                    y: location.y - dragGrabOffset.height
                )
                let readAs = dropSlot?.row ?? dragging.row
                let horizontalPosition = layoutDirection == .rightToLeft
                    ? containerWidth - visualLocation.x
                    : visualLocation.x
                LineupPlayerNode(
                    player: dragging,
                    isSelected: dragging.id == selectedID,
                    row: readAs,
                    compact: compact
                )
                .frame(
                    width: originalFrame?.width,
                    height: originalFrame?.height
                )
                .scaleEffect(1.12)
                .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
                .position(x: horizontalPosition, y: visualLocation.y)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(20)
            }
        }
    }

    /// The gesture is attached only when there is something to do with it. A
    /// `.onTapGesture` swallows the tap even when its closure does nothing, and
    /// on the exercise page that would eat the taps meant for the card itself.
    @ViewBuilder
    private func node(for player: LineupPlayer) -> some View {
        let node = LineupPlayerNode(
            player: player,
            isSelected: player.id == selectedID,
            row: player.row,
            compact: compact
        )
            .frame(maxWidth: .infinity, minHeight: compact ? 40 : 44)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(player.name)، \(player.row.title)")

        if let onSelect {
            let tappable = node
                .contentShape(.rect)
                .onTapGesture { onSelect(player) }
                .accessibilityAddTraits(.isButton)

            if onReorder != nil {
                // The stable pitch owns the long-press drag. Keeping the player
                // node tappable preserves the existing tap-to-trade action
                // without installing a second recognizer that competes with
                // page scrolling.
                tappable
            } else {
                tappable.contextMenu {
                    if let onMove {
                        Button("نقل إلى الفريق الآخر", systemImage: "arrow.left.arrow.right") {
                            onMove(player)
                        }
                    }
                }
            }
        } else {
            node
        }
    }
}

/// One player standing on the pitch.
private struct LineupPlayerNode: View {
    let player: LineupPlayer
    let isSelected: Bool
    let markerTint: Color
    /// A simple Equatable key drives football's colour interpolation without
    /// making the neutral sports carry a fictional LineupRow.
    let markerAnimationKey: Int
    var compact: Bool

    /// Football reads the colour from the band this player occupies *right
    /// now* — his own, or the destination he is being carried into.
    init(
        player: LineupPlayer,
        isSelected: Bool,
        row: LineupRow,
        compact: Bool = false
    ) {
        self.player = player
        self.isSelected = isSelected
        self.markerTint = row.tint
        self.markerAnimationKey = row.rawValue
        self.compact = compact
    }

    /// Volleyball and generic courts colour a player without assigning him a
    /// football position.
    init(
        player: LineupPlayer,
        isSelected: Bool,
        markerTint: Color,
        compact: Bool = false
    ) {
        self.player = player
        self.isSelected = isSelected
        self.markerTint = markerTint
        self.markerAnimationKey = 0
        self.compact = compact
    }

    var body: some View {
        VStack(spacing: compact ? 2 : 3) {
            Circle()
                .fill(markerTint)
                .frame(width: compact ? 12 : 14, height: compact ? 12 : 14)
                .overlay {
                    Circle()
                        .stroke(.white, lineWidth: isSelected ? 2 : 0)
                        .padding(-3)
                }
                // Interpolated rather than switched, so the colour arrives
                // with the space that opens for him rather than after it.
                .animation(.snappy(duration: 0.24), value: markerAnimationKey)
                .padding(.bottom, compact ? 1 : 2)

            if !player.firstName.isEmpty {
                Text(player.firstName)
                    .font(TamrinFont.font(size: compact ? 8 : 9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Text(player.displayName)
                .font(TamrinFont.font(size: compact ? 10.5 : 12, weight: .bold))
                .foregroundStyle(.white)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .opacity(isSelected ? 1 : 0.95)
        .animation(.snappy(duration: 0.2), value: isSelected)
    }
}

/// The lines on the grass: the touchline, the halfway circle cut by the top
/// edge, and the two boxes in front of our goal.
private struct PitchMarkings: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: 18, height: 18))

        // The centre circle, halved by the halfway line that runs along the
        // top edge — the far half of the pitch is off-card.
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.minY),
            radius: rect.width * 0.17,
            startAngle: .degrees(0),
            endAngle: .degrees(180),
            clockwise: false
        )

        let penaltyWidth = rect.width * 0.52
        let penaltyHeight = min(rect.height * 0.18, 58)
        path.addRect(
            CGRect(
                x: rect.midX - penaltyWidth / 2,
                y: rect.maxY - penaltyHeight,
                width: penaltyWidth,
                height: penaltyHeight
            )
        )

        let goalWidth = rect.width * 0.26
        let goalHeight = min(rect.height * 0.07, 24)
        path.addRect(
            CGRect(
                x: rect.midX - goalWidth / 2,
                y: rect.maxY - goalHeight,
                width: goalWidth,
                height: goalHeight
            )
        )
        return path
    }
}

/// One team's half of a volleyball court. The net sits at the open, upper edge
/// of the card and the attack line divides the front and back rows. Its double
/// rail and short ties make it read as a net without adding a different visual
/// material to the app's restrained glass drawing.
private struct VolleyballHalfCourtMarkings: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: 18, height: 18))

        let netInset = max(18, rect.width * 0.055)
        let netStart = rect.minX + netInset
        let netEnd = rect.maxX - netInset
        let netTop = rect.minY + 10
        let netBottom = netTop + 6

        path.move(to: CGPoint(x: netStart, y: netTop))
        path.addLine(to: CGPoint(x: netEnd, y: netTop))
        path.move(to: CGPoint(x: netStart, y: netBottom))
        path.addLine(to: CGPoint(x: netEnd, y: netBottom))

        let tieSpacing = max(14, (netEnd - netStart) / 18)
        var tieX = netStart
        while tieX <= netEnd {
            path.move(to: CGPoint(x: tieX, y: netTop))
            path.addLine(to: CGPoint(x: tieX, y: netBottom))
            tieX += tieSpacing
        }

        let attackY = rect.minY + rect.height / 3
        path.move(to: CGPoint(x: rect.minX, y: attackY))
        path.addLine(to: CGPoint(x: rect.maxX, y: attackY))
        return path
    }
}

// MARK: - Team card

/// Wallet does not dim a card before it lifts. A nearly imperceptible press is
/// enough to acknowledge the touch without making the hero start from a faded,
/// undersized snapshot.
private struct LineupCardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.992 : 1))
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

/// One side, as a card: a header that always shows who they are and how they
/// add up, and the pitch itself when the card is open.
struct LineupTeamCard: View {
    let side: LineupSide
    let players: [LineupPlayer]
    var isExpanded: Bool = true
    var compact = false
    var sportStyle: LineupSportStyle = .football
    /// A capacity-normalized score supplied by the editor. Read-only cards use
    /// the team's ordinary average when no comparison score is supplied.
    var strengthScore: Int?
    /// Folds the pitch away. Set inside the lineup page, where the two cards
    /// are worked on; nil on the exercise page, where the whole card is a way
    /// in rather than something to open in place.
    var onToggle: (() -> Void)?
    /// The whole card becomes one target that opens the lineup — a Wallet card
    /// rather than a disclosure row. Exclusive with `onToggle`.
    var onOpen: (() -> Void)?
    /// Turns the header into the page's team switcher while preserving the
    /// exact dot, name, count and accessory layout used by the source card.
    var onSwitch: (() -> Void)?
    var selectedID: UUID?
    var onSelect: ((LineupPlayer) -> Void)?
    var onMove: ((LineupPlayer) -> Void)?
    /// Passed through to the pitch. Nil everywhere the split is only being
    /// read — the exercise page, and the page's own preview card.
    var onReorder: ((UUID, LineupRow, Int) -> Void)?
    var onDraggingChanged: ((Bool) -> Void)?
    /// Hidden on the exercise page: the level is the organizer's working
    /// number while he splits, not something the roster needs to read.
    var showsLevel: Bool = true

    private var stats: LineupStats { LineupStats(players: players) }
    private var displayedStrength: Int {
        min(max(strengthScore ?? stats.averageStrength, 0), 100)
    }

    var body: some View {
        if let onOpen {
            Button(action: onOpen) {
                card
            }
            .buttonStyle(LineupCardPressStyle())
            .accessibilityLabel("\(side.title)، \(stats.count.counted(.player))")
            .accessibilityHint("يفتح التشكيلة")
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            header

            if isExpanded {
                if players.isEmpty {
                    Text("لا أحد في هذا الفريق بعد.")
                        .font(TamrinFont.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 292 : nil)
                        .padding(.vertical, compact ? 0 : 26)
                } else {
                    LineupPitchView(
                        players: players,
                        compact: compact,
                        pitchHeight: compact ? 292 : 288,
                        sportStyle: sportStyle,
                        teamTint: side.tint,
                        selectedID: selectedID,
                        onSelect: onSelect,
                        onMove: onMove,
                        onReorder: onReorder,
                        onDraggingChanged: onDraggingChanged
                    )
                }
            }
        }
        .padding(compact ? 10 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tamrinGlassCard()
        // One shape for the whole card, so the gaps between the header and the
        // pitch are part of the target rather than holes in it.
        .contentShape(.rect(cornerRadius: TamrinCard.cornerRadius))
    }

    @ViewBuilder
    private var header: some View {
        if let onSwitch {
            Button(action: onSwitch) {
                headerContent
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(side.title)، \(stats.count.counted(.player))")
            .accessibilityHint("يبدّل إلى \(side.other.title)")
        } else if onToggle != nil {
            Button {
                onToggle?()
            } label: {
                headerContent
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(side.title)، \(stats.count.counted(.player))")
        } else {
            headerContent
        }
    }

    private var headerContent: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 4) {
            HStack(spacing: compact ? 6 : 10) {
                Circle()
                    .fill(side.tint)
                    .frame(width: compact ? 8 : 10, height: compact ? 8 : 10)

                Text(side.title)
                    .font(TamrinFont.font(size: compact ? 15 : 19, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)

                Text(
                    compact
                        ? stats.count.formatted(.number.locale(.tamrin).grouping(.never))
                        : stats.count.counted(.player)
                )
                    .font(TamrinFont.font(size: compact ? 11 : 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .accessibilityLabel(stats.count.counted(.player))

                if onToggle != nil {
                    // Up when the card is open, down when it is shut — the one
                    // disclosure that reads the same either way round, which a
                    // sideways chevron does not in RTL.
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                } else if onOpen != nil || onSwitch != nil {
                    // The same affordance appears outside and inside the page,
                    // keeping the header pixel-stable through the hand-off.
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            if showsLevel && sportStyle.usesFootballFeatures {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(displayedStrength.formatted(.number.locale(.tamrin).grouping(.never)))
                        .font(TamrinFont.font(size: compact ? 20 : 15, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())

                    Text("من 100")
                        .font(TamrinFont.font(size: compact ? 9 : 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("قوة الفريق \(displayedStrength) من 100")
            }
        }
        .contentShape(.rect)
    }
}
