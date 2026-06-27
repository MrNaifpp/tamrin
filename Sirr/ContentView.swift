//
//  ContentView.swift
//  Sirr
//
//  Created by فارس أبومالح on 07/04/1447 AH.
//

import SwiftUI

enum AuthScreen: Hashable {
    case login
    case signup
}

struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var authPath = NavigationPath()
    /// Event the user was trying to join when prompted to log in. Held across
    /// the login flow so we can route to it once authenticated.
    @State private var pendingEventId: UUID?

    var body: some View {
        ZStack {
            Group {
                if appState.isLoggedIn, appState.authVM.isNewUserAfterOTP {
                    SignupView(vm: appState.authVM, onBack: nil, isPostOTP: true, onComplete: {
                        appState.authVM.clearNewUserAfterOTP()
                    })
                } else if appState.isLoggedIn {
                    EventPageView(authVM: appState.authVM, deepLinkEventId: $appState.deepLinkEventId)
                } else {
                    NavigationStack(path: $authPath) {
                        LoginOnbord(vm: appState.authVM, onNavigateToLogin: { authPath.append(AuthScreen.login) })
                            .navigationDestination(for: AuthScreen.self) { screen in
                                if screen == .login {
                                    LoginView(vm: appState.authVM)
                                } else if screen == .signup {
                                    SignupView(vm: appState.authVM, onBack: { authPath.removeLast() })
                                }
                            }
                    }
                }
            }

            if let deepId = appState.deepLinkEventId, !appState.isLoggedIn, appState.sessionChecked {
                SharedEventView(
                    eventId: deepId,
                    isLoggedIn: false,
                    onDismiss: {
                        appState.deepLinkEventId = nil
                    },
                    onRequestLogin: {
                        // Remember the event so we can open it after login.
                        pendingEventId = deepId
                        appState.deepLinkEventId = nil
                        // Land on LoginOnbord (the real login entry with Apple /
                        // Google sign-in), not the bare email LoginView. Clearing
                        // the sheet reveals the onboarding root of the stack.
                        authPath = NavigationPath()
                    }
                )
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.deepLinkEventId != nil)
        .onChange(of: appState.isLoggedIn) { loggedIn in
            guard loggedIn else {
                // Signed out: drop any stale deep-link so the SharedEventView
                // overlay doesn't reappear over the login screen and error out.
                appState.deepLinkEventId = nil
                pendingEventId = nil
                return
            }
            // Resume the deep-link event after the user logs in. Re-driving
            // deepLinkEventId lets EventPageView's .task(id:) open the detail.
            guard let id = pendingEventId else { return }
            pendingEventId = nil
            appState.deepLinkEventId = id
        }
        .onReceive(DeepLinkRouter.shared.$pendingURL) { url in
            guard let url else { return }
            appState.handleDeepLink(url)
            DeepLinkRouter.shared.clear()
        }
    }
}


#Preview {
    ContentView()
}
