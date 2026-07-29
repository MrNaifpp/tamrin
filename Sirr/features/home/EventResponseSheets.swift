import SwiftUI

/// A stable value passed by the reason pickers. `code == nil` means the user
/// intentionally chose not to share a reason.
struct EventReasonSelection: Identifiable, Hashable, Sendable {
    let code: String?
    let title: String
    let acceptsFreeText: Bool

    var id: String { code ?? "without_reason" }

    init(code: String?, title: String, acceptsFreeText: Bool = false) {
        self.code = code
        self.title = title
        self.acceptsFreeText = acceptsFreeText
    }
}

/// Lets a member confirm that they cannot attend and optionally explain why.
/// The caller owns persistence and any roster refresh after `onConfirm` returns.
struct MemberDeclineSheet: View {
    let onConfirm: @MainActor (_ reasonCode: String?, _ reasonText: String?) async throws -> Void

    private static let reasons = [
        EventReasonSelection(code: nil, title: "بدون سبب"),
        EventReasonSelection(code: "traveling", title: "مسافر"),
        EventReasonSelection(code: "tired", title: "تعبان"),
        EventReasonSelection(code: "injured", title: "مصاب"),
        EventReasonSelection(code: "commitment", title: "لدي ارتباط"),
        EventReasonSelection(code: "other", title: "أخرى", acceptsFreeText: true)
    ]

    var body: some View {
        EventResponseFlow(
            title: "الاعتذار عن التمرين",
            message: "هل أنت متأكد من الاعتذار؟ سيتاح مكانك لبقية أعضاء المجموعة، ويمكنك إضافة السبب بشكل اختياري.",
            confirmationTitle: "نعم، أعتذر",
            reasonTitle: "سبب الاعتذار",
            reasonPrompt: "تحب تضيف سبب اعتذارك؟ اختياري، ويساعد المشرف يرتب التمرين.",
            confirmTitle: "تأكيد الاعتذار",
            reasons: Self.reasons,
            // A member giving up their seat frees it for someone else, so the
            // commitment is deliberate: it takes a slide, not a tap.
            slideToConfirmTitle: "اسحب لتأكيد الاعتذار",
            onConfirm: onConfirm
        )
    }
}

/// Lets an administrator skip one occurrence without ending its recurring
/// series. The reason is optional and persistence remains with the caller.
struct AdminSkipEventSheet: View {
    let onConfirm: @MainActor (_ reasonCode: String?, _ reasonText: String?) async throws -> Void

    private static let reasons = [
        EventReasonSelection(code: nil, title: "بدون سبب"),
        EventReasonSelection(code: "weather", title: "ظرف الطقس"),
        EventReasonSelection(code: "match_or_event_conflict", title: "تعارض مع مباراة أو حدث مهم"),
        EventReasonSelection(code: "low_attendance", title: "قلة العدد"),
        EventReasonSelection(code: "occasion", title: "وجود مناسبة"),
        EventReasonSelection(code: "other", title: "أخرى", acceptsFreeText: true)
    ]

    var body: some View {
        EventResponseFlow(
            title: "تخطي هذا الموعد",
            message: "سيتم تخطي هذا الموعد فقط، وتستمر سلسلة التمارين والمواعيد القادمة كالمعتاد. إضافة السبب اختيارية.",
            confirmationTitle: "متابعة",
            reasonTitle: "سبب التخطي",
            reasonPrompt: "تحب تضيف سبب التخطي؟ اختياري، ويوصل للأعضاء مع الإشعار.",
            confirmTitle: "تخطي الموعد",
            reasons: Self.reasons,
            onConfirm: onConfirm
        )
    }
}

/// Two sheets, not two steps in one: the first confirms the decision, and only
/// once it is confirmed does a second sheet come up to attach an optional
/// reason. Both use the platform's own chrome — a `NavigationStack` with an
/// inline title and toolbar actions — and both stop at their content's height.
private struct EventResponseFlow: View {
    let title: String
    let message: String
    let confirmationTitle: String
    let reasonTitle: String
    let reasonPrompt: String
    let confirmTitle: String
    let reasons: [EventReasonSelection]
    /// When set, confirming requires dragging this control rather than tapping
    /// a toolbar button.
    var slideToConfirmTitle: String?
    let onConfirm: @MainActor (_ reasonCode: String?, _ reasonText: String?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isReasonPresented = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label {
                    Text(message)
                        .font(TamrinFont.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .symbolEffect(.pulse)
                }
                .labelStyle(.titleAndIcon)

                if let slideToConfirmTitle {
                    SlideToConfirmButton(title: slideToConfirmTitle) {
                        isReasonPresented = true
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheetContentHeight()
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء", role: .cancel) { dismiss() }
                }
                if slideToConfirmTitle == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmationTitle, role: .destructive) {
                            Haptics.impact(.rigid)
                            isReasonPresented = true
                        }
                    }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .fittedSheet(minHeight: 180, includesNavigationBar: true)
        .sheet(isPresented: $isReasonPresented) {
            EventReasonSheet(
                title: reasonTitle,
                prompt: reasonPrompt,
                confirmTitle: confirmTitle,
                reasons: reasons,
                onConfirm: onConfirm,
                onFinished: { dismiss() }
            )
        }
    }
}

/// The second sheet: attach an optional reason, then commit. Presented only
/// after the decision itself has been confirmed.
private struct EventReasonSheet: View {
    let title: String
    let prompt: String
    let confirmTitle: String
    let reasons: [EventReasonSelection]
    let onConfirm: @MainActor (_ reasonCode: String?, _ reasonText: String?) async throws -> Void
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedReason: EventReasonSelection
    @State private var otherReasonText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var reasonFieldFocused: Bool

    private let maximumReasonLength = 500

    init(
        title: String,
        prompt: String,
        confirmTitle: String,
        reasons: [EventReasonSelection],
        onConfirm: @escaping @MainActor (_ reasonCode: String?, _ reasonText: String?) async throws -> Void,
        onFinished: @escaping () -> Void
    ) {
        precondition(!reasons.isEmpty, "Event response sheets require at least one reason option.")
        self.title = title
        self.prompt = prompt
        self.confirmTitle = confirmTitle
        self.reasons = reasons
        self.onConfirm = onConfirm
        self.onFinished = onFinished
        _selectedReason = State(initialValue: reasons[0])
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(prompt)
                    .font(TamrinFont.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker(title, selection: $selectedReason.animation(.smooth(duration: 0.25))) {
                    ForEach(reasons) { reason in
                        Text(reason.title).tag(reason)
                    }
                }
                .pickerStyle(.menu)
                .tint(.primary)
                .padding(.horizontal, 14)
                .frame(height: 52)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TamrinTheme.secondary, in: .rect(cornerRadius: 16, style: .continuous))
                .disabled(isSubmitting)

                if selectedReason.acceptsFreeText {
                    TextField("اكتب السبب", text: $otherReasonText, axis: .vertical)
                        .font(TamrinFont.body)
                        .lineLimit(2 ... 4)
                        .focused($reasonFieldFocused)
                        .disabled(isSubmitting)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(TamrinTheme.secondary, in: .rect(cornerRadius: 16, style: .continuous))
                        .transition(.blurReplace.combined(with: .move(edge: .top)))
                        .onChange(of: otherReasonText) { _, newValue in
                            guard newValue.count > maximumReasonLength else { return }
                            otherReasonText = String(newValue.prefix(maximumReasonLength))
                        }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(TamrinFont.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.blurReplace)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheetContentHeight()
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(.smooth(duration: 0.28), value: selectedReason)
            .animation(.smooth(duration: 0.28), value: errorMessage)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("رجوع") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, role: .destructive) {
                        reasonFieldFocused = false
                        Task { await submit() }
                    }
                    .disabled(isSubmitting)
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
    }

    @MainActor
    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil

        let trimmedText = otherReasonText.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasonText = selectedReason.acceptsFreeText && !trimmedText.isEmpty
            ? String(trimmedText.prefix(maximumReasonLength))
            : nil

        do {
            try await onConfirm(selectedReason.code, reasonText)
            dismiss()
            // Close the confirmation sheet underneath once the reason sheet
            // has gone, so the whole flow leaves the screen together.
            onFinished()
        } catch {
            let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = description.isEmpty ? "تعذر إكمال العملية. حاول مرة أخرى." : description
            isSubmitting = false
        }
    }
}

/// Slide-to-confirm, restored from the original decline experience: nothing
/// happens until the knob is dragged most of the way across, so an accidental
/// tap can never give up a seat. `leading` is the physical right edge in the
/// app's RTL environment, so the drag runs right-to-left.
private struct SlideToConfirmButton: View {
    let title: String
    let confirm: () -> Void

    @State private var progress: CGFloat = 0
    @State private var didHaptic = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let knob: CGFloat = 54
    private let threshold: CGFloat = 0.82

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - knob - 8, 1)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.red.opacity(0.16))

                Text(title)
                    .font(TamrinFont.font(size: 14, weight: .bold))
                    .foregroundStyle(.red.opacity(0.92 - Double(progress) * 0.65))
                    .frame(maxWidth: .infinity)

                Circle()
                    .fill(.red)
                    .frame(width: knob, height: knob)
                    .overlay {
                        Image(systemName: progress > 0.78 ? "checkmark" : "chevron.left.2")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .padding(4)
                    .offset(x: travel * progress)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                progress = min(max(-value.translation.width / travel, 0), 1)
                                if progress > threshold, !didHaptic {
                                    Haptics.impact(.rigid)
                                    didHaptic = true
                                } else if progress < threshold {
                                    didHaptic = false
                                }
                            }
                            .onEnded { _ in
                                if progress > threshold {
                                    Haptics.success()
                                    confirm()
                                    withAnimation(.smooth(duration: 0.25)) { progress = 0 }
                                } else {
                                    withAnimation(reduceMotion ? nil : .bouncy(duration: 0.4)) { progress = 0 }
                                }
                                didHaptic = false
                            }
                    )
            }
            .contentShape(.capsule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityHint("اسحب من اليمين إلى اليسار للتأكيد")
            .accessibilityAction { confirm() }
        }
        .frame(height: 62)
    }
}
