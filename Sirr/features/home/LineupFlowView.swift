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
    let feed: HomeStore
    let occurrence: FeedOccurrence
    var artName: String = "ExerciseArt1"
    var onFinish: (LineupPlan?) -> Void

    var body: some View {
        // The stack exists for iPhone Duo's vertical bar, where the page's
        // close and options buttons live. Everywhere else its bar stays hidden
        // and the page draws its own. Hosted here rather than at each cover so
        // every place that opens the editor gets it.
        LineupFlowPage(feed: feed, occurrence: occurrence, artName: artName, onFinish: onFinish)
            .verticalBarHost()
    }
}

private struct LineupFlowPage: View {
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
    @Environment(\.hasVerticalBar) private var hasVerticalBar
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
    /// The split as it was last kept, on the server or as a draft. Nil for a
    /// fresh split nobody has kept yet.
    @State private var keptSides: [[UUID]]?
    @State private var confirmsLeaving = false
    @State private var isSavingDraft = false
    @State private var draftError: String?
    /// A player is in hand. The page holds still while he is: otherwise the
    /// scroll view takes the vertical half of the drag and cancels it.
    @State private var isDraggingPlayer = false

    private var sportStyle: LineupSportStyle {
        LineupSportStyle(sport: feed.team(for: occurrence)?.sport)
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
        GeometryReader { proxy in
            if let fold = proxy.tabletopFold, !isLoading, candidates.count >= 2 {
                tabletopBoard(fold: fold)
            } else {
                standardBoard
            }
        }
        // iPhone Duo's cover screen: the bar's buttons would sit under the
        // camera, so the system places them in its vertical bar instead.
        .toolbar {
            if hasVerticalBar {
                ToolbarItem(placement: .cancellationAction) { closeButton }
                ToolbarItem(placement: .primaryAction) { optionsMenu }
            }
        }
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
        .environment(\.layoutDirection, .tamrin)
        .colorScheme(.dark)
        .task { await load() }
        .confirmationDialog(
            "تحفظ التشكيلة قبل ما تطلع؟",
            isPresented: $confirmsLeaving,
            titleVisibility: .visible
        ) {
            Button("حفظ كمسودة") { saveDraft() }
            Button("تجاهل التغييرات", role: .destructive) { dismiss() }
            Button("تراجع", role: .cancel) {}
        } message: {
            Text("المسودة تبقى عندك وحدك لين تنشرها.")
        }
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

    private var standardBoard: some View {
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
    }

    // MARK: - Tactics board

    /// iPhone Duo standing half-open on a table: a tactics board. The pitches
    /// fill the raised half, where the whole group can read them, and every
    /// control moves to the half lying on the table, where a tap doesn't rock
    /// the phone. Nothing is placed across the fold itself.
    private func tabletopBoard(fold: CGRect) -> some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                teamsBoard
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .scrollDisabled(isDraggingPlayer)
            .safeAreaInset(edge: .top) { topBar }
            .frame(height: max(fold.minY, 0))

            Color.clear.frame(height: fold.height)

            ScrollView(showsIndicators: false) {
                tabletopDeck
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var tabletopDeck: some View {
        VStack(spacing: 12) {
            if usesFootballFeatures {
                balanceSummary
            } else {
                randomSplitSummary
            }

            if !unplaced.isEmpty {
                unplacedNotice
            }

            ForEach(LineupSide.allCases) { side in
                benchRow(side)
            }

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
            .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: bottomActionKey)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// A team as a row of chips on the table half. Tapping one arms him the
    /// same way tapping him on the pitch does, so a trade can be made without
    /// reaching up to the raised half.
    private func benchRow(_ side: LineupSide) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(side.title)
                .font(TamrinFont.font(size: 12, weight: .bold))
                .foregroundStyle(side.tint)
                .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(teams[side]) { player in
                        benchChip(player, side: side)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollClipDisabled()
        }
    }

    private func benchChip(_ player: LineupPlayer, side: LineupSide) -> some View {
        let isSelected = tradeCandidateID == player.id
        return Button {
            tap(player)
        } label: {
            HStack(spacing: 6) {
                MemberAvatar(name: player.name, size: 26, imageUrl: player.avatarUrl)
                Text(player.displayName)
                    .font(TamrinFont.font(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? .black : .white)
            .background(
                Capsule().fill(isSelected ? AnyShapeStyle(side.tint) : AnyShapeStyle(.white.opacity(0.12)))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint("يحدده، ثم اختر لاعبًا من الفريق الآخر للتبديل")
    }

    // MARK: - Loading

    private func load() async {
        // The server first, so the candidates below are built against the
        // overrides this exercise actually carries rather than an empty cache.
        await LineupStore.load(eventID: occurrence.id)
        positions = usesFootballFeatures
            ? LineupStore.positions(for: occurrence.id)
            : LineupPositions()
        candidates = feed.lineupCandidates(
            for: occurrence,
            usesFootballPositions: usesFootballFeatures
        )
        var restoredSavedPlan = false

        if let plan = LineupStore.cached(eventID: occurrence.id) {
            let resolved = plan.resolve(against: candidates)
            // A plan that lost everyone — a roster that was emptied and
            // rebuilt — is no plan at all, so a fresh split is made below.
            if !resolved.teams.allPlayers.isEmpty {
                teams = resolved.teams
                unplaced = resolved.unplaced
                keptSides = [plan.first, plan.second]
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

            if !hasVerticalBar {
                HStack {
                    optionsMenu
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.regular)

                    Spacer(minLength: 0)

                    closeButton
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.regular)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private var optionsMenu: some View {
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
        .accessibilityLabel("خيارات التشكيلة")
    }

    private var closeButton: some View {
        Button {
            close()
        } label: {
            Label("إغلاق", systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .semibold))
                .frame(
                    width: TamrinControlMetrics.glassIconContent,
                    height: TamrinControlMetrics.glassIconContent
                )
        }
        .accessibilityLabel("إغلاق")
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
            TamrinActionButton(title: String(localized: "إغلاق"), prominent: false) {
                dismiss()
            }
        } else if let selectedPlayer, let source = selectedPlayerSide {
            HStack(spacing: 10) {
                TamrinActionButton(
                    title: source.other == .first
                        ? String(localized: "نقل للفريق الأول")
                        : String(localized: "نقل للفريق الثاني"),
                    // The arrow points at the destination the player will move
                    // to: down or up while the cards are stacked, and across to
                    // the other pitch when they stand side by side. The first
                    // side leads, and the directional arrows follow the
                    // language, so this reads right in Arabic and English.
                    systemImage: teamsSideBySide
                        ? (source == .first ? "arrow.forward" : "arrow.backward")
                        : (source == .first ? "arrow.down" : "arrow.up")
                ) {
                    move(selectedPlayer)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityLabel(
                    "نقل \(selectedPlayer.displayName) إلى \(source.other.title)"
                )
                .accessibilityHint("ينقله بدون تبديل لاعب آخر")

                TamrinActionButton(title: String(localized: "إلغاء"), prominent: false) {
                    tradeCandidateID = nil
                }
                .frame(maxWidth: 110)
                .accessibilityLabel("إلغاء اختيار \(selectedPlayer.displayName)")
            }
        } else {
            VStack(spacing: 8) {
                if let draftError {
                    Label(draftError, systemImage: "exclamationmark.circle.fill")
                        .font(TamrinFont.font(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 10) {
                    Button(action: splitTeams) {
                        Label("إعادة التوزيع", systemImage: "arrow.trianglehead.2.clockwise")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .accessibilityLabel("إعادة التوزيع")

                    // A published lineup has no draft to go back to: every
                    // change to it reaches the players.
                    if !isPublished {
                        TamrinActionButton(
                            title: String(localized: "حفظ كمسودة"),
                            isLoading: isSavingDraft,
                            prominent: false,
                            action: saveDraft
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .disabled(isSavingDraft)
                    }

                    TamrinActionButton(
                        title: isPublished ? String(localized: "نشر التعديلات") : String(localized: "نشر"),
                        action: publishLineup
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .disabled(isSavingDraft)
                }
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
                        ? String(localized: "يجهّز التشكيلة ويوازن الفريقين…")
                        : String(localized: "يجهّز التشكيلة ويوزّع اللاعبين…")
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
                    ? String(localized: "حدّد لاعبًا ثم انقله بالزر أو اختر لاعبًا من الفريق الآخر للتبديل. اسحب اللاعب مباشرة لتغيير مركزه، واسحب أرضية الملعب للتمرير.")
                    : String(localized: "حدّد لاعبًا ثم انقله بالزر أو اختر لاعبًا من الفريق الآخر للتبديل.")
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
                    "\(teams.first.count.counted(.player)) مقابل \(teams.second.count.counted(.player))"
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
        guard strengthGap > 3 else { return String(localized: "الفريقان متكافئان تقريبًا") }
        let stronger: LineupSide = strengthScores.first > strengthScores.second ? .first : .second
        switch strengthGap {
        case 4...7: return String(localized: "\(stronger.title) أقوى قليلًا")
        case 8...14: return String(localized: "\(stronger.title) أقوى")
        default: return String(localized: "\(stronger.title) أقوى بوضوح")
        }
    }

    @ViewBuilder
    /// iPhone Duo open, or any screen as wide: the two pitches face each
    /// other like the two halves of one match, instead of one under the other.
    private var teamsSideBySide: Bool { horizontalSizeClass == .regular }

    private var teamsBoard: some View {
        let layout = teamsSideBySide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            : AnyLayout(VStackLayout(spacing: 12))
        return layout {
            ForEach(LineupSide.allCases) { side in
                editableTeamCard(side)
                    .frame(maxWidth: .infinity)
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
                    ? String(localized: "لاعب واحد سجّل بعد آخر تقسيم وما دخل التشكيلة.")
                    : String(localized: "\(unplaced.count.counted(.player)) سجّلوا بعد آخر تقسيم وما دخلوا التشكيلة.")
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
        LineupStore.savePositions(positions, eventID: occurrence.id)
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
        LineupStore.savePositions(positions, eventID: occurrence.id)
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

    /// «نشر» is the moment the split becomes the group's, and the button says
    /// so. Every drag before it was a draft only the organizer could see, which
    /// is the point: reading a half finished lineup tells a player he is
    /// dropped when he is not.
    private func publishLineup() {
        let plan = LineupPlan(teams: teams)
        LineupStore.save(plan, positions: positions, eventID: occurrence.id)
        Task { await LineupStore.publish(eventID: occurrence.id) }
        onFinish(plan)
        Haptics.success()
        dismiss()
    }

    private var isPublished: Bool { LineupStore.isPublished(eventID: occurrence.id) }

    /// True when the split on screen is not the one last kept.
    private var hasUnsavedChanges: Bool {
        guard candidates.count >= 2, !teams.allPlayers.isEmpty else { return false }
        return keptSides != [teams.first.map(\.id), teams.second.map(\.id)]
    }

    private func close() {
        if hasUnsavedChanges { confirmsLeaving = true } else { dismiss() }
    }

    /// Keeps the split for later without telling anyone. It opens again
    /// exactly as it was left, and players see nothing until «نشر».
    private func saveDraft() {
        guard !isSavingDraft else { return }
        let plan = LineupPlan(teams: teams)
        isSavingDraft = true
        draftError = nil
        Task {
            let saved = await LineupStore.saveDraft(plan, positions: positions, eventID: occurrence.id)
            isSavingDraft = false
            guard saved else {
                Haptics.error()
                draftError = String(localized: "ما انحفظت المسودة. تأكد من الاتصال وحاول مجددًا.")
                return
            }
            keptSides = [plan.first, plan.second]
            onFinish(plan)
            Haptics.success()
            dismiss()
        }
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
                ForEach(PlayerPosition.football, id: \.rawValue) { position in
                    Button {
                        onChoose(position)
                    } label: {
                        Label(
                            position.title,
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
