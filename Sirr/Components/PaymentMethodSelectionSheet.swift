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
            .background(TamrinTheme.page)
            .navigationTitle("وسائل الدفع")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("إغلاق") { dismiss() }
                        .font(TamrinFont.font(size: 16, weight: .medium))
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
                            wasExisting ? "تم حفظ تعديلات \(provider.displayName)" : "تمت إضافة \(provider.displayName)",
                            symbol: "checkmark.circle.fill"
                        )
                    },
                    onRemove: {
                        remove(provider)
                        isEditorPresented = false
                        showToast("تمت إزالة \(provider.displayName)", symbol: "trash.fill")
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
            UISelectionFeedbackGenerator().selectionChanged()
            if isSelected {
                remove(.cash)
                showToast("تمت إزالة الدفع كاش", symbol: "trash.fill")
            } else {
                upsert(PaymentMethodDraft(provider: .cash))
                showToast("تمت إضافة الدفع كاش", symbol: "checkmark.circle.fill")
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
            UISelectionFeedbackGenerator().selectionChanged()
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
        case phoneNumber, iban, accountNumber
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
        .background(TamrinTheme.page)
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
            focusedField = provider.requiresPhone ? .phoneNumber : .iban
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
            PaymentEditorField(
                title: "رقم الجوال",
                placeholder: "05xxxxxxxx",
                text: $phoneNumber,
                keyboardType: .phonePad,
                textContentType: .telephoneNumber
            )
            .focused($focusedField, equals: .phoneNumber)
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
        .background(.ultraThinMaterial)
    }

    private var saveButton: some View {
        TamrinActionButton(
            title: existing == nil ? "إضافة وسيلة الدفع" : "حفظ التعديلات",
            tint: provider.brandColor
        ) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedIBAN: String {
        uppercased().filter { !$0.isWhitespace }
    }
}
