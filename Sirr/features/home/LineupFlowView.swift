//
//  LineupFlowView.swift
//  Sirr
//
//  The organizer's split, on its own page: everyone holding a seat is divided
//  immediately, then the organizer trades whoever he wants until it looks right.
//
//  Presented the way the apologies page is — a full-screen cover that rises
//  over the blurred exercise artwork — because it is the same kind of thing: a
//  list that belongs to this exercise and closes back onto it.
//

import SwiftUI

struct LineupFlowView: View {
    @Bindable var feed: HomeStore
    let occurrence: FeedOccurrence
    /// The exercise's artwork, blurred behind this page the way it sits behind
    /// the panel on the page that opened it.
    var artName: String = "ExerciseArt1"
    /// The saved split, or nil when the organizer threw it away. The exercise
    /// page holds it so the section under the progress bar updates the moment
    /// this page closes.
    var onFinish: (LineupPlan?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var candidates: [LineupPlayer] = []
    @State private var teams = LineupTeams()
    /// The player waiting for someone to trade places with.
    @State private var tradeCandidateID: UUID?
    @State private var isLoading = true
    /// Ratings may finish after the page appears. A fresh automatic split can
    /// be refined when they arrive, but never overwrite an organizer's edits.
    @State private var hasManuallyEditedTeams = false
    /// Tonight's positions, as the organizer set them.
    @State private var positions = LineupPositions()
    /// People who took a seat after the last split was saved.
    @State private var unplaced: [LineupPlayer] = []
    @State private var showDeleteConfirm = false
    /// A player is in hand. The page holds still while he is: otherwise the
    /// scroll view takes the vertical half of the drag and cancels it.
    @State private var isDraggingPlayer = false

    private var sportStyle: LineupSportStyle {
        LineupSportStyle(symbol: feed.team(for: occurrence)?.symbol)
    }

    private var usesFootballFeatures: Bool {
        sportStyle.usesFootballFeatures
    }

    private func split(_ players: [LineupPlayer]) -> LineupTeams {
        usesFootballFeatures
            ? LineupBalancer.split(players)
            : LineupBalancer.randomSplit(players)
    }

    /// A score users can read as "out of 100". Dividing both totals by the
    /// larger team size keeps equal teams equivalent to their average, while a
    /// team missing a player pays for the empty place instead of looking
    /// deceptively equal.
    private var strengthScores: (first: Int, second: Int) {
        let first = LineupStats(players: teams.first)
        let second = LineupStats(players: teams.second)
        let capacity = max(first.count, second.count, 1)
        func score(_ total: Int) -> Int {
            min(max(Int((Double(total) / Double(capacity)).rounded()), 0), 100)
        }
        return (score(first.totalStrength), score(second.totalStrength))
    }

    private var selectedPlayer: LineupPlayer? {
        guard let tradeCandidateID else { return nil }
        return teams.allPlayers.first { $0.id == tradeCandidateID }
    }

    private var selectedPlayerSide: LineupSide? {
        guard let tradeCandidateID else { return nil }
        return teams.side(of: tradeCandidateID)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                lineupContent
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 30)
        }
        // Held still while a player is in hand. A move along one band is short
        // and sideways and the scroll view let it pass, but reaching another
        // band means travelling up or down — the one movement it claims for
        // itself, cancelling the drag mid-flight and losing the drop.
        .scrollDisabled(isDraggingPlayer)
        .safeAreaInset(edge: .top) { topBar }
        .safeAreaInset(edge: .bottom) { bottomBar }
        // Painted by the page rather than left to `presentationBackground`. A
        // cover with a see-through background gives the zoom transition nothing
        // solid to grow, and UIKit quietly falls back to a slide — so the card
        // has to expand into a page that carries its own backdrop.
        .background {
            ZStack {
                Image(exerciseArt: artName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 26, opaque: true)
                Color.black.opacity(0.46)
            }
            .ignoresSafeArea()
        }
        .environment(\.layoutDirection, .rightToLeft)
        .colorScheme(.dark)
        .task { await load() }
        .confirmationDialog(
            "حذف التشكيلة؟",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("حذف التشكيلة", role: .destructive) { deleteLineup() }
            Button("تراجع", role: .cancel) {}
        } message: {
            Text("سيعود التمرين بلا تشكيلة، ويبقى المسجلون كما هم.")
        }
    }

    // MARK: - Loading

    private func load() async {
        positions = usesFootballFeatures
            ? LineupPositionStore.load(eventID: occurrence.id)
            : LineupPositions()
        candidates = feed.lineupCandidates(
            for: occurrence,
            usesFootballPositions: usesFootballFeatures
        )
        var restoredSavedPlan = false

        if let plan = LineupStore.load(eventID: occurrence.id) {
            let resolved = plan.resolve(against: candidates)
            // A plan that lost everyone — a roster that was emptied and
            // rebuilt — is no plan at all, so a fresh split is made below.
            if !resolved.teams.allPlayers.isEmpty {
                teams = resolved.teams
                unplaced = resolved.unplaced
                restoredSavedPlan = true
                isLoading = false
            }
        }

        // The removed picker must not be replaced by a network wait. Draw the
        // next stage immediately with neutral strengths, then refine this
        // untouched fresh split once the real ratings arrive.
        if !restoredSavedPlan {
            teams = split(candidates)
            unplaced = []
            isLoading = false
        }

        // Every non-football sport is intentionally roster-only: no ratings
        // RPC, no position refinement, and no second random split after the
        // first teams are already visible.
        guard usesFootballFeatures else { return }

        let strengths = await feed.lineupStrengths(for: occurrence)
        if !strengths.isEmpty { apply(strengths) }

        if !restoredSavedPlan, !hasManuallyEditedTeams {
            teams = split(candidates)
        }
        isLoading = false
    }

    /// The ratings land after the roster does, so both the pool and any
    /// already-restored sides are brought up to date in place.
    private func apply(_ strengths: [UUID: Int]) {
        for index in candidates.indices {
            if let strength = strengths[candidates[index].id] {
                candidates[index].strength = strength
            }
        }
        for side in LineupSide.allCases {
            for index in teams[side].indices {
                if let strength = strengths[teams[side][index].id] {
                    teams[side][index].strength = strength
                }
            }
        }
        unplaced = unplaced.map { player in
            var updated = player
            if let strength = strengths[player.id] { updated.strength = strength }
            return updated
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        ZStack {
            Text("التشكيلة")
                .font(TamrinFont.font(size: 17, weight: .bold))
                .foregroundStyle(.white)

            HStack {
                Menu {
                    Button("حذف التشكيلة", systemImage: "trash", role: .destructive) {
                        showDeleteConfirm = true
                    }
                } label: {
                    Label("خيارات", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(
                            width: TamrinControlMetrics.glassIconContent,
                            height: TamrinControlMetrics.glassIconContent
                        )
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .accessibilityLabel("خيارات التشكيلة")

                Spacer(minLength: 0)

                Button {
                    dismiss()
                } label: {
                    Label("إغلاق", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(
                            width: TamrinControlMetrics.glassIconContent,
                            height: TamrinControlMetrics.glassIconContent
                        )
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .accessibilityLabel("إغلاق")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            ZStack {
                if reduceMotion {
                    bottomActionControls
                        .id(bottomActionKey)
                        .transition(.opacity)
                } else {
                    bottomActionControls
                        .id(bottomActionKey)
                        .transition(.blurReplace)
                }
            }
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.24),
                value: bottomActionKey
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    /// Identity follows only what the bar visibly says. Selecting another
    /// player on the same side must not replay an animation when neither the
    /// action nor its destination changed.
    private var bottomActionKey: String {
        if isLoading { return "loading" }
        if candidates.count < 2 { return "close" }
        if let destination = selectedPlayerSide?.other {
            return "move-\(destination.rawValue)"
        }
        return "idle"
    }

    @ViewBuilder
    private var bottomActionControls: some View {
        if isLoading {
            EmptyView()
        } else if candidates.count < 2 {
            TamrinActionButton(title: "إغلاق", prominent: false) {
                dismiss()
            }
        } else if let selectedPlayer, let source = selectedPlayerSide {
            HStack(spacing: 10) {
                TamrinActionButton(
                    title: source.other == .first
                        ? "نقل للفريق الأول"
                        : "نقل للفريق الثاني",
                    // The team cards are stacked, so the arrow should point at
                    // the destination the player will move to.
                    systemImage: source == .first ? "arrow.down" : "arrow.up"
                ) {
                    move(selectedPlayer)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityLabel(
                    "نقل \(selectedPlayer.displayName) إلى \(source.other.title)"
                )
                .accessibilityHint("ينقله بدون تبديل لاعب آخر")

                TamrinActionButton(title: "إلغاء", prominent: false) {
                    tradeCandidateID = nil
                }
                .frame(maxWidth: 110)
                .accessibilityLabel("إلغاء اختيار \(selectedPlayer.displayName)")
            }
        } else {
            HStack(spacing: 10) {
                TamrinActionButton(
                    title: "إعادة التوزيع",
                    systemImage: "arrow.trianglehead.2.clockwise",
                    prominent: false,
                    action: splitTeams
                )

                TamrinActionButton(title: "حفظ", action: saveLineup)
            }
        }
    }

    // MARK: - The two sides

    @ViewBuilder
    private var lineupContent: some View {
        if isLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text(
                    usesFootballFeatures
                        ? "يجهّز التشكيلة ويوازن الفريقين…"
                        : "يجهّز التشكيلة ويوزّع اللاعبين…"
                )
                    .font(TamrinFont.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .tamrinGlassCard()
        } else if candidates.count < 2 {
            Text("تحتاج لاعبين اثنين على الأقل لصناعة التشكيلة.")
                .font(TamrinFont.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .tamrinGlassCard()
        } else {
            if usesFootballFeatures {
                balanceSummary
            } else {
                randomSplitSummary
            }

            if !unplaced.isEmpty {
                unplacedNotice
            }

            teamsBoard

            Text(
                usesFootballFeatures
                    ? "حدّد لاعبًا ثم انقله بالزر أو اختر لاعبًا من الفريق الآخر للتبديل. اضغط مطولًا لتغيير مركزه."
                    : "حدّد لاعبًا ثم انقله بالزر أو اختر لاعبًا من الفريق الآخر للتبديل."
            )
                .font(TamrinFont.font(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
        }
    }

    private var balanceSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: strengthGap <= 3 ? "equal.circle.fill" : "chart.bar.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(strengthComparisonLabel)
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)

                Text("قوة كل فريق موضحة من 100")
                    .font(TamrinFont.font(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .tamrinGlassCard()
    }

    private var randomSplitSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "shuffle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("توزيع عشوائي")
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)

                Text(
                    "\(teams.first.count.counted(.player)) مقابل "
                        + teams.second.count.counted(.player)
                )
                .font(TamrinFont.font(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .tamrinGlassCard()
    }

    private var strengthGap: Int {
        abs(strengthScores.first - strengthScores.second)
    }

    private var strengthComparisonLabel: String {
        guard strengthGap > 3 else { return "الفريقان متكافئان تقريبًا" }
        let stronger: LineupSide = strengthScores.first > strengthScores.second ? .first : .second
        switch strengthGap {
        case 4...7: return "\(stronger.title) أقوى قليلًا"
        case 8...14: return "\(stronger.title) أقوى"
        default: return "\(stronger.title) أقوى بوضوح"
        }
    }

    @ViewBuilder
    private var teamsBoard: some View {
        VStack(spacing: 12) {
            ForEach(LineupSide.allCases) { side in
                editableTeamCard(side)
            }
        }
    }

    private func editableTeamCard(_ side: LineupSide) -> some View {
        LineupTeamCard(
            side: side,
            players: teams[side],
            compact: false,
            sportStyle: sportStyle,
            strengthScore: usesFootballFeatures
                ? (side == .first ? strengthScores.first : strengthScores.second)
                : nil,
            selectedID: tradeCandidateID,
            onSelect: { tap($0) },
            onMove: { move($0) },
            onReorder: usesFootballFeatures
                ? { reorder($0, to: $1, at: $2) }
                : nil,
            onDraggingChanged: usesFootballFeatures
                ? { isDraggingPlayer = $0 }
                : nil,
            showsLevel: usesFootballFeatures
        )
    }

    private var unplacedNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.badge.clock")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TamrinTheme.peach)

            Text(
                unplaced.count == 1
                    ? "لاعب واحد سجّل بعد آخر تقسيم وما دخل التشكيلة."
                    : "\(unplaced.count.counted(.player)) سجّلوا بعد آخر تقسيم وما دخلوا التشكيلة."
            )
                .font(TamrinFont.font(size: 13, weight: .medium))
                .foregroundStyle(.white)

            Spacer(minLength: 0)

            Button("أعِد التقسيم") { splitTeams() }
                .font(TamrinFont.font(size: 13, weight: .bold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .tamrinGlassCard()
    }

    // MARK: - Actions

    private func splitTeams() {
        guard candidates.count >= 2 else { return }
        hasManuallyEditedTeams = true
        withAnimation(.smooth(duration: 0.24)) {
            teams = split(candidates)
        }
        tradeCandidateID = nil
        unplaced = []
        Haptics.success()
    }

    /// One tap arms a player, the next one on the other side completes the
    /// trade. Tapping the armed player again puts him back down.
    private func tap(_ player: LineupPlayer) {
        guard let armedID = tradeCandidateID else {
            tradeCandidateID = player.id
            Haptics.selection()
            return
        }

        if armedID == player.id {
            tradeCandidateID = nil
            return
        }

        guard teams.side(of: armedID) != teams.side(of: player.id) else {
            // Both on the same side: treat it as changing his mind about who
            // he meant to move rather than as a no-op.
            tradeCandidateID = player.id
            Haptics.selection()
            return
        }

        withAnimation(.smooth(duration: 0.20)) {
            hasManuallyEditedTeams = true
            teams.swap(armedID, with: player.id)
            tradeCandidateID = nil
        }
        Haptics.impact(.light)
    }

    /// A player dropped somewhere on his own pitch.
    ///
    /// Two things can have changed and they are written separately: where he
    /// stands within a band is the side's array order, and which band he is in
    /// is his position for tonight. Dropping him back in his own band is only
    /// the first, so his position is left alone rather than re-written with the
    /// value it already had — which would mark it as the organizer's choice
    /// when he never made one.
    private func reorder(_ playerID: UUID, to row: LineupRow, at index: Int) {
        let wasIn = teams.allPlayers.first { $0.id == playerID }?.row
        guard wasIn != row || teams.needsMove(playerID, inRow: row, at: index) else { return }
        hasManuallyEditedTeams = true
        withAnimation(.smooth(duration: 0.20)) {
            if wasIn != row {
                choosePosition(row.position, for: playerID)
            }
            teams.place(playerID, inRow: row, at: index)
        }
    }

    private func move(_ player: LineupPlayer) {
        hasManuallyEditedTeams = true
        withAnimation(.smooth(duration: 0.20)) {
            teams.move(player.id)
            tradeCandidateID = nil
        }
        Haptics.impact(.light)
    }

    /// Where this player plays tonight. Saved against the exercise, never
    /// against his profile, and applied to the pool and to any side he is
    /// already standing in so the pitch redraws him in the right band.
    private func choosePosition(_ position: PlayerPosition, for playerID: UUID) {
        positions.set(position, for: playerID)
        persistPositions(position, overridden: true, for: playerID)
    }

    private func resetPosition(for playerID: UUID) {
        positions.clear(playerID)
        LineupPositionStore.save(positions, eventID: occurrence.id)
        // Back to whatever the roster says, which is what a fresh read gives.
        let profilePosition = feed.lineupCandidates(for: occurrence)
            .first { $0.id == playerID }?
            .position ?? .midfielder
        applyPosition(profilePosition, overridden: false, for: playerID)
    }

    private func persistPositions(
        _ position: PlayerPosition,
        overridden: Bool,
        for playerID: UUID
    ) {
        LineupPositionStore.save(positions, eventID: occurrence.id)
        applyPosition(position, overridden: overridden, for: playerID)
    }

    private func applyPosition(
        _ position: PlayerPosition,
        overridden: Bool,
        for playerID: UUID
    ) {
        hasManuallyEditedTeams = true
        Haptics.selection()
        withAnimation(.smooth(duration: 0.20)) {
            if let index = candidates.firstIndex(where: { $0.id == playerID }) {
                candidates[index].position = position
                candidates[index].isPositionOverridden = overridden
            }
            teams.setPosition(position, overridden: overridden, for: playerID)
        }
    }

    private func saveLineup() {
        let plan = LineupPlan(teams: teams)
        LineupStore.save(plan, eventID: occurrence.id)
        onFinish(plan)
        Haptics.success()
        dismiss()
    }

    private func deleteLineup() {
        LineupStore.clear(eventID: occurrence.id)
        onFinish(nil)
        dismiss()
    }
}

/// The position badge, and — for the organizer — the control that changes it.
///
/// `PositionTag` names the stored word, which a guest does not have; this one
/// always has something to say, and can be pressed to say something else.
struct LineupRowTag: View {
    let row: LineupRow
    /// When set, the tag opens the list of positions for tonight.
    var onChoose: ((PlayerPosition) -> Void)?
    /// Offered only once tonight's position differs from the player's profile.
    var onReset: (() -> Void)?

    var body: some View {
        if let onChoose {
            Menu {
                ForEach(PlayerPosition.allCases, id: \.rawValue) { position in
                    Button {
                        onChoose(position)
                    } label: {
                        Label(
                            position.rawValue,
                            systemImage: row == LineupRow(position) ? "checkmark" : ""
                        )
                    }
                }

                if let onReset {
                    Divider()
                    Button("رجّعه لمركزه في ملفه", systemImage: "arrow.uturn.backward") {
                        onReset()
                    }
                }
            } label: {
                tag(showsChevron: true)
            }
            .accessibilityLabel("مركزه الليلة: \(row.title)")
            .accessibilityHint("يفتح اختيار مركزه في هذا الموعد")
        } else {
            tag(showsChevron: false)
        }
    }

    private func tag(showsChevron: Bool) -> some View {
        HStack(spacing: 4) {
            Text(row.title)
                .font(TamrinFont.font(size: 12, weight: .bold))
                .lineLimit(1)

            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(row.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(row.tint.opacity(0.14), in: .capsule)
        .accessibilityLabel("مركزه: \(row.title)")
    }
}
