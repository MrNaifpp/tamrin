//
//  LineupTeamPage.swift
//  Sirr
//
//  One side, opened out of its card on the exercise page: the pitch it was
//  showing, and under it the same players as a list you can read name by name.
//
//  Deliberately nothing else. The split, the trades and the balance between the
//  two sides all belong to the editor behind «تعديل» — this page is the answer,
//  not the working.
//

import SwiftUI

struct LineupTeamPage: View {
    let feed: HomeStore
    let occurrence: FeedOccurrence
    var artName: String = "ExerciseArt1"
    /// Present only for the in-place Wallet transition. The destination card
    /// uses the source card's id while the surrounding page fades in behind it.
    private let transitionSource: LineupSide?
    private let transitionNamespace: Namespace.ID?
    /// A transition is seeded from the exact source snapshot. Re-resolving on
    /// appearance could change its count or players between adjacent frames.
    private let reloadsTeamsOnAppear: Bool
    var heroExpanded: Bool
    var backdropVisible: Bool
    var detailsVisible: Bool
    var interactionEnabled: Bool
    var onTransitionReady: (() -> Void)?
    var onRequestClose: (() -> Void)?
    /// Passed straight up to the exercise page whenever the editor changes or
    /// throws away the lineup.
    var onFinish: (LineupPlan?) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Seeded by the card that was pressed, then owned by the page: its header
    /// is the switch between the two sides.
    @State private var side: LineupSide
    @State private var teams = LineupTeams()
    @State private var positions = LineupPositions()
    @State private var showEditor = false

    init(
        feed: HomeStore,
        occurrence: FeedOccurrence,
        artName: String = "ExerciseArt1",
        side: LineupSide,
        initialTeams: LineupTeams? = nil,
        transitionSource: LineupSide? = nil,
        transitionNamespace: Namespace.ID? = nil,
        heroExpanded: Bool = true,
        backdropVisible: Bool = true,
        detailsVisible: Bool = true,
        interactionEnabled: Bool = true,
        onTransitionReady: (() -> Void)? = nil,
        onRequestClose: (() -> Void)? = nil,
        onFinish: @escaping (LineupPlan?) -> Void
    ) {
        self.feed = feed
        self.occurrence = occurrence
        self.artName = artName
        self.transitionSource = transitionSource
        self.transitionNamespace = transitionNamespace
        self.reloadsTeamsOnAppear = initialTeams == nil
        self.heroExpanded = heroExpanded
        self.backdropVisible = backdropVisible
        self.detailsVisible = detailsVisible
        self.interactionEnabled = interactionEnabled
        self.onTransitionReady = onTransitionReady
        self.onRequestClose = onRequestClose
        self.onFinish = onFinish
        _side = State(initialValue: side)
        _teams = State(initialValue: initialTeams ?? LineupTeams())
    }

    private var usesWalletTransition: Bool {
        transitionSource != nil && transitionNamespace != nil
    }

    private var sportStyle: LineupSportStyle {
        LineupSportStyle(sport: feed.team(for: occurrence)?.sport)
    }

    /// Back to front, the way a squad list is read — and the same order the
    /// balancer leaves the side in, so a manual move does not shuffle the list.
    private var players: [LineupPlayer] {
        guard sportStyle.usesFootballFeatures else { return teams[side] }
        return teams[side].sorted { lhs, rhs in
            if lhs.row != rhs.row { return lhs.row.rawValue > rhs.row.rawValue }
            return lhs.strength > rhs.strength
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                // Both sides exist for the length of the dissolve, so each
                // swapped region is its own ZStack: laid out in a VStack they
                // would briefly stack one above the other and shove the page.
                ZStack(alignment: .top) {
                    heroTeamCard
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    guard size.width > 0, size.height > 0 else { return }
                    onTransitionReady?()
                }

                Text("القائمة")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
                    .walletDetailVisibility(
                        detailsVisible,
                        enabled: usesWalletTransition
                    )

                ZStack(alignment: .top) {
                    VStack(spacing: 8) {
                        ForEach(players) { player in
                            playerListRow(player)
                        }
                    }
                    .id(side)
                    .transition(.blurReplace)
                }
                .walletDetailVisibility(
                    detailsVisible,
                    enabled: usesWalletTransition
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top) { topBar }
        .background {
            ZStack {
                Image(exerciseArt: artName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 26, opaque: true)
                Color.black.opacity(0.46)
            }
            .opacity(usesWalletTransition ? (backdropVisible ? 1 : 0) : 1)
            .ignoresSafeArea()
        }
        .environment(\.layoutDirection, .rightToLeft)
        .colorScheme(.dark)
        .allowsHitTesting(interactionEnabled)
        .task {
            if reloadsTeamsOnAppear { await reload() }
        }
        .fullScreenCover(isPresented: $showEditor) {
            LineupFlowView(feed: feed, occurrence: occurrence, artName: artName) { plan in
                onFinish(plan)
                // Nothing left to show this side on: the whole lineup went.
                if plan == nil { closePage() } else { Task { await reload() } }
            }
        }
    }

    /// The card itself is the only thing present on frame one. Everything else
    /// waits until its flight is underway, matching Wallet's card-first reveal.
    @ViewBuilder
    private var heroTeamCard: some View {
        // The second source card is folded. Matching that same state at both
        // ends prevents an expanded destination from being replaced by a
        // shorter source on the final hand-off frame.
        let showsPitch = !usesWalletTransition
            || transitionSource == .first
            || heroExpanded
        let card = LineupTeamCard(
            side: side,
            players: teams[side],
            isExpanded: showsPitch,
            sportStyle: sportStyle,
            onSwitch: switchSide,
            showsLevel: false
        )
        .clipShape(TamrinCard.shape)
        // Keep the switcher's visual structure in place throughout the flight;
        // only its interaction waits for the geometry transition to finish.
        .allowsHitTesting(interactionEnabled)

        if let transitionSource, let transitionNamespace {
            card
                .matchedGeometryEffect(
                    id: LineupZoomSource.card(transitionSource),
                    in: transitionNamespace,
                    properties: .frame,
                    anchor: .center,
                    // This one surface remains visible for the whole flight.
                    // Swapping geometry ownership moves it out and home without
                    // a source/target opacity crossfade midway through either.
                    isSource: heroExpanded
                )
                .zIndex(10)
        } else {
            card
        }
    }

    /// The other side takes this one's place without changing the card frame.
    private func switchSide() {
        Haptics.selection()
        withAnimation(.easeInOut(duration: 0.32)) {
            side = side.other
        }
    }

    /// Reads the saved split against today's roster, the same way the exercise
    /// page does — so a player who left is gone from both at once.
    private func reload() async {
        let plan = await LineupStore.load(eventID: occurrence.id)
        positions = sportStyle.usesFootballFeatures
            ? LineupStore.positions(for: occurrence.id)
            : LineupPositions()
        guard let plan else { return }
        teams = plan.resolve(
            against: feed.lineupCandidates(
                for: occurrence,
                usesFootballPositions: sportStyle.usesFootballFeatures
            )
        ).teams
    }

    /// The same per-exercise position the editor offers, reachable from the
    /// list here too — this is where the organizer is actually looking when he
    /// decides someone is playing at the back tonight.
    private func choosePosition(_ position: PlayerPosition, for playerID: UUID) {
        positions.set(position, for: playerID)
        LineupStore.savePositions(positions, eventID: occurrence.id)
        apply(position, overridden: true, for: playerID)
    }

    private func resetPosition(for playerID: UUID) {
        positions.clear(playerID)
        LineupStore.savePositions(positions, eventID: occurrence.id)
        let profilePosition = feed.lineupCandidates(
            for: occurrence,
            usesFootballPositions: true
        )
            .first { $0.id == playerID }?
            .position ?? .midfielder
        apply(profilePosition, overridden: false, for: playerID)
    }

    @ViewBuilder
    private func playerListRow(_ player: LineupPlayer) -> some View {
        if sportStyle.usesFootballFeatures {
            MemberRowCard(
                name: player.name,
                avatarImageUrl: player.avatarUrl
            ) {
                LineupRowTag(
                    row: player.row,
                    onChoose: { choosePosition($0, for: player.id) },
                    onReset: player.isPositionOverridden
                        ? { resetPosition(for: player.id) }
                        : nil
                )
            }
            .accessibilityElement(children: .combine)
        } else {
            MemberRowCard(
                name: player.name,
                avatarImageUrl: player.avatarUrl
            )
            .accessibilityElement(children: .combine)
        }
    }

    private func apply(_ position: PlayerPosition, overridden: Bool, for playerID: UUID) {
        Haptics.selection()
        withAnimation(.snappy(duration: 0.28)) {
            teams.setPosition(position, overridden: overridden, for: playerID)
        }
    }

    private func closePage() {
        if let onRequestClose {
            // The matched id always belongs to the card that launched this
            // page. If the organizer switched teams, restore that card's
            // content in the same transaction before it flies home, avoiding
            // a different team's face landing in the original source slot.
            if let transitionSource, side != transitionSource {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    side = transitionSource
                }
            }
            onRequestClose()
        } else {
            dismiss()
        }
    }

    /// Close on the leading edge, edit on the trailing one — the reverse of the
    /// editor's bar, because here the way out is the ordinary thing to press.
    private var topBar: some View {
        ZStack {
            Text("التشكيلة")
                .font(TamrinFont.font(size: 17, weight: .bold))
                .foregroundStyle(.white)

            HStack {
                Button {
                    closePage()
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

                Spacer(minLength: 0)

                // Sized like the bar button iOS puts in the same corner — the
                // Clock's «تعديل» — rather than a small pill: the system's
                // 17pt bar-button text, and enough width around it that the
                // capsule reads as a sibling of the circle across from it.
                if feed.isCurrentTeamOwner {
                    Button {
                        showEditor = true
                    } label: {
                        Text("تعديل")
                            .font(TamrinFont.font(size: 17, weight: .medium))
                            // Five points on each side on top of the style's
                            // own insets is what lands the capsule on the width
                            // iOS gives the same word in its own bar.
                            .padding(.horizontal, 5)
                            .frame(height: TamrinControlMetrics.glassIconContent)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .accessibilityHint("يفتح تعديل التشكيلة وتبديل اللاعبين")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .walletDetailVisibility(
            detailsVisible,
            enabled: usesWalletTransition
        )
        .allowsHitTesting(interactionEnabled)
    }
}

private extension View {
    /// Detail rows in Wallet resolve from a soft, slightly lowered copy while
    /// the selected card finishes its travel. Keeping this as render-only work
    /// means the page has its final layout throughout the geometry transition.
    func walletDetailVisibility(_ visible: Bool, enabled: Bool) -> some View {
        opacity(!enabled || visible ? 1 : 0)
            .blur(radius: enabled && !visible ? 10 : 0)
            .offset(y: enabled && !visible ? 18 : 0)
            .allowsHitTesting(!enabled || visible)
            .accessibilityHidden(enabled && !visible)
    }
}
