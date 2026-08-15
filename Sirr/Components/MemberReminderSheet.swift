import SwiftUI

/// Picks which reminder the group gets, then sends it. Two choices and one
/// action, so the whole thing is one short screen: the options sit at the top
/// and the send button is pinned to the bottom edge, closed until a choice
/// has actually been made.
struct MemberReminderSheet: View {
    /// Returns a message to show once the push has gone out; throws to keep
    /// the sheet open with the reason.
    let onSend: @MainActor (MemberReminderKind) async throws -> String

    @Environment(\.dismiss) private var dismiss
    @State private var selection: MemberReminderKind?
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                option(
                    .register,
                    title: "تذكير الأعضاء بالتسجيل",
                    detail: "يوصل للأعضاء اللي ما حجزوا مقاعدهم بعد",
                    symbol: "person.badge.plus"
                )
                option(
                    .payment,
                    title: "تذكير الأعضاء بدفع القطة",
                    detail: "يوصل للمسجلين في الموعد",
                    symbol: "banknote.fill"
                )

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(TamrinFont.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                        .transition(.blurReplace)
                }

                // The send button is measured with the rest of the content
                // rather than pinned as a safe-area inset — an inset is laid
                // out after the sheet has been sized, so it never reached the
                // detent and left the sheet stretched to its ceiling. No
                // Spacer either, for the same reason: a greedy stack reports
                // the whole screen as its height. In a content-fitted sheet the
                // end of this stack is the bottom edge.
                TamrinActionButton(
                    title: "إرسال الإشعار",
                    isLoading: isSending
                ) {
                    Task { await send() }
                }
                .disabled(selection == nil || isSending)
                .padding(.top, 12)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .sheetContentHeight()
            .frame(maxHeight: .infinity, alignment: .top)
            .background(TamrinTheme.sheet)
            .animation(.smooth(duration: 0.26), value: selection)
            .animation(.smooth(duration: 0.26), value: errorMessage)
            .navigationTitle("إشعار الأعضاء")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء", role: .cancel) { dismiss() }
                        .disabled(isSending)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .fittedSheet(minHeight: 300, includesNavigationBar: true)
        .interactiveDismissDisabled(isSending)
    }

    private func option(
        _ kind: MemberReminderKind,
        title: String,
        detail: String,
        symbol: String
    ) -> some View {
        let isSelected = selection == kind

        return Button {
            Haptics.selection()
            selection = kind
            errorMessage = nil
        } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Color.primary)
                    .frame(width: 44, height: 44)
                    .background(
                        isSelected ? AnyShapeStyle(TamrinTheme.ink) : AnyShapeStyle(TamrinTheme.secondary),
                        in: .rect(cornerRadius: 15, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(TamrinFont.headline)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(TamrinFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? TamrinTheme.ink : Color.secondary.opacity(0.3))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TamrinTheme.card, in: .rect(cornerRadius: 22, style: .continuous))
            .contentShape(.rect(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .accessibilityValue(isSelected ? "محدد" : "غير محدد")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @MainActor
    private func send() async {
        guard let selection, !isSending else { return }
        isSending = true
        errorMessage = nil

        do {
            _ = try await onSend(selection)
            Haptics.success()
            dismiss()
        } catch {
            Haptics.error()
            let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = description.isEmpty ? "تعذر إرسال الإشعار. حاول مرة أخرى." : description
            isSending = false
        }
    }
}

#Preview {
    Color.black
        .sheet(isPresented: .constant(true)) {
            MemberReminderSheet { _ in "أُرسل التذكير" }
        }
}
