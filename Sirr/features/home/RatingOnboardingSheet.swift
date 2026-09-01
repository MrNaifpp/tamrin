//
//  RatingOnboardingSheet.swift
//  Sirr
//
//  What to know before you rate anyone, in three cards over the whole screen.
//
//  Rating is the one feature here where a wrong mental model produces wrong
//  data rather than a confused user: someone who thinks his score is published
//  rates politely, and someone who thinks he is judging against professionals
//  rates everyone in the thirties. Neither can be corrected afterwards — the
//  numbers are already in the average. So this is shown once, before the first
//  rating, rather than left to be worked out.
//

import AVFoundation
import SwiftUI

/// The colour the rating flow moves forward on. Repeated here so the two read
/// as one feature rather than two screens that happen to follow each other.
private let ratingForward = Color(red: 0.20, green: 0.47, blue: 0.96)

enum RatingOnboarding {
    private static let key = "rating.onboarding.seen"

    static var hasSeen: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markSeen() { UserDefaults.standard.set(true, forKey: key) }
}

struct RatingOnboardingSheet: View {
    let onDone: () -> Void

    @State private var step = 0

    private static let steps: [RatingOnboardingStep] = [
        RatingOnboardingStep(
            title: "ميزة جديدة، تقييم اللاعبين ✨",
            body: "الآن يمديك تقييم اللاعبين اللي معك في التمرين.",
            art: .film
        ),
        RatingOnboardingStep(
            title: "تقييمك مستور 👀",
            body: "ما يظهر لك من اللي قيّموك، ولا يظهر لهم من قيّمهم.",
            art: .symbol("eye.slash.fill")
        ),
        RatingOnboardingStep(
            title: "المقياس تمرينكم",
            body: "لا تقارن باللاعبين العالميين، قارن بتمرينكم.",
            art: .symbol("figure.soccer")
        )
    ]

    private var current: RatingOnboardingStep { Self.steps[step] }
    private var isLast: Bool { step == Self.steps.count - 1 }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                skipRow

                Spacer(minLength: 0)

                VStack(spacing: 12) {
                    Text(current.title)
                        .font(TamrinFont.font(size: 27, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        // One line, shrinking to fit rather than wrapping. A
                        // title that wraps drops its last word — here the
                        // emoji — onto a line of its own, which reads as a
                        // mistake rather than as a second line.
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    Text(current.body)
                        .font(TamrinFont.font(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.66))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
                .id(step)
                .transition(.blurReplace)
                .padding(.horizontal, 28)

                Spacer(minLength: 0)

                // The band belongs to the art. The first card spends it
                // on the feature actually running — a rater who has seen the
                // ruler move needs less convincing about it than any sentence
                // could manage.
                RatingOnboardingArtView(art: current.art)
                    .frame(height: proxy.size.height * 0.50)
                    .frame(maxWidth: .infinity)
                    .id(current.art)
                    .transition(.blurReplace)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 16) {
                // With the button rather than above the film: the two are the
                // controls of this page, and splitting them put a row of dots
                // in the middle of the picture.
                progress

                Button {
                if isLast {
                    finish()
                } else {
                    Haptics.impact(.light)
                    withAnimation(.smooth(duration: 0.4)) { step += 1 }
                }
            } label: {
                // «تم», not «ابدأ التقييم»: this now opens on launch rather
                // than from a rate button, so the last card ends the
                // announcement instead of handing over to anything.
                Text(isLast ? "تم" : "التالي")
                    .font(TamrinFont.font(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(ratingForward, in: .capsule)
            }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .background {
                // The film runs behind this, so the controls need the page
                // under them to stay readable.
                LinearGradient(
                    colors: [TamrinTheme.page.opacity(0), TamrinTheme.page],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
        .background(TamrinTheme.page.ignoresSafeArea())
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.colorScheme, .dark)
    }

    /// A way out that is not the last page. Marked as seen either way: skipping
    /// is a decision about this screen, and showing it again would read as the
    /// app not having listened.
    private var skipRow: some View {
        HStack {
            Spacer(minLength: 0)
            Button("تخطٍ") { finish() }
                .font(TamrinFont.font(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .opacity(isLast ? 0 : 1)
                .disabled(isLast)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .animation(.smooth(duration: 0.25), value: isLast)
    }

    private func finish() {
        RatingOnboarding.markSeen()
        onDone()
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Self.steps.indices, id: \.self) { index in
                Capsule()
                    .fill(index == step ? ratingForward : .white.opacity(0.18))
                    .frame(width: index == step ? 20 : 6, height: 6)
            }
        }
        .animation(.snappy(duration: 0.3), value: step)
        .accessibilityHidden(true)
    }
}

private struct RatingOnboardingStep {
    let title: String
    let body: String
    let art: RatingOnboardingArt
}

private enum RatingOnboardingArt: Hashable {
    /// The recording of the rating flow, from `FeatureMedia/`.
    case film
    case symbol(String)
}

private struct RatingOnboardingArtView: View {
    let art: RatingOnboardingArt

    /// Nil when the clip is missing from the bundle, which falls back to the
    /// drawn badge rather than leaving a hole in the page.
    private static let filmURL: URL? = {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("FeatureMedia/rating-onboarding.mov")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    var body: some View {
        switch art {
        case .film:
            if let url = Self.filmURL {
                // Full width, and whatever that leaves over the band's height
                // runs off the top and bottom. The clip is already framed on
                // what it wants to show, so nothing tracks it any more — but it
                // still needs to stop somewhere, and a hard edge would read as
                // a cropped video where a fade reads as a window onto one.
                LoopingVideo(url: url)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.40),
                                .init(color: .black, location: 0.60),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            } else {
                badge(symbol: "star.fill")
            }
        case .symbol(let name):
            badge(symbol: name)
        }
    }

    private func badge(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 56, weight: .semibold))
            .foregroundStyle(ratingForward)
            .frame(width: 140, height: 140)
            .background(ratingForward.opacity(0.18), in: .circle)
    }
}

/// A clip that plays itself: muted, looping, no controls.
///
/// `AVPlayerLayer` rather than `VideoPlayer`, which brings transport controls
/// and a tap target — neither belongs on a page whose only two actions are
/// "next" and "skip".
private struct LoopingVideo: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LoopingVideoView { LoopingVideoView(url: url) }
    func updateUIView(_ uiView: LoopingVideoView, context: Context) {}
}

final class LoopingVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private let player = AVQueuePlayer()
    /// Held: the looper stops looping the moment it is released.
    private var looper: AVPlayerLooper?

    init(url: URL) {
        super.init(frame: .zero)
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        // Muted, but still declared as ambient so it does not stop whatever the
        // person was listening to.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)

        let playerLayer = layer as? AVPlayerLayer
        playerLayer?.player = player
        // Fill: the clip takes the band's full width and overflows its height,
        // which is what the fade above is there to finish.
        playerLayer?.videoGravity = .resizeAspectFill
        player.play()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
