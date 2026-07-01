//
//  AppState.swift
//  Sirr
//
//  Created by naif ali alshahrani on 11/08/1447 AH.
//

import Combine
import Foundation

@MainActor
class AppState: ObservableObject {
    @Published var isLoggedIn = false
    @Published var deepLinkEventId: UUID?
    /// False until the initial session check completes. Used to avoid flashing
    /// the logged-out deep-link sheet to a user who turns out to be signed in.
    @Published var sessionChecked = false
    let authVM = AuthViewModel()
    private var cancellables = Set<AnyCancellable>()

    init() {
        authVM.$isAuthenticated
            .assign(to: \.isLoggedIn, on: self)
            .store(in: &cancellables)
        Task {
            await authVM.checkSession()
            sessionChecked = true
        }
    }

    func handleDeepLink(_ url: URL) {
        // Accept both the custom scheme (sirr://event/{id}) and the Universal
        // Link (https://guileless-squirrel-b6537a.netlify.app/event/{id}). In
        // both cases the event id is the path segment that follows "event".
        let segments = (url.host.map { [$0] } ?? []) + url.pathComponents.filter { $0 != "/" }
        guard let idx = segments.firstIndex(of: "event"),
              idx + 1 < segments.count,
              let eventId = UUID(uuidString: segments[idx + 1]) else { return }
        deepLinkEventId = eventId
    }
}

