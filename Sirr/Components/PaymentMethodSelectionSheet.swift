import SwiftUI

/// تجربة المشرف لاختيار وسيلة أو أكثر لاستلام رسوم التمرين وإدخال بياناتها.
struct PaymentMethodSelectionSheet: View {
    @Binding var selections: [PaymentMethodDraft]

    @Environment(\.dismiss) private var dismiss
    @State private var editorProvider: PaymentProvider = .stcBank
    @State private var isEditorPresented = false
    @State private var toast: PaymentSelectionToast?

    private let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    private let providers: [PaymentProvider] = [
        .alRajhi,
        .barq,
        .stcBank,
        .snb,
        .alinma,
        .riyad
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    introduction
                    cashOption
                    electronicPaymentSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(TamrinTheme.sheet)
            .navigationTitle("وسائل الدفع")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("إغلاق") { dismiss() }
                        .font(TamrinFont.font(size: 16, weight: .medium))
                }
                // Selections already write straight through to the plan, so
                // this confirms rather than commits — and it stays closed until
                // there is at least one way for a player to pay.
                ToolbarItem(placement: .topBarTrailing) {
                    Button("إضافة") {
                        Haptics.impact(.light)
                        dismiss()
                    }
                    .font(TamrinFont.font(size: 16, weight: .bold))
                    .disabled(selections.isEmpty)
                    .accessibilityHint(
                        selections.isEmpty
                            ? "اختر وسيلة دفع واحدة على الأقل أولًا"
                            : "يعتمد وسائل الدفع المحددة ويغلق الصفحة"
                    )
                }
            }
            .navigationDestination(isPresented: $isEditorPresented) {
                let provider = editorProvider
                let existing = method(for: provider)

                PaymentMethodDetailsEditor(
                    provider: provider,
                    existing: existing,
                    onSave: { method in
                        let wasExisting = existing != nil
                        upsert(method)
                        isEditorPresented = false
                        showToast(
                            wasExisting ? "حُفظت تعديلات \(provider.displayName)" : "أضفت \(provider.displayName)",
                            symbol: "checkmark.circle.fill"
                        )
                    },
                    onRemove: {
                        remove(provider)
                        isEditorPresented = false
                        showToast("أزلت \(provider.displayName)", symbol: "trash.fill")
                    }
                )
            }
            .overlay(alignment: .top) {
                if let toast {
                    savedToast(toast)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(2)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDragIndicator(.visible)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("كيف يستلم المشرف الدفع؟")
                    .font(TamrinFont.title2)

                Spacer(minLength: 12)

                if !selections.isEmpty {
                    Text("\(selections.count.formatted()) محددة")
                        .font(TamrinFont.font(size: 12, weight: .medium))
                        .foregroundStyle(TamrinTheme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(TamrinTheme.lime.opacity(0.72), in: .capsule)
                        .contentTransition(.numericText())
                }
            }

            Text("تقدر تختار أكثر من وسيلة. سيشاهد اللاعب الطرق المتاحة وبيانات التحويل اللازمة فقط.")
                .font(TamrinFont.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var cashOption: some View {
        let isSelected = method(for: .cash) != nil

        return Button {
            Haptics.selection()
            if isSelected {
                remove(.cash)
                showToast("أزلت الدفع كاش", symbol: "trash.fill")
            } else {
                upsert(PaymentMethodDraft(provider: .cash))
                showToast("أضفت الدفع كاش", symbol: "checkmark.circle.fill")
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "banknote.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : TamrinTheme.ink)
                    .frame(width: 52, height: 52)
                    .background(
                        isSelected ? AnyShapeStyle(TamrinTheme.ink) : AnyShapeStyle(TamrinTheme.secondary),
                        in: .rect(cornerRadius: 17, style: .continuous)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("الدفع كاش في الملعب")
                        .font(TamrinFont.headline)
                    Text("يدفع اللاعب للمشرف عند الحضور")
                        .font(TamrinFont.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(isSelected ? TamrinTheme.ink : Color.secondary.opacity(0.32))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 82)
            .background(
                TamrinTheme.card,
                in: .rect(cornerRadius: 24, style: .continuous)
            )
            .contentShape(.rect(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("الدفع كاش في الملعب")
        .accessibilityHint(isSelected ? "إزالة الدفع كاش من الخيارات" : "إضافة الدفع كاش إلى الخيارات")
        .accessibilityValue(isSelected ? "محدد" : "غير محدد")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var electronicPaymentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("التحويل الإلكتروني")
                    .font(TamrinFont.title3)
                Text("اضغط على الوسيلة لإضافة بياناتها أو تعديلها")
                    .font(TamrinFont.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(providers, id: \.self) { provider in
                    providerCard(provider)
                }
            }
        }
    }

    private func providerCard(_ provider: PaymentProvider) -> some View {
        let isSelected = method(for: provider) != nil

        return Button {
            Haptics.selection()
            editorProvider = provider
            isEditorPresented = true
        } label: {
            VStack(spacing: 10) {
                PaymentProviderLogo(provider: provider, size: 60)
                    .shadow(color: .black.opacity(0.075), radius: 6, y: 2)
                    .accessibilityHidden(true)

                Text(provider.selectionTitle)
                    .font(TamrinFont.font(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .center)
            .background(
                TamrinTheme.card,
                in: .rect(cornerRadius: 24, style: .continuous)
            )
            .overlay(alignment: .topLeading) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(TamrinTheme.ink, in: .circle)
                        .padding(10)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(provider.displayName)
        .accessibilityHint(isSelected ? "فتح بيانات وسيلة الدفع للتعديل أو الإزالة" : "فتح نموذج إضافة بيانات وسيلة الدفع")
        .accessibilityValue(isSelected ? "محدد" : "غير محدد")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func method(for provider: PaymentProvider) -> PaymentMethodDraft? {
        selections.first { $0.provider == provider }
    }

    private func upsert(_ method: PaymentMethodDraft) {
        if let originalIndex = selections.firstIndex(where: { $0.provider == method.provider }) {
            selections.removeAll { $0.provider == method.provider }
            selections.insert(method, at: min(originalIndex, selections.endIndex))
        } else {
            selections.append(method)
        }
    }

    private func remove(_ provider: PaymentProvider) {
        selections.removeAll { $0.provider == provider }
    }

    private func savedToast(_ toast: PaymentSelectionToast) -> some View {
        Label {
            Text(toast.message)
                .font(TamrinFont.font(size: 15, weight: .medium))
        } icon: {
            Image(systemName: toast.symbol)
                .font(.system(size: 18, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(minHeight: 50)
        .background(TamrinTheme.ink.opacity(0.96), in: .capsule)
        .shadow(color: .black.opacity(0.14), radius: 16, y: 7)
        .accessibilityAddTraits(.isStaticText)
    }

    private func showToast(_ message: String, symbol: String) {
        let value = PaymentSelectionToast(message: message, symbol: symbol)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            toast = value
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard toast?.id == value.id else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                toast = nil
            }
        }
    }
}

private extension PaymentProvider {
    /// الاسم المختصر داخل شبكة الاختيار، مطابق لإيقاع المرجع البصري.
    var selectionTitle: String {
        switch self {
        case .cash: "كاش"
        case .stcBank: "stc bank"
        case .barq: "برق"
        case .alRajhi: "الراجحي"
        case .snb: "الأهلي"
        case .alinma: "الإنماء"
        case .riyad: "الرياض"
        }
    }
}

private struct PaymentSelectionToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let symbol: String
}

/// يعرض الشعار الرسمي بنسبة أبعاده الأصلية، بلا حاوية دائرية أو إطار.
private struct PaymentProviderWordmark: View {
    let provider: PaymentProvider
    var maxWidth: CGFloat
    var height: CGFloat

    var body: some View {
        Group {
            if let assetName = provider.logoAssetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .padding(provider == .stcBank ? 10 : 0)
                    .background {
                        if provider == .stcBank {
                            provider.logoSurfaceColor
                                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                        }
                    }
            } else {
                Image(systemName: "banknote.fill")
                    .font(.system(size: height * 0.5, weight: .semibold))
                    .foregroundStyle(provider.brandColor)
            }
        }
        .frame(maxWidth: maxWidth, minHeight: height, maxHeight: height)
    }
}

private struct PaymentMethodDetailsEditor: View {
    let provider: PaymentProvider
    let existing: PaymentMethodDraft?
    let onSave: (PaymentMethodDraft) -> Void
    let onRemove: () -> Void

    @State private var phoneNumber: String
    @State private var iban: String
    @State private var accountNumber: String
    @State private var isRemoveConfirmationPresented = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case iban, accountNumber
    }

    init(
        provider: PaymentProvider,
        existing: PaymentMethodDraft?,
        onSave: @escaping (PaymentMethodDraft) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.provider = provider
        self.existing = existing
        self.onSave = onSave
        self.onRemove = onRemove
        _phoneNumber = State(initialValue: existing?.phoneNumber ?? "")
        _iban = State(initialValue: existing?.iban ?? "")
        _accountNumber = State(initialValue: existing?.accountNumber ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                fields
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, existing == nil ? 112 : 184)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TamrinTheme.sheet)
        .navigationTitle(existing == nil ? "إضافة وسيلة الدفع" : "تعديل وسيلة الدفع")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            bottomActions
        }
        .alert("إزالة \(provider.displayName)؟", isPresented: $isRemoveConfirmationPresented) {
            Button("إزالة الوسيلة", role: .destructive, action: onRemove)
            Button("تراجع", role: .cancel) {}
        } message: {
            Text("لن تظهر هذه الوسيلة للاعب ضمن خيارات الدفع لهذا التمرين.")
        }
        .onAppear {
            // The phone editor's UIKit field focuses itself in makeUIView; only
            // the bank branch still drives focus through FocusState.
            if !provider.requiresPhone {
                focusedField = .iban
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            PaymentProviderWordmark(provider: provider, maxWidth: 170, height: 74)
                .accessibilityHidden(true)

            Text(provider.displayName)
                .font(TamrinFont.title2)
            Text(provider.requiresPhone
                 ? "أدخل رقم الجوال المرتبط بالحساب"
                 : "أدخل البيانات التي يحتاجها اللاعب للتحويل")
                .font(TamrinFont.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var fields: some View {
        if provider.requiresPhone {
            // UIKit-backed on purpose: on device, SwiftUI's TextField never drew
            // digits freshly typed from the numeric keypads (.numberPad and
            // .phonePad alike) in this sheet — the binding updated, but the field
            // stayed visually empty until a deletion forced a re-layout. The IBAN
            // branch escapes only because its keyboard is .asciiCapable.
            // UITextField renders the same input correctly (verified on device).
            VStack(alignment: .leading, spacing: 8) {
                Text("رقم الجوال")
                    .font(TamrinFont.font(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                PhoneDigitsField(text: $phoneNumber, placeholder: "05xxxxxxxx")
                    .padding(.horizontal, 16)
                    .frame(minHeight: 58)
                    .background(TamrinTheme.glass, in: .rect(cornerRadius: 20, style: .continuous))
            }
            .accessibilityElement(children: .contain)
        } else {
            VStack(spacing: 14) {
                PaymentEditorField(
                    title: "IBAN",
                    placeholder: "SA00 0000 0000 0000 0000 0000",
                    text: $iban,
                    keyboardType: .asciiCapable,
                    capitalization: .characters
                )
                .focused($focusedField, equals: .iban)

                PaymentEditorField(
                    title: "رقم الحساب",
                    placeholder: "اختياري",
                    text: $accountNumber,
                    keyboardType: .numberPad
                )
                .focused($focusedField, equals: .accountNumber)
            }
        }
    }

    private var bottomActions: some View {
        VStack(spacing: 10) {
            saveButton

            if existing != nil {
                TamrinActionButton(
                    title: "إزالة وسيلة الدفع",
                    systemImage: "trash",
                    role: .destructive,
                    prominent: false
                ) {
                    isRemoveConfirmationPresented = true
                }
                .tint(.red)
                .accessibilityHint("يحذف هذه الوسيلة من خيارات هذا التمرين")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var saveButton: some View {
        TamrinActionButton(
            title: existing == nil ? "إضافة وسيلة الدفع" : "حفظ التعديلات",
            tint: provider.brandColor
        ) {
            Haptics.impact(.medium)
            onSave(currentDraft)
        }
        .disabled(!isValid)
        .accessibilityHint(isValid ? "يحفظ بيانات وسيلة الدفع" : "أكمل البيانات المطلوبة أولاً")
    }

    private var isValid: Bool {
        currentDraft.isValid
    }

    private var currentDraft: PaymentMethodDraft {
        PaymentMethodDraft(
            provider: provider,
            phoneNumber: phoneNumber.trimmed,
            iban: iban.normalizedIBAN,
            accountNumber: accountNumber.trimmed
        )
    }
}

private struct PaymentEditorField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var capitalization: TextInputAutocapitalization = .never

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TamrinFont.font(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .font(TamrinFont.font(size: 17, weight: .medium))
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
                .multilineTextAlignment(.leading)
                .environment(\.layoutDirection, .leftToRight)
                .padding(.horizontal, 16)
                .frame(minHeight: 58)
                .background(TamrinTheme.glass, in: .rect(cornerRadius: 20, style: .continuous))
        }
        .accessibilityElement(children: .contain)
    }
}

/// The phone-number input, backed by UITextField rather than SwiftUI's TextField.
/// SwiftUI's field would not display digits as they were typed from numeric
/// keypads here (the binding received them; the field stayed blank until a
/// deletion forced a re-layout), so the digits go through UIKit directly.
private struct PhoneDigitsField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.keyboardType = .numberPad
        field.placeholder = placeholder
        field.font = TamrinFont.uiFont(size: 17, weight: .medium)
        field.textAlignment = .left
        field.semanticContentAttribute = .forceLeftToRight
        field.autocorrectionType = .no
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        // Mirrors the FocusState auto-focus the bank editor gets on push.
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        if field.text != text { field.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        @objc func changed(_ sender: UITextField) { text.wrappedValue = sender.text ?? "" }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedIBAN: String {
        uppercased().filter { !$0.isWhitespace }
    }
}
