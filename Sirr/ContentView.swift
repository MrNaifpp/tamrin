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
    @StateObject private var updateGate = AppUpdateGate()
    @Environment(\.scenePhase) private var scenePhase
    @State private var authPath = NavigationPath()
    /// Event the user was trying to join when prompted to log in. Held across
    /// the login flow so we can route to it once authenticated.
    @State private var pendingEventId: UUID?
    /// Invite code the user was trying to use when prompted to log in.
    @State private var pendingJoinCode: String?

    var body: some View {
        ZStack {
            Group {
                if appState.isLoggedIn, appState.authVM.isNewUserAfterOTP {
                    SignupView(vm: appState.authVM, onBack: nil, isPostOTP: true, onComplete: {
                        appState.authVM.clearNewUserAfterOTP()
                    })
                } else if appState.isLoggedIn || isDebugMemberFixtureEnabled {
                    // Designer Home feed, now wired to Supabase via HomeStore
                    // (workspaces / events / participants / profile).
                    DesignerHomeView(appState: appState)
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

            if let code = appState.deepLinkJoinCode, appState.isLoggedIn, appState.sessionChecked {
                JoinWorkspaceView(
                    code: code,
                    isLoggedIn: true,
                    onDismiss: { appState.deepLinkJoinCode = nil },
                    onRequestLogin: {},
                    onJoined: { wsId in
                        appState.currentWorkspaceId = wsId
                    }
                )
                .transition(.move(edge: .bottom))
            }

            if let code = appState.deepLinkJoinCode, !appState.isLoggedIn, appState.sessionChecked {
                JoinWorkspaceView(
                    code: code,
                    isLoggedIn: false,
                    onDismiss: { appState.deepLinkJoinCode = nil },
                    onRequestLogin: {
                        pendingJoinCode = code
                        appState.deepLinkJoinCode = nil
                        authPath = NavigationPath()
                    },
                    onJoined: { _ in }
                )
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.deepLinkEventId != nil || appState.deepLinkJoinCode != nil)
        .onChange(of: appState.isLoggedIn) { loggedIn in
            guard loggedIn else {
                // Signed out: drop any stale deep-link so overlays don't
                // reappear over the login screen and error out.
                appState.deepLinkEventId = nil
                appState.deepLinkJoinCode = nil
                pendingEventId = nil
                pendingJoinCode = nil
                return
            }
            // Resume whichever deep link was pending before login.
            if let id = pendingEventId {
                pendingEventId = nil
                appState.deepLinkEventId = id
            }
            if let code = pendingJoinCode {
                pendingJoinCode = nil
                appState.deepLinkJoinCode = code
            }
        }
        .onReceive(DeepLinkRouter.shared.$pendingURL) { url in
            guard let url else { return }
            appState.handleDeepLink(url)
            DeepLinkRouter.shared.clear()
        }
        // Outermost on purpose: the gate has to cover the deep-link overlays
        // above as well, or an invite link would be a way around it.
        .sheet(item: updateGate.presentation) { config in
            ForceUpdateSheet(storeURL: URL(string: config.updateUrl))
        }
        .task { await updateGate.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Re-check on foreground too. Without this, a session left open
            // for days never sees the floor move.
            guard phase == .active else { return }
            Task { await updateGate.refresh() }
        }
    }

    /// The deterministic Home fixture is an explicit launch-only testing mode.
    /// Let it reach Home without creating a real Supabase session so the member
    /// journey — including anonymous ratings — can be exercised safely offline.
    private var isDebugMemberFixtureEnabled: Bool {
        #if DEBUG
        HomeDebugMemberFixture.isEnabled
        #else
        false
        #endif
    }
}


#Preview {
    ContentView()
}
