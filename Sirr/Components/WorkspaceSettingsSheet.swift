//
//  WorkspaceSettingsSheet.swift
//  Sirr
//
//  Single half-sheet (same pattern as EventSettingsSheet): identity header,
//  invite-link share, member list (owner can remove), rename/regenerate for the
//  owner, and delete (owner) / leave (member) at the bottom.
//

import SwiftUI

struct WorkspaceSettingsSheet: View {
    let workspace: WorkspaceRecord
    let currentUserId: UUID?
    /// Called after rename/regenerate/remove so home can refresh its list.
    var onChanged: () -> Void
    /// Called after leave or delete; caller clears currentWorkspaceId and reloads.
    var onLeftOrDeleted: () -> Void
    /// App-level sign-out (this sheet doubles as the app's settings home).
    var onLogout: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var detail: WorkspaceDetail?
    @State private var loadError: String?
    @State private var isWorking = false
    @State private var actionError: String?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDestructiveConfirm = false
    @State private var memberToRemove: WorkspaceMemberRecord?

    private var isOwner: Bool { currentUserId == workspace.ownerId }
    private var inviteCode: String? { detail?.workspace.inviteCode ?? workspace.inviteCode }

    var body: some View {
        ZStack {
            Color(white: 0.10).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        identitySection
                        inviteSection
                        membersSection
                        dangerSection
                        appSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .task { await loadDetail() }
        .alert("إعادة تسمية المساحة", isPresented: $showRename) {
            TextField("الاسم", text: $renameText)
            Button("حفظ") { handleRename() }
            Button("إلغاء", role: .cancel) {}
        }
        .confirmationDialog(
            isOwner ? "حذف المساحة" : "مغادرة المساحة",
            isPresented: $showDestructiveConfirm,
            titleVisibility: .visible
        ) {
            Button(isOwner ? "حذف" : "مغادرة", role: .destructive) { handleLeaveOrDelete() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text(isOwner
                 ? "سيتم حذف المساحة وجميع أحداثها ومشاركيها نهائيًا. لا يمكن التراجع."
                 : "ستفقد الوصول إلى أحداث هذه المساحة وستُزال من الأحداث القادمة.")
        }
        .confirmationDialog(
            "إزالة العضو",
            isPresented: Binding(
                get: { memberToRemove != nil },
                set: { if !$0 { memberToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("إزالة", role: .destructive) {
                if let member = memberToRemove {
                    memberToRemove = nil
                    handleRemove(member)
                }
            }
            Button("إلغاء", role: .cancel) { memberToRemove = nil }
        } message: {
            Text("سيفقد \(memberToRemove?.displayName ?? "العضو") الوصول إلى المساحة وسيُزال من الأحداث القادمة.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        ZStack {
            Text("إعدادات المساحة")
                .font(.appSubheadline)
                .foregroundStyle(.white)
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 40, height: 40)
                        .background(Color.white)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private var identitySection: some View {
        VStack(spacing: 8) {
            WorkspaceAvatar(name: workspace.name, id: workspace.id, size: 56)
            Text(detail?.workspace.name ?? workspace.name)
                .font(.appSubheadline)
                .foregroundStyle(.white)
            Text("\(detail?.members.count ?? workspace.memberCount ?? 0) أعضاء" + (isOwner ? " · أنت المالك" : ""))
                .font(.appCaption)
                .foregroundStyle(Color(white: 0.55))
            if isOwner {
                Button("إعادة تسمية") {
                    renameText = detail?.workspace.name ?? workspace.name
                    showRename = true
                }
                .font(.appCaption)
                .foregroundStyle(.blue)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let code = inviteCode,
               let url = URL(string: "https://guileless-squirrel-b6537a.netlify.app/join/\(code)") {
                ShareLink(item: url) {
                    HStack {
                        Spacer()
                        Image(systemName: "link")
                        Text("مشاركة رابط الدعوة")
                            .font(.appBody)
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.blue.opacity(0.35))
                    )
                }
            }
            if isOwner {
                Button {
                    handleRegenerate()
                } label: {
                    Text("إبطال الرابط وإنشاء رابط جديد")
                        .font(.appCaption)
                        .foregroundStyle(Color(white: 0.55))
                }
                .disabled(isWorking)
            }
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("الأعضاء")
                .font(.appBody)
                .foregroundStyle(Color(white: 0.5))
                .padding(.horizontal, 4)

            if let loadError {
                Text(loadError).font(.appCaption).foregroundStyle(.red)
            } else if let members = detail?.members {
                ForEach(members) { member in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(.white.opacity(0.12))
                            .frame(width: 30, height: 30)
                            .overlay(
                                Text(String((member.displayName ?? "؟").prefix(1)))
                                    .font(.appCaption)
                                    .foregroundStyle(.white)
                            )
                        Text(member.displayName ?? "عضو")
                            .font(.appBody)
                            .foregroundStyle(.white)
                        Spacer()
                        if member.isOwner {
                            Text("المالك")
                                .font(.appCaption)
                                .foregroundStyle(Color(white: 0.55))
                        } else if isOwner {
                            Button("إزالة") { memberToRemove = member }
                                .font(.appCaption)
                                .foregroundStyle(.red)
                                .disabled(isWorking)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white.opacity(0.06))
                    )
                }
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity)
            }
        }
    }

    private var dangerSection: some View {
        VStack(spacing: 8) {
            Button {
                showDestructiveConfirm = true
            } label: {
                HStack {
                    Spacer()
                    if isWorking {
                        ProgressView().tint(.red)
                    } else {
                        Text(isOwner ? "حذف المساحة" : "مغادرة المساحة")
                            .font(.appBody)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                }
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(isWorking)

            if let actionError {
                Text(actionError).font(.appCaption).foregroundStyle(.red)
            }
        }
    }

    private var appSection: some View {
        VStack(spacing: 8) {
            Divider().overlay(Color(white: 0.25))
            Button {
                dismiss()
                onLogout()
            } label: {
                HStack {
                    Spacer()
                    Text("تسجيل الخروج")
                        .font(.appBody)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func loadDetail() async {
        do {
            detail = try await WorkspaceService.shared.getWorkspace(id: workspace.id)
        } catch {
            loadError = "تعذر تحميل الأعضاء."
        }
    }

    private func handleRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run {
            _ = try await WorkspaceService.shared.renameWorkspace(id: workspace.id, name: trimmed)
            await loadDetail()
            onChanged()
        }
    }

    private func handleRegenerate() {
        run {
            _ = try await WorkspaceService.shared.regenerateInviteCode(id: workspace.id)
            await loadDetail()
            onChanged()
        }
    }

    private func handleRemove(_ member: WorkspaceMemberRecord) {
        run {
            try await WorkspaceService.shared.removeMember(workspaceId: workspace.id, userId: member.userId)
            await loadDetail()
            onChanged()
        }
    }

    private func handleLeaveOrDelete() {
        run {
            if isOwner {
                try await WorkspaceService.shared.deleteWorkspace(id: workspace.id)
            } else {
                try await WorkspaceService.shared.leaveWorkspace(id: workspace.id)
            }
            onLeftOrDeleted()
            dismiss()
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        actionError = nil
        Task { @MainActor in
            defer { isWorking = false }
            do { try await work() }
            catch { actionError = "تعذر تنفيذ العملية. حاول مرة أخرى." }
        }
    }
}
