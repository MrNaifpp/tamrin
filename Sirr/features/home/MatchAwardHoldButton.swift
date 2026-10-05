import SwiftUI

/// A released or interrupted hold never submits. Accessibility uses an explicit
/// confirmation instead of requiring a precisely timed touch.
struct MatchAwardHoldButton: View {
    let title: String
    let disabled: Bool
    let isSaving: Bool
    let action: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var progress: CGFloat = 0
    @State private var hold = MatchAwardHoldController()
    @State private var touchActive = false
    @State private var confirmsAccessibleVote = false

    var body: some View {
        TamrinActionButton(title: touchActive ? String(localized: "استمر في الضغط") : title, isLoading: isSaving, prominent: false) {
            // Touch activation is handled by the hold. Assistive activation
            // opens an equivalent explicit confirmation.
            if UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning {
                confirmsAccessibleVote = true
            }
        }
        .disabled(disabled || isSaving)
        .overlay {
            GeometryReader { proxy in
                Rectangle()
                    .fill(.white.opacity(0.13))
                    .frame(width: proxy.size.width * progress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: AppLanguage.isArabic ? .trailing : .leading)
                    .contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard !disabled, !isSaving else { cancel(); return }
                            let bounds = CGRect(origin: .zero, size: proxy.size)
                            guard bounds.contains(value.location),
                                  hypot(value.translation.width, value.translation.height) < 30 else {
                                // Remain latched until release; sliding back in must not restart.
                                touchActive = true
                                cancelHold()
                                return
                            }
                            guard !touchActive else { return }
                            touchActive = true
                            beginHold()
                        }
                        .onEnded { _ in cancel() })
            }
            // Explicit physical coordinates: Arabic fills from the RIGHT edge,
            // English from the left. Only this decorative layer is pinned LTR.
            .environment(\.layoutDirection, .leftToRight)
            .clipShape(.capsule)
            .allowsHitTesting(!disabled && !isSaving)
            .accessibilityHidden(true)
        }
        .accessibilityLabel(title)
        .accessibilityHint("يفتح تأكيد التصويت لهذا اللاعب")
        .confirmationDialog("تأكيد التصويت لهذا اللاعب؟", isPresented: $confirmsAccessibleVote,
                            titleVisibility: .visible) {
            Button("تأكيد التصويت") { if !disabled && !isSaving { action() } }
            Button("إلغاء", role: .cancel) {}
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancel() } }
        .onChange(of: disabled) { _, value in if value { cancel() } }
        .onChange(of: isSaving) { _, value in if value { cancel() } }
        .onDisappear { cancel() }
    }

    private func beginHold() {
        withAnimation(.linear(duration: MatchAwardHoldController.duration)) { progress = 1 }
        hold.begin { intensity in
            Haptics.drumRollPulse(intensity: CGFloat(intensity))
        } onComplete: {
            guard touchActive, !disabled, !isSaving, scenePhase == .active else { cancel(); return }
            action()
        }
    }

    private func cancelHold() {
        hold.cancel()
        withAnimation(.easeOut(duration: 0.12)) { progress = 0 }
    }

    private func cancel() {
        cancelHold()
        touchActive = false
    }
}

