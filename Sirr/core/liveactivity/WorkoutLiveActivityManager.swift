import ActivityKit
import Foundation
import os

/// The small, stable snapshot needed to schedule the next workout outside the
/// app's process. Keeping this detached from HomeStore means ActivityKit never
/// receives roster, payment, or workspace state that it cannot use.
struct WorkoutActivityEvent: Hashable {
    let id: UUID
    let title: String
    let startAt: Date
    let locationName: String
    let latitude: Double?
    let longitude: Double?
}

/// Keeps exactly one Live Activity: the signed-in person's nearest confirmed
/// workout. iOS 26 can schedule the activity while the app is foregrounded and
/// start it later even after the app has moved to the background.
@MainActor
final class WorkoutLiveActivityManager {
    static let shared = WorkoutLiveActivityManager()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Sirr",
        category: "WorkoutLiveActivity"
    )
    private let leadTime: TimeInterval = 2 * 60 * 60
    private var desiredEvent: WorkoutActivityEvent?
    private var desiredRevision = 0
    private var synchronizationTask: Task<Void, Never>?

    private init() {}

    func synchronize(next event: WorkoutActivityEvent?) async {
        guard !Task.isCancelled else { return }
        desiredEvent = event
        desiredRevision &+= 1

        if let synchronizationTask {
            await synchronizationTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainSynchronizationQueue()
        }
        synchronizationTask = task
        await task.value
    }

    /// ActivityKit ending is asynchronous. Run one reconciliation at a time,
    /// then loop when a newer desired event arrived during an `await`, so an
    /// older task can never finish by removing the activity a newer task kept.
    private func drainSynchronizationQueue() async {
        while true {
            let revision = desiredRevision
            let event = desiredEvent
            await reconcile(next: event)

            guard revision == desiredRevision else { continue }
            synchronizationTask = nil
            return
        }
    }

    private func reconcile(next event: WorkoutActivityEvent?) async {
        let now = Date.now
        let activities = Activity<WorkoutActivityAttributes>.activities

        guard let event, event.startAt > now else {
            await endAll(activities)
            return
        }

        let expectedAttributes = WorkoutActivityAttributes(
            eventID: event.id.uuidString,
            title: event.title,
            venueName: event.locationName,
            latitude: event.latitude,
            longitude: event.longitude
        )
        let expectedStartTimestamp = event.startAt.timeIntervalSince1970

        // Attributes are immutable. A changed time, venue, or title therefore
        // replaces the pending activity instead of leaving stale lock-screen
        // details behind. If a duplicate somehow exists, keep only the first.
        var keptMatchingActivity = false
        for activity in activities {
            if !keptMatchingActivity,
               activity.attributes == expectedAttributes,
               abs(activity.content.state.startTimestamp - expectedStartTimestamp) < 0.5,
               activity.activityState != .ended,
               activity.activityState != .dismissed {
                keptMatchingActivity = true
            } else {
                await end(activity)
            }
        }
        guard !keptMatchingActivity else { return }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities are disabled for this app")
            return
        }

        let content = ActivityContent(
            state: WorkoutActivityAttributes.ContentState(
                startTimestamp: expectedStartTimestamp
            ),
            staleDate: event.startAt,
            relevanceScore: 1
        )
        let activationDate = event.startAt.addingTimeInterval(-leadTime)

        do {
            if activationDate > now {
                let alert = AlertConfiguration(
                    title: "تمرينك قرب",
                    body: "باقي ساعتين على \(event.title)",
                    sound: .default
                )
                _ = try Activity<WorkoutActivityAttributes>.request(
                    attributes: expectedAttributes,
                    content: content,
                    pushType: nil,
                    style: .standard,
                    alertConfiguration: alert,
                    start: activationDate
                )
                logger.info("Scheduled Live Activity for event \(event.id.uuidString, privacy: .public)")
            } else {
                _ = try Activity<WorkoutActivityAttributes>.request(
                    attributes: expectedAttributes,
                    content: content,
                    pushType: nil,
                    style: .standard
                )
                logger.info("Started Live Activity for event \(event.id.uuidString, privacy: .public)")
            }
        } catch {
            logger.error("Unable to schedule Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func endAll(_ activities: [Activity<WorkoutActivityAttributes>]) async {
        for activity in activities {
            await end(activity)
        }
    }

    private func end(_ activity: Activity<WorkoutActivityAttributes>) async {
        let finalContent = ActivityContent(
            state: activity.content.state,
            staleDate: nil,
            relevanceScore: 0
        )
        await activity.end(finalContent, dismissalPolicy: .immediate)
    }
}
