import Foundation

/// One timer owns both the drum roll and submission. Completion does not depend
/// on a second gesture recognizer competing with the native button.
@MainActor
final class MatchAwardHoldController {
    private var task: Task<Void, Never>?
    private var completed = false
    static let duration: Double = 1.1

    func begin(onBeat: @escaping (Double) -> Void, onComplete: @escaping () -> Void) {
        guard task == nil, !completed else { return }
        task = Task { @MainActor in
            let beats: [Double] = [0, 0.14, 0.27, 0.39, 0.50, 0.60, 0.69,
                                   0.77, 0.84, 0.90, 0.95, 1.00, 1.045, 1.08]
            let clock = ContinuousClock()
            let start = clock.now
            do {
                for (index, beat) in beats.enumerated() {
                    try await clock.sleep(until: start.advanced(by: .seconds(beat)))
                    try Task.checkCancellation()
                    onBeat(0.4 + Double(index) / Double(beats.count - 1) * 0.5)
                }
                try await clock.sleep(until: start.advanced(by: .seconds(Self.duration)))
                try Task.checkCancellation()
                completed = true
                task = nil
                onComplete()
            } catch { /* A released or interrupted hold never submits. */ }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        completed = false
    }
}
