//
//  JoinWorkspaceView.swift
//  Sirr
//
//  Invite-link join screen. Placeholder — full UI lands with the join flow task.
//

import SwiftUI

struct JoinWorkspaceView: View {
    let code: String
    var isLoggedIn: Bool
    var onDismiss: () -> Void
    var onRequestLogin: () -> Void
    /// Called with the workspace id after a successful join.
    var onJoined: (UUID) -> Void

    var body: some View {
        Color.black.ignoresSafeArea()
            .overlay(ProgressView().tint(.white))
            .onTapGesture { onDismiss() }
    }
}
