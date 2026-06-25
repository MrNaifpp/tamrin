//
//  DeepLinkRouter.swift
//  Sirr
//
//  Buffers deep links so a link that arrives before the UI is listening
//  (the cold-launch-from-push case) is not lost. A plain NotificationCenter
//  post is dropped if no observer is subscribed at that instant; a @Published
//  value, by contrast, replays its current value to any late subscriber.
//

import Combine
import Foundation

@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    /// The most recent deep link awaiting handling. Subscribers receive the
    /// current value on subscription, so links delivered during launch are
    /// picked up once `ContentView` attaches its observer.
    @Published var pendingURL: URL?

    private init() {}

    func submit(_ url: URL) {
        pendingURL = url
    }

    func clear() {
        pendingURL = nil
    }
}
