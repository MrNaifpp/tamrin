import SwiftUI

/// The man-of-the-match walkout, in the spirit of a FIFA pack: the map closes
/// in on the winner's region, then his position, then his rating. The stadium
/// lights stutter on around a dark card back, which rises, flashes and flips.
///
/// Every layer is a pure function of the elapsed time, so skipping, replaying
/// and Reduce Motion are just a different starting time.
/// The one control the walkout shows at a time: a way past it while it runs,
/// and a replay once it has landed.
private enum WalkoutControl { case skip, replay }

struct MatchAwardWalkoutView: View {
    let player: MatchAwardPlayer
    let stats: MatchAwardPlayerStats
    var workspaceID: UUID?
    var isDemo = false
    /// Starts on the final frame, for a result already watched.
    var startsRevealed = false
    var onRevealed: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hasVerticalBar) private var hasVerticalBar
    @State private var start = Date.distantFuture
    @State private var run = 0
    /// Which control the toolbar carries on iPhone Duo's cover screen.
    @State private var barControl: WalkoutControl?

    private var timeline: WalkoutTimeline { WalkoutTimeline(hasMap: SaudiRegionMap.shared.region(player.regionId) != nil) }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                let t = max(0, context.date.timeIntervalSince(start))
                scene(t: t, size: proxy.size)
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            if !hasVerticalBar { controls }
        }
        // On iPhone Duo's cover screen the floating control would sit under
        // the camera, so it moves to the flow's toolbar and the system places
        // it in its vertical bar.
        .toolbar {
            if hasVerticalBar, let barControl {
                ToolbarItem(placement: .primaryAction) {
                    if barControl == .skip { skipButton } else { replayButton }
                }
            }
        }
        .task(id: hasVerticalBar ? start : nil) { await followBarControl() }
        .task(id: run) { await play() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "رجل المباراة: \(player.name)"))
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Playback

    private func play() async {
        let line = timeline
        if startsRevealed && run == 0 || reduceMotion {
            start = Date.now.addingTimeInterval(-line.end)
            onRevealed()
            return
        }
        start = .now
        // Haptics follow the picture: a thud per beat, a clunk per light bank,
        // a heartbeat under the rising card, a burst on the flip.
        var beats: [(Double, () -> Void)] = []
        if line.hasMap {
            beats.append((line.mapZoomEnd - 0.1, { Haptics.impact(.soft, intensity: 0.7) }))
        }
        beats.append((line.positionStart + 0.1, { Haptics.impact(.medium, intensity: 0.8) }))
        beats.append((line.ratingStart + 0.15, { Haptics.impact(.heavy) }))
        for (index, edge) in WalkoutTimeline.bankEdges.enumerated() {
            let intensity = 0.4 + 0.6 * Double(index) / Double(WalkoutTimeline.bankEdges.count)
            beats.append((line.lightsStart + edge, { Haptics.drumRollPulse(intensity: intensity) }))
        }
        var beat = line.backIn + 0.3
        var gap = 0.5
        while beat < line.cardStart - 0.1 {
            let k = (beat - line.backIn) / (line.cardStart - line.backIn)
            beats.append((beat, { Haptics.drumRollPulse(intensity: 0.5 + 0.5 * k) }))
            beat += gap
            gap = max(0.12, gap * 0.78)
        }
        beats.append((line.cardStart, { Haptics.impact(.heavy) }))
        beats.append((line.cardStart + 0.3, { Haptics.success() }))
        for (time, beat) in beats.sorted(by: { $0.0 < $1.0 }) {
            let wait = time - Date.now.timeIntervalSince(start)
            if wait > 0 {
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            }
            beat()
        }
        let settle = line.settled - Date.now.timeIntervalSince(start)
        if settle > 0 { try? await Task.sleep(for: .seconds(settle)) }
        if !Task.isCancelled { onRevealed() }
    }

    @ViewBuilder
    private var controls: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let t = context.date.timeIntervalSince(start)
            Group {
                if t < timeline.cardStart {
                    skipButton
                } else if t > timeline.settled {
                    replayButton
                }
            }
            .font(TamrinFont.font(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .buttonStyle(.glass)
            .padding(.trailing, 20)
            .padding(.top, 8)
            .animation(.smooth, value: t > timeline.settled)
        }
        .environment(\.layoutDirection, .tamrin)
    }

    private var skipButton: some View {
        Button("تخطي") { start = Date.now.addingTimeInterval(-timeline.cardStart + 0.05) }
    }

    private var replayButton: some View {
        Button("إعادة", systemImage: "arrow.counterclockwise") { run += 1 }
            .labelStyle(.iconOnly)
            .accessibilityLabel("إعادة العرض")
    }

    /// The same four-times-a-second check the floating control makes, kept
    /// as state so the toolbar changes only when the control does.
    private func followBarControl() async {
        guard hasVerticalBar else {
            barControl = nil
            return
        }
        while !Task.isCancelled {
            let t = Date.now.timeIntervalSince(start)
            let control: WalkoutControl? = t < timeline.cardStart ? .skip
                : t > timeline.settled ? .replay : nil
            if control != barControl {
                withAnimation(.smooth) { barControl = control }
            }
            do { try await Task.sleep(for: .seconds(0.25)) } catch { return }
        }
    }

    // MARK: - The scene

    @ViewBuilder
    private func scene(t: Double, size: CGSize) -> some View {
        let line = timeline
        let layout = WalkoutLayout(size: size)
        ZStack {
            stage(t: t, size: size, line: line, layout: layout)
            if line.hasMap, t < line.mapEnd { map(t: t, size: size, line: line) }
            word(PlayerCardView.positionTitle(player.position), t: t,
                 range: (line.positionStart, line.positionEnterEnd, line.positionExitStart, line.positionEnd),
                 fontSize: min(120, size.width * 0.3))
            rating(t: t, line: line, size: size)
            floodlights(t: t, size: size, line: line, layout: layout)
            if t >= line.backIn { card(t: t, size: size, line: line, layout: layout) }
            flash(t: t, line: line)
        }
        .frame(width: size.width, height: size.height)
        .background(Color(white: 0.035))
    }

    /// A dark, neutral stage. Light only arrives with the floodlights, and the
    /// one colour on screen is the card's green.
    private func stage(t: Double, size: CGSize, line: WalkoutTimeline, layout: WalkoutLayout) -> some View {
        let lit = WalkoutTimeline.brightness(at: t - line.lightsStart)
        let landed = Ease.smooth(between(t, line.cardStart, line.cardEnd))
        return ZStack {
            // The pool of light on the floor under the card.
            Ellipse()
                .fill(RadialGradient(colors: [.white.opacity(0.10 * lit), .clear],
                                     center: .center, startRadius: 0, endRadius: size.width * 0.55))
                .frame(width: size.width * 1.3, height: 120)
                .position(x: size.width / 2, y: layout.cardBottom + 24)
            Circle()
                .fill(RadialGradient(colors: [MatchAwardCardView.green.opacity(0.22 * landed), .clear],
                                     center: .center, startRadius: 0, endRadius: layout.cardHeight * 0.75))
                .frame(width: layout.cardHeight * 1.5, height: layout.cardHeight * 1.5)
                .position(x: size.width / 2, y: layout.cardCenterY)
        }
        .allowsHitTesting(false)
    }

    // MARK: Map

    private func map(t: Double, size: CGSize, line: WalkoutTimeline) -> some View {
        let shared = SaudiRegionMap.shared
        let region = shared.region(player.regionId)!
        let appear = Ease.out(between(t, line.mapIn, line.mapIn + 0.9))
        let zoom = Ease.zoom(between(t, line.mapZoomStart, line.mapZoomEnd))
        let dissolve = Ease.smooth(between(t, line.mapOutStart, line.mapEnd))
        let canvas = CGSize(width: size.width, height: size.height * 0.6)
        let wide = SaudiRegionMap.camera(fitting: shared.countryBounds, in: canvas, fill: 0.88)
        let close = SaudiRegionMap.camera(fitting: region.bounds, in: canvas, fill: 0.72)
        // Interpolate in screen space so the region travels straight to the middle.
        let scale = lerp(wide.scale, close.scale, zoom)
        let center = CGPoint(x: lerp(wide.center.x * wide.scale, close.center.x * close.scale, zoom) / scale,
                             y: lerp(wide.center.y * wide.scale, close.center.y * close.scale, zoom) / scale)
        let others = shared.regions.filter { $0.id != region.id }.flatMap(\.rings)
        let labelIn = Ease.out(between(t, line.labelIn, line.labelIn + 0.5))

        return ZStack {
            ZStack {
                MapRingsShape(rings: shared.country, center: center, scale: scale)
                    .fill(.white.opacity(0.07))
                MapRingsShape(rings: others, center: center, scale: scale)
                    .stroke(.white.opacity(0.16 * (1 - zoom * 0.5)), lineWidth: 0.7)
                MapRingsShape(rings: region.rings, center: center, scale: scale)
                    .fill(.white.opacity(0.2 + 0.72 * zoom))
                    .shadow(color: .white.opacity(0.35 * zoom), radius: 24)
            }
            .frame(width: canvas.width, height: canvas.height)
            .scaleEffect(lerp(0.96, 1, appear) * (1 + 0.06 * dissolve))
            .blur(radius: lerp(10, 0, appear) + dissolve * 12)
            .opacity(appear * (1 - dissolve))
            .offset(y: -size.height * 0.07)

            Text(region.label)
                .font(TamrinFont.font(size: min(56, size.width * 0.14), weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.5)
                .padding(.horizontal, 24)
                .offset(y: size.height * 0.29 + lerp(14, 0, labelIn))
                .blur(radius: lerp(6, 0, labelIn))
                .opacity(labelIn * (1 - dissolve))
                .environment(\.layoutDirection, .tamrin)

            Text("© OpenStreetMap")
                .font(TamrinFont.font(size: 9, weight: .regular))
                .foregroundStyle(.white.opacity(0.25 * appear * (1 - dissolve)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 16).padding(.bottom, 40)
        }
        .allowsHitTesting(false)
    }

    // MARK: Position and rating

    private func word(_ text: String, t: Double, range: (Double, Double, Double, Double), fontSize: CGFloat) -> some View {
        let enter = Ease.out(between(t, range.0, range.1))
        let exit = Ease.smooth(between(t, range.2, range.3))
        return Text(text)
            .font(TamrinFont.font(size: fontSize, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.4)
            .padding(.horizontal, 24)
            .scaleEffect(lerp(0.92, 1, enter) * (1 + 0.05 * exit))
            .blur(radius: lerp(8, 0, enter) + exit * 10)
            .offset(y: lerp(16, 0, enter))
            .opacity(enter * (1 - exit))
            .compositingGroup()
            .allowsHitTesting(false)
    }

    private func rating(t: Double, line: WalkoutTimeline, size: CGSize) -> some View {
        let enter = between(t, line.ratingStart, line.ratingEnterEnd)
        let exit = Ease.smooth(between(t, line.ratingExitStart, line.ratingEnd))
        let scale = enter < 0.78 ? lerp(0.86, 1.03, Ease.out(enter / 0.78)) : lerp(1.03, 1, Ease.smooth((enter - 0.78) / 0.22))
        // The number rolls up into place, the way a pack rolls its rating.
        let shown = Int(lerp(Double(max(40, stats.overall - 25)), Double(stats.overall), Ease.out(min(1, enter * 1.25))).rounded())
        return Text(stats.isKnown ? shown.tamrinNumber : "—")
            .font(TamrinFont.font(size: min(220, size.width * 0.55), weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .shadow(color: .white.opacity(0.25 * Ease.out(enter)), radius: 30)
            .scaleEffect(scale * (1 + 0.05 * exit))
            .blur(radius: exit * 12)
            .opacity(Ease.out(enter) * (1 - exit))
            .allowsHitTesting(false)
    }

    // MARK: Floodlights

    /// Four banks of light outside the top of the screen. Nothing is drawn
    /// of the fixtures themselves: you see their beams cut through the dark
    /// and a flare where they enter the frame.
    private func floodlights(t: Double, size: CGSize, line: WalkoutTimeline, layout: WalkoutLayout) -> some View {
        let local = t - line.lightsStart
        let settle = Ease.smooth(between(t, line.cardEnd, line.settled))
        let banks: [CGFloat] = [-0.08, 0.22, 0.78, 1.08]
        return ZStack {
            ForEach(banks.indices, id: \.self) { index in
                let level = WalkoutTimeline.bank(index, at: local)
                let source = CGPoint(x: size.width * banks[index], y: -30)
                let sway = sin(t * 0.7 + Double(index) * 1.3) * 10
                let target = CGPoint(x: size.width / 2 + sway, y: layout.cardBottom + 30)
                LightBeam(from: source, to: target, spread: size.width * 0.62)
                    .fill(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.10), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .blur(radius: 22)
                    .blendMode(.plusLighter)
                    .opacity(level * (1 - 0.6 * settle))
                // The flare where the beam enters the frame.
                Circle()
                    .fill(RadialGradient(colors: [.white, .white.opacity(0.35), .clear],
                                         center: .center, startRadius: 0, endRadius: 70))
                    .frame(width: 140, height: 140)
                    .position(x: min(max(source.x, 10), size.width - 10), y: 0)
                    .blendMode(.plusLighter)
                    .opacity(level * (1 - 0.5 * settle))
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    // MARK: The card

    private func card(t: Double, size: CGSize, line: WalkoutTimeline, layout: WalkoutLayout) -> some View {
        // The back fades in under the lights and rises while the heartbeat quickens.
        let backIn = Ease.out(between(t, line.backIn, line.backIn + 0.8))
        let rise = Ease.smooth(between(t, line.backIn, line.cardStart))
        let charge = pow(between(t, line.backIn + 0.6, line.cardStart), 2)
        // Then the flip: half a turn, the face takes over at 90°.
        let flip = Ease.out(between(t, line.cardStart, line.cardStart + 0.65))
        let angle = flip * 180
        let land = between(t, line.cardStart, line.cardEnd)
        let pop = land < 0.55 ? lerp(1, 1.07, Ease.out(land / 0.55)) : lerp(1.07, 1, Ease.smooth((land - 0.55) / 0.45))
        let since = t - line.cardStart
        let titleIn = Ease.out(between(t, line.cardEnd - 0.2, line.settled))
        let w = layout.cardWidth, h = layout.cardHeight

        return ZStack {
            // The shockwave on the flip.
            Circle()
                .stroke(.white.opacity(0.55 * (1 - Ease.out(between(since, 0, 0.8)))), lineWidth: 2)
                .frame(width: w, height: w)
                .scaleEffect(lerp(0.5, 3, Ease.out(between(since, 0, 0.8))))
                .position(x: size.width / 2, y: layout.cardCenterY)
                .opacity(since >= 0 ? 1 : 0)

            SparkBurst(time: since, origin: CGPoint(x: size.width / 2, y: layout.cardCenterY))
                .frame(width: size.width, height: size.height)

            VStack(spacing: 6) {
                Text("رجل المباراة")
                    .font(TamrinFont.font(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                if let region = SaudiRegionMap.label(for: player.regionId) {
                    Text(region)
                        .font(TamrinFont.font(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .opacity(titleIn)
            .offset(y: lerp(8, 0, titleIn))
            .position(x: size.width / 2, y: layout.titleY)
            .environment(\.layoutDirection, .tamrin)

            ZStack {
                if angle < 90 {
                    CardBack(charge: charge)
                        .frame(width: w, height: h)
                } else {
                    MatchAwardPlayerCard(player: player, workspaceID: workspaceID, isDemo: isDemo, style: .award)
                        .frame(width: w, height: h)
                        .modifier(CardFloat(t: since, active: land >= 1))
                        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                }
            }
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .scaleEffect(lerp(0.78, 1, rise) * pop)
            .offset(y: lerp(70, 0, rise))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
            .opacity(backIn)
            .position(x: size.width / 2, y: layout.cardCenterY)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func flash(t: Double, line: WalkoutTimeline) -> some View {
        // A soft pop on every light bank, and one bright flash on the flip.
        let local = t - line.lightsStart
        let bankPops = WalkoutTimeline.bankEdges.reduce(0.0) { sum, edge in
            let d = local - edge
            return d >= 0 && d < 0.2 ? sum + 0.08 * (1 - d / 0.2) : sum
        }
        let d = t - line.cardStart
        let cardFlash = d >= 0 && d < 0.6 ? 0.85 * pow(1 - d / 0.6, 2) : 0
        return Color.white.opacity(min(1, bankPops + cardFlash))
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }
}

// MARK: - Timeline

struct WalkoutTimeline {
    let hasMap: Bool

    let mapIn = 0.5
    let mapZoomStart = 1.5
    let mapZoomEnd = 3.6
    let labelIn = 3.2
    let mapOutStart = 4.7
    let mapEnd = 5.2

    private var base: Double { hasMap ? 5.2 : 0.8 }
    var positionStart: Double { base }
    var positionEnterEnd: Double { base + 0.45 }
    var positionExitStart: Double { base + 1.15 }
    var positionEnd: Double { base + 1.5 }
    var ratingStart: Double { base + 1.5 }
    var ratingEnterEnd: Double { base + 2.1 }
    var ratingExitStart: Double { base + 2.8 }
    var ratingEnd: Double { base + 3.2 }
    var lightsStart: Double { base + 3.4 }
    /// The card back appears once the first banks are holding.
    var backIn: Double { lightsStart + 1.7 }
    var cardStart: Double { lightsStart + 3.9 }
    var cardEnd: Double { cardStart + 0.95 }
    var settled: Double { cardStart + 1.5 }
    var end: Double { settled + 0.2 }

    /// When each bank is lit, relative to `lightsStart`: they stutter like
    /// lamps warming up, quicker each time, then hold from about 2s.
    static let bankIntervals: [[ClosedRange<Double>]] = [
        [0.15...0.24, 0.70...0.76, 1.15...1.20, 1.50...99],
        [0.40...0.48, 0.92...0.97, 1.32...1.36, 1.70...99],
        [0.28...0.35, 0.82...0.87, 1.24...1.28, 1.62...99],
        [0.55...0.62, 1.04...1.09, 1.42...1.46, 1.85...99],
    ]

    static let bankEdges: [Double] = bankIntervals.flatMap { $0.map(\.lowerBound) }.sorted()

    /// 0 or 1 with a short ramp, so a lamp catches rather than blinks.
    static func bank(_ index: Int, at local: Double) -> Double {
        for range in bankIntervals[index] where range.contains(local) {
            let lit = min(1, (local - range.lowerBound) / 0.04)
            let fade = range.upperBound > 50 ? 1 : min(1, (range.upperBound - local) / 0.03)
            return max(0, min(lit, fade))
        }
        return 0
    }

    static func brightness(at local: Double) -> Double {
        (0..<4).map { bank($0, at: local) }.reduce(0, +) / 4
    }
}

// MARK: - Layout

/// Full-screen geometry: the card sits in the upper middle and the bottom is
/// kept clear for the cheers that arrive once it has landed.
private struct WalkoutLayout {
    let size: CGSize
    private var top: CGFloat { 150 }
    private var bottomReserve: CGFloat { 190 }
    var cardHeight: CGFloat {
        min(size.height - top - bottomReserve, size.width * 0.78 / MatchAwardCardView.aspectRatio)
    }
    var cardWidth: CGFloat { cardHeight * MatchAwardCardView.aspectRatio }
    var cardCenterY: CGFloat { top + (size.height - top - bottomReserve) / 2 }
    var cardBottom: CGFloat { cardCenterY + cardHeight / 2 }
    var titleY: CGFloat { cardCenterY - cardHeight / 2 - 34 }
}

// MARK: - Pieces

/// The back of the card: dark glass, a thin rim that catches the light, and
/// the trophy, glowing harder as the reveal gets closer.
private struct CardBack: View {
    let charge: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(white: 0.14), Color(white: 0.06)],
                                      startPoint: .top, endPoint: .bottom))
            shape.fill(RadialGradient(colors: [MatchAwardCardView.green.opacity(0.15 + 0.55 * charge), .clear],
                                      center: .center, startRadius: 0, endRadius: 160))
            MatchAwardArrow()
                .fill(.white.opacity(0.05 + 0.1 * charge))
                .frame(width: 120, height: 120)
                .offset(y: -10)
            Image(systemName: "trophy.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35 + 0.65 * charge))
                .shadow(color: MatchAwardCardView.green.opacity(charge), radius: 18)
                .offset(y: 30)
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5 + 0.5 * charge), .white.opacity(0.06)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
        }
        .shadow(color: MatchAwardCardView.green.opacity(0.6 * charge), radius: 40 * charge)
        .accessibilityHidden(true)
    }
}

private struct LightBeam: Shape {
    let from: CGPoint
    let to: CGPoint
    let spread: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: from.x - 14, y: from.y))
        path.addLine(to: CGPoint(x: from.x + 14, y: from.y))
        path.addLine(to: CGPoint(x: to.x + spread / 2, y: to.y))
        path.addLine(to: CGPoint(x: to.x - spread / 2, y: to.y))
        path.closeSubpath()
        return path
    }
}

/// A short burst of sparks from the flip, falling as they fade.
private struct SparkBurst: View {
    let time: Double
    let origin: CGPoint

    var body: some View {
        Canvas { context, _ in
            guard time >= 0, time < 1.8 else { return }
            for i in 0..<36 {
                let seed = Double(i)
                let angle = seed * 2.39996
                let speed = 140 + (seed * 37).truncatingRemainder(dividingBy: 200)
                let x = origin.x + cos(angle) * speed * time
                let y = origin.y + sin(angle) * speed * time + 120 * time * time
                let life = 1 - time / (1.0 + Double(i % 4) * 0.2)
                guard life > 0 else { continue }
                let dot = 1.5 + Double(i % 3)
                var spark = context
                spark.opacity = life
                let color: Color = i % 4 == 0 ? MatchAwardCardView.green : .white
                spark.fill(Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot)), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// After it lands, the card breathes: a slow tilt and a passing sheen.
private struct CardFloat: ViewModifier {
    let t: Double
    let active: Bool

    func body(content: Content) -> some View {
        let k = active ? 1.0 : 0.0
        let sweep = (t * 0.35).truncatingRemainder(dividingBy: 2.2)
        content
            .overlay {
                LinearGradient(colors: [.clear, .white.opacity(0.18), .clear],
                               startPoint: UnitPoint(x: -0.6 + sweep, y: 0),
                               endPoint: UnitPoint(x: sweep, y: 1))
                    .blendMode(.plusLighter)
                    .mask(content)
                    .opacity(k)
            }
            .rotation3DEffect(.degrees(sin(t * 0.8) * 2.5 * k), axis: (x: 1, y: 0, z: 0), perspective: 0.35)
            .rotation3DEffect(.degrees(sin(t * 0.55) * 3.5 * k), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
            .offset(y: sin(t * 1.1) * 3 * k)
    }
}

// MARK: - Math

private func between(_ t: Double, _ a: Double, _ b: Double) -> Double { min(1, max(0, (t - a) / max(b - a, 0.0001))) }
private func lerp(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }

private enum Ease {
    static func out(_ t: Double) -> Double { 1 - pow(1 - min(1, max(0, t)), 4) }
    static func smooth(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }
    /// Slow to leave, then rushing in, then settling: a camera diving onto a spot.
    static func zoom(_ t: Double) -> Double { smooth(pow(min(1, max(0, t)), 3)) }
}
