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
    let authVM = AuthViewModel()
    private var cancellables = Set<AnyCancellable>()

    init() {
        authVM.$isAuthenticated
            .assign(to: \.isLoggedIn, on: self)
            .store(in: &cancellables)
        Task {
            await authVM.checkSession()
        }
    }

    func handleDeepLink(_ url: URL) {
        let raw = url.absoluteString
        guard raw.hasPrefix("sirr://event/") else { return }
        let after = raw.dropFirst("sirr://event/".count)
        let idString = String(after.prefix(36))
        guard let eventId = UUID(uuidString: idString) else { return }
        deepLinkEventId = eventId
    }
}

