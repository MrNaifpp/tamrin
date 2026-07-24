//
//  JoinWorkspaceView.swift
//  Sirr
//
//  Invite-link join screen (sirr://join/{code} or https://<domain>/join/{code}).
//  Shows a preview (name, owner, member count) and one big join button.
//  Logged-out users get a login CTA; ContentView resumes the code post-login.
//

import SwiftUI

struct JoinWorkspaceView: View {
    let code: String
    var isLoggedIn: Bool
    var onDismiss: () -> Void
    var onRequestLogin: () -> Void
    /// Called with the workspace id after a successful join.
    var onJoined: (UUID) -> Void

    @State private var preview: WorkspaceInvitePreview?
    @State private var loadError: String?
    @State private var isJoining = false
    @State private var joinError: String?

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.55, green: 0.23, blue: 0.36),
                    Color(red: 0.10, green: 0.30, blue: 0.23)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if let preview {
                VStack(spacing: 14) {
                    Spacer()
                    WorkspaceAvatar(name: preview.name, id: preview.id, size: 64)
                    Text(preview.name)
                        .font(.appTitle)
                        .foregroundStyle(.white)
                    Text(previewSubtitle(preview))
                        .font(.appBody)
                        .foregroundStyle(.white.opacity(0.9))
                    if preview.memberCount > 0 {
                        Text("\(preview.memberCount) أعضاء")
                            .font(.appCaption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    joinButton(preview)
                    if let joinError {
                        Text(joinError)
                            .font(.appCaption)
                            .foregroundStyle(.red)
                    }
                    Button("ليس الآن") { onDismiss() }
                        .font(.appBody)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 32)
            } else if let loadError {
                VStack(spacing: 16) {
                    Text("🔗").font(.system(size: 48))
                    Text(loadError)
                        .font(.appBody)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button("إغلاق") { onDismiss() }
                        .font(.appBody)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 32)
            } else {
                ProgressView().tint(.white)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .task { await loadPreview() }
    }

    private func previewSubtitle(_ p: WorkspaceInvitePreview) -> String {
        if p.isMember { return "أنت عضو في هذه المجموعة" }
        if let owner = p.ownerName, !owner.isEmpty { return "دعاك \(owner) للانضمام" }
        return "دُعيت للانضمام"
    }

    @ViewBuilder
    private func joinButton(_ p: WorkspaceInvitePreview) -> some View {
        Button {
            if isLoggedIn { handleJoin() } else { onRequestLogin() }
        } label: {
            Group {
                if isJoining {
                    ProgressView().tint(.black)
                } else {
                    Text(p.isMember ? "فتح المجموعة" : (isLoggedIn ? "انضمام" : "سجّل الدخول للانضمام"))
                        .font(.headline)
                        .foregroundStyle(.black)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: TamrinControlMetrics.actionHeight)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.white))
        }
        .buttonStyle(.plain)
        .disabled(isJoining)
    }

    private func loadPreview() async {
        guard isLoggedIn else {
            // get_workspace_by_invite requires an authenticated session; show a
            // generic invite card prompting login instead of failing.
            loadError = nil
            // Minimal logged-out experience: straight to the login CTA.
            preview = WorkspaceInvitePreview(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: "دعوة إلى مجموعة", ownerName: nil, memberCount: 0, isMember: false)
            return
        }
        do {
            preview = try await WorkspaceService.shared.getInvitePreview(code: code)
        } catch {
            loadError = "رابط الدعوة غير صالح أو تم إبطاله.\nاطلب رابطًا جديدًا من صاحب المجموعة."
        }
    }

    private func handleJoin() {
        guard !isJoining else { return }
        joinError = nil
        isJoining = true
        Task {
            defer { isJoining = false }
            do {
                let wsId = try await WorkspaceService.shared.joinWorkspace(code: code)
                onJoined(wsId)
                onDismiss()
            } catch {
                joinError = "تعذر الانضمام. حاول مرة أخرى."
            }
        }
    }
}
