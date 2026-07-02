//
//  WorkspaceSwitcherSheet.swift
//  Sirr
//
//  Slack-style half-sheet listing the user's workspaces. Tapping a row makes
//  it the current workspace; the gear opens its settings; logout lives at the
//  bottom (it left the home toolbar when the workspace avatar took its place).
//

import SwiftUI

struct WorkspaceSwitcherSheet: View {
    let workspaces: [WorkspaceRecord]
    let currentId: UUID?
    var onSelect: (WorkspaceRecord) -> Void
    var onCreate: () -> Void
    var onOpenSettings: (WorkspaceRecord) -> Void
    var onLogout: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color(white: 0.10).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("مساحاتك")
                    .font(.appSubheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(workspaces) { ws in
                            workspaceRow(ws)
                        }
                        createRow
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }

                logoutRow
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func workspaceRow(_ ws: WorkspaceRecord) -> some View {
        HStack(spacing: 12) {
            Button {
                onSelect(ws)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    WorkspaceAvatar(name: ws.name, id: ws.id)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ws.name)
                            .font(.appBodyMedium)
                            .foregroundStyle(.white)
                        if let count = ws.memberCount {
                            Text("\(count) أعضاء")
                                .font(.appCaption)
                                .foregroundStyle(Color(white: 0.55))
                        }
                    }
                    Spacer()
                    if ws.id == currentId {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                dismiss()
                onOpenSettings(ws)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(white: 0.55))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(ws.id == currentId ? .white.opacity(0.14) : .white.opacity(0.06))
        )
    }

    private var createRow: some View {
        Button {
            dismiss()
            onCreate()
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: "plus").foregroundStyle(.white))
                Text("مساحة جديدة")
                    .font(.appBodyMedium)
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private var logoutRow: some View {
        Button {
            dismiss()
            onLogout()
        } label: {
            Text("تسجيل الخروج")
                .font(.appBody)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }
}
