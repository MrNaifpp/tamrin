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
    /// Invite code from a /join/{code} link, pending until the join screen handles it.
    @Published var deepLinkJoinCode: String?
    /// False until the initial session check completes. Used to avoid flashing
    /// the logged-out deep-link sheet to a user who turns out to be signed in.
    @Published var sessionChecked = false
    /// The workspace the app is currently "inside" (Slack-style). Persisted so
    /// relaunch lands in the same workspace. nil = not yet chosen / none.
    @Published var currentWorkspaceId: UUID? {
        didSet {
            UserDefaults.standard.set(currentWorkspaceId?.uuidString, forKey: Self.currentWorkspaceKey)
        }
    }
    let authVM = AuthViewModel()
    private var cancellables = Set<AnyCancellable>()
    private static let currentWorkspaceKey = "currentWorkspaceId"

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.currentWorkspaceKey) {
            currentWorkspaceId = UUID(uuidString: stored)
        }
        authVM.$isAuthenticated
            .assign(to: \.isLoggedIn, on: self)
            .store(in: &cancellables)
        Task {
            await authVM.checkSession()
            sessionChecked = true
        }
    }

    func handleDeepLink(_ url: URL) {
        // Accept both the custom scheme (sirr://event/{id}, sirr://join/{code})
        // and the Universal Link (https://<domain>/event/{id}, /join/{code}).
        // The payload is the path segment that follows "event" / "join".
        let segments = (url.host.map { [$0] } ?? []) + url.pathComponents.filter { $0 != "/" }
        if let idx = segments.firstIndex(of: "event"),
           idx + 1 < segments.count,
           let eventId = UUID(uuidString: segments[idx + 1]) {
            deepLinkEventId = eventId
            return
        }
        if let idx = segments.firstIndex(of: "join"),
           idx + 1 < segments.count {
            let code = segments[idx + 1]
            // Invite codes are 12 alphanumeric chars (new_invite_code()).
            guard code.count == 12, code.allSatisfy({ $0.isLetter || $0.isNumber }) else { return }
            deepLinkJoinCode = code
        }
    }
}
