import SwiftUI

/// Lets the organizer seat someone who does not use the app by typing their
/// name. The caller owns persistence: `onAdd` returns a message when the server
/// refuses (a full list, a closed registration, a name already on the roster),
/// which is shown in place rather than dismissing onto an unchanged roster.
struct ManualParticipantSheet: View {
    /// Whether the exercise costs money, which is the only thing the organizer
    /// still has to settle by hand after the seat exists.
    let isPaid: Bool
    /// Returns nil on success, or the reason the registration did not happen.
    let onAdd: @MainActor (_ name: String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    private let maximumNameLength = 60

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("اسم اللاعب")
                    .font(TamrinFont.font(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("مثلًا: خالد العتيبي", text: $name)
                    .font(TamrinFont.headline)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .disabled(isSubmitting)
                    .onSubmit { submit() }
                    .onChange(of: name) { _, newValue in
                        guard newValue.count > maximumNameLength else { return }
                        name = String(newValue.prefix(maximumNameLength))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The field is the white surface; the sheet under it stays
                    // off-white.
                    .background(TamrinTheme.card, in: .capsule)

                Text(isPaid
                     ? "يحجز مقعده في هذا الموعد فقط. مقعده محسوب مدفوع، وتسوّون المبلغ بينكم خارج التطبيق."
                     : "يحجز مقعده في هذا الموعد فقط، ولا يحتاج حساب في التطبيق.")
                    .font(TamrinFont.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(TamrinFont.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.blurReplace)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheetContentHeight()
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(.smooth(duration: 0.28), value: errorMessage)
            .background(TamrinTheme.sheet)
            .sheetTitle("تسجيل يدوي", subtitle: "سجّل لاعبًا ما عنده حساب في التطبيق")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء", role: .cancel) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("إضافة", action: submit)
                        .fontWeight(.semibold)
                        .disabled(isSubmitting || trimmedName.isEmpty)
                }
            }
            .overlay {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.large)
                        .padding(20)
                        .background(.regularMaterial, in: .rect(cornerRadius: 20, style: .continuous))
                        .transition(.blurReplace)
                }
            }
            .animation(.smooth(duration: 0.2), value: isSubmitting)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .fittedSheet(minHeight: 200, includesNavigationBar: true)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear { nameFocused = true }
    }

    private func submit() {
        guard !isSubmitting, !trimmedName.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil
        nameFocused = false

        Task {
            let failure = await onAdd(trimmedName)
            isSubmitting = false
            if let failure {
                errorMessage = failure
                Haptics.error()
                nameFocused = true
            } else {
                Haptics.success()
                dismiss()
            }
        }
    }
}

#Preview("تسجيل يدوي") {
    Color.black
        .sheet(isPresented: .constant(true)) {
            ManualParticipantSheet(isPaid: true) { name in
                name == "خالد" ? "فيه لاعب مسجل بنفس الاسم. ميّزه باسم العائلة أو رقم." : nil
            }
        }
}
