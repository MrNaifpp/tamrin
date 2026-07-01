//
//  CreateWorkspaceSheet.swift
//  Sirr
//
//  Single-field sheet: name the workspace, create it, switch into it.
//

import SwiftUI

struct CreateWorkspaceSheet: View {
    /// Called with the created workspace; caller switches into it.
    var onCreated: (WorkspaceRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isCreating = false
    @State private var errorText: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            Color(white: 0.10).ignoresSafeArea()

            VStack(spacing: 20) {
                Text("مساحة جديدة")
                    .font(.appSubheadline)
                    .foregroundStyle(.white)
                    .padding(.top, 24)

                TextField("", text: $name, prompt: Text("اسم المساحة").foregroundColor(Color(white: 0.45)))
                    .font(.appBody)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    .focused($nameFocused)
                    .padding(.horizontal, 18)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.white.opacity(0.08))
                    )
                    .padding(.horizontal, 20)

                if let errorText {
                    Text(errorText)
                        .font(.appCaption)
                        .foregroundStyle(.red)
                }

                Button {
                    handleCreate()
                } label: {
                    Group {
                        if isCreating {
                            ProgressView().tint(.black)
                        } else {
                            Text("إنشاء")
                                .font(.headline)
                                .foregroundStyle(.black)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 27, style: .continuous).fill(Color.white))
                }
                .buttonStyle(.plain)
                .disabled(isCreating || name.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, 20)

                Spacer()
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear { nameFocused = true }
    }

    private func handleCreate() {
        guard !isCreating else { return }
        isCreating = true
        errorText = nil
        Task {
            defer { isCreating = false }
            do {
                let ws = try await WorkspaceService.shared.createWorkspace(name: name)
                onCreated(ws)
                dismiss()
            } catch {
                errorText = "تعذر إنشاء المساحة. حاول مرة أخرى."
            }
        }
    }
}
