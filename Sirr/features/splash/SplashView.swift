//
//  SplashView.swift
//  Sirr
//

import SwiftUI

struct SplashView: View {
    var onComplete: () -> Void = {}

    @State private var iconScale: CGFloat = 0.85
    @State private var haloScale: CGFloat = 0.85
    @State private var haloOpacity: Double = 0.0
    @State private var iconOpacity: Double = 0.0
    @State private var wordmarkOpacity: Double = 0.0

    private let pageBackground = Color(red: 248/255.0, green: 248/255.0, blue: 247/255.0)
    private let brandGreen = Color(red: 0.35, green: 0.72, blue: 0.45)

    var body: some View {
        ZStack {
            pageBackground
                .ignoresSafeArea()

            ZStack {
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: brandGreen.opacity(0.55), location: 0.0),
                        .init(color: brandGreen.opacity(0.25), location: 0.45),
                        .init(color: brandGreen.opacity(0.0),  location: 1.0)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: 180
                )
                .frame(width: 340, height: 340)
                .blur(radius: 18)
                .scaleEffect(haloScale)
                .opacity(haloOpacity)

                Image(systemName: "figure.run")
                    .font(.system(size: 92, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: brandGreen.opacity(0.35), radius: 12, x: 0, y: 6)
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)
            }

            VStack {
                Spacer()
                Text("تمريــن")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(white: 0.55))
                    .opacity(wordmarkOpacity)
                    .padding(.bottom, 48)
            }
            .ignoresSafeArea()
        }
        .environment(\.layoutDirection, .rightToLeft)
        .task {
            await runIntroSequence()
        }
    }

    @MainActor
    private func runIntroSequence() async {
        // 1. Fade + spring in to scale 1.0
        withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
            iconScale = 1.0
            haloScale = 1.0
            iconOpacity = 1.0
            haloOpacity = 1.0
            wordmarkOpacity = 1.0
        }
        try? await Task.sleep(nanoseconds: 700_000_000)

        // 2. Zoom out (shrink toward center)
        withAnimation(.easeInOut(duration: 0.45)) {
            iconScale = 0.65
            haloScale = 0.6
            haloOpacity = 0.7
        }
        try? await Task.sleep(nanoseconds: 450_000_000)

        // 3. Zoom in (burst outward) + fade — transitions into ContentView
        withAnimation(.easeIn(duration: 0.55)) {
            iconScale = 3.2
            haloScale = 3.8
            iconOpacity = 0.0
            haloOpacity = 0.0
            wordmarkOpacity = 0.0
        }
        try? await Task.sleep(nanoseconds: 500_000_000)

        onComplete()
    }
}

#Preview {
    SplashView()
}
