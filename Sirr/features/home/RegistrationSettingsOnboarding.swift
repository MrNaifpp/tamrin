//
//  RegistrationSettingsOnboarding.swift
//  Sirr
//
//  The registration settings, introduced once to the organizer the first time
//  they open a workout of their own. Members never see it: none of it is
//  theirs to change.
//

import SwiftUI

enum RegistrationSettingsOnboarding {
    private static let key = "registration-settings.onboarding.seen"

    static var hasSeen: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markSeen() { UserDefaults.standard.set(true, forKey: key) }
}

struct RegistrationSettingsOnboardingSheet: View {
    let onDone: () -> Void

    var body: some View {
        RegistrationOnboardingPager(steps: Self.steps) {
            RegistrationSettingsOnboarding.markSeen()
            onDone()
        }
    }

    private static let steps: [RegistrationOnboardingCard] = [
        RegistrationOnboardingCard(
            title: String(localized: "ميزة جديدة، إعدادات التسجيل ✨"),
            body: String(localized: "تتحكم كيف يسجّل اللاعبين في تمرينك."),
            symbol: "slider.horizontal.3"
        ),
        RegistrationOnboardingCard(
            title: String(localized: "وقت فتح التسجيل"),
            body: String(localized: "حدد قبل كم يوم وفي أي ساعة يفتح التسجيل."),
            symbol: "calendar.badge.clock"
        ),
        RegistrationOnboardingCard(
            title: String(localized: "الموافقة والضيوف"),
            body: String(localized: "وافق على كل طلب بنفسك، وشغّل أو أوقف الضيوف."),
            symbol: "person.crop.circle.badge.checkmark"
        )
    ]
}

/// The same blue the rating cards move forward on, so the two read alike.
private let registrationForward = Color(red: 0.20, green: 0.47, blue: 0.96)

struct RegistrationOnboardingCard {
    let title: String
    let body: String
    let symbol: String
}

/// The cards, paged by the system so a swipe moves between them: a title, a
/// line, a symbol, and next / skip. The caller marks the feature as seen in `onFinish`,
/// which runs on skip and on the last card alike.
struct RegistrationOnboardingPager: View {
    let steps: [RegistrationOnboardingCard]
    let onFinish: () -> Void

    @State private var step = 0

    private var isLast: Bool { step == steps.count - 1 }

    var body: some View {
        NavigationStack {
            // The system pager, so a swipe moves between cards; «التالي»
            // moves the same selection.
            TabView(selection: $step) {
                ForEach(steps.indices, id: \.self) { index in
                    page(steps[index]).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .safeAreaInset(edge: .bottom) { controls }
            .background(TamrinTheme.page.ignoresSafeArea())
            .toolbar {
                // A way out that is not the last page. Marked as seen either
                // way: skipping is a decision about this screen, and showing it
                // again would read as the app not having listened.
                if !isLast {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("تخطٍ") { finish() }
                    }
                }
            }
        }
        .environment(\.layoutDirection, .tamrin)
        .environment(\.colorScheme, .dark)
    }

    private func page(_ card: RegistrationOnboardingCard) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 12) {
                    Text(card.title)
                        .font(TamrinFont.font(size: 27, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        // One line, shrinking to fit rather than wrapping. A
                        // title that wraps drops its last word — here the
                        // emoji — onto a line of its own, which reads as a
                        // mistake rather than as a second line.
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    Text(card.body)
                        .font(TamrinFont.font(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.66))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
                .padding(.horizontal, 28)

                Spacer(minLength: 0)

                Image(systemName: card.symbol)
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(registrationForward)
                    .frame(width: 140, height: 140)
                    .background(registrationForward.opacity(0.18), in: .circle)
                    .frame(height: proxy.size.height * 0.50)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            progress

            Button {
                if isLast {
                    finish()
                } else {
                    Haptics.impact(.light)
                    withAnimation(.smooth(duration: 0.4)) { step += 1 }
                }
            } label: {
                Text(isLast ? String(localized: "تم") : String(localized: "التالي"))
                    .font(TamrinFont.font(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(registrationForward, in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background {
            // Keeps the controls readable over the page.
            LinearGradient(
                colors: [TamrinTheme.page.opacity(0), TamrinTheme.page],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private func finish() {
        onFinish()
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { index in
                Capsule()
                    .fill(index == step ? registrationForward : .white.opacity(0.18))
                    .frame(width: index == step ? 20 : 6, height: 6)
            }
        }
        .animation(.snappy(duration: 0.3), value: step)
        .accessibilityHidden(true)
    }
}

