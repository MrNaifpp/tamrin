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
    @State private var pendingLoginForEvent = false

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
                        LoginOnbord(onNavigateToLogin: { authPath.append(AuthScreen.login) })
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

            if let deepId = appState.deepLinkEventId, !appState.isLoggedIn {
                SharedEventView(
                    eventId: deepId,
                    isLoggedIn: false,
                    onDismiss: {
                        appState.deepLinkEventId = nil
                    },
                    onRequestLogin: {
                        pendingLoginForEvent = true
                        appState.deepLinkEventId = nil
                        authPath.append(AuthScreen.login)
                    }
                )
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.deepLinkEventId != nil)
        .onReceive(NotificationCenter.default.publisher(for: .deepLinkReceived)) { notification in
            if let url = notification.object as? URL {
                appState.handleDeepLink(url)
            }
        }
    }
}


#Preview {
    ContentView()
}
