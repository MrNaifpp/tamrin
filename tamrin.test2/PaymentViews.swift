import SwiftUI
import UIKit

enum RegistrationFlowStep: Equatable {
    case selection
    case methodPicker
    case methodDetails(UUID)
    case success
}

struct RegistrationFlowSheet: View {
    @Bindable var store: TamrinStore
    let occurrence: Occurrence
    var artName: String = "ExerciseArt1"
    var startStep: RegistrationFlowStep = .selection

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var step: RegistrationFlowStep = .selection
    @State private var didAppear = false
    @State private var registerMe = false
    @State private var guestNames: [String] = []
    @State private var showGuestSection = false
    @State private var didCopyIBAN = false
    @State private var fallbackAlert = false
    @FocusState private var focusedGuest: Int?

    private var title: String { store.currentPlan?.name ?? "التمرين الأسبوعي" }
    private var methods: [PaymentMethod] { store.methodsForCurrentTeam() }
    private var validGuests: [String] {
        guestNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private var canSubmit: Bool { registerMe || !validGuests.isEmpty }

    var body: some View {
        ZStack {
            switch step {
            case .selection:
                selectionStep
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
            case .methodPicker:
                methodPickerStep
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
            case .methodDetails(let id):
                methodDetailsStep(id: id)
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
            case .success:
                successStep
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.snappy(duration: 0.32), value: step)
        .environment(\.layoutDirection, .rightToLeft)
        .preferredColorScheme(.dark)
        .presentationDetents([.fraction(0.72), .large])
        .presentationDragIndicator(.visible)
        .alert("تم نسخ الآيبان", isPresented: $fallbackAlert) {
            Button("حسناً") {}
        } message: {
            Text("تعذر فتح تطبيق البنك. افتحه يدوياً والصق رقم الآيبان المنسوخ.")
        }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            step = startStep
        }
    }

    // MARK: - اختيار المسجلين

    private var selectionStep: some View {
        VStack(spacing: 0) {
            Text("سجـل في التمريـن")
                .font(TamrinFont.font(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 22)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    Image(artName)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 66)
                        .clipShape(.rect(cornerRadius: 12, style: .continuous))
                        .padding(.top, 16)

                    VStack(spacing: 4) {
                        Text(title)
                            .font(TamrinFont.font(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text("يوم \(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
                            .font(TamrinFont.font(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }

                    Text("اضغط على اسمك للتسجيل")
                        .font(TamrinFont.font(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 14)

                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.snappy(duration: 0.22)) { registerMe.toggle() }
                    } label: {
                        HStack(spacing: 12) {
                            PlanMemberAvatar(name: store.profile?.name ?? "", size: 34, tint: .white.opacity(0.35))
                            Text(store.profile?.name ?? "أنا")
                                .font(TamrinFont.font(size: 16, weight: .medium))
                                .foregroundStyle(registerMe ? TamrinTheme.ink : .white)
                            Spacer()
                            if registerMe {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(TamrinTheme.ink)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 56)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        registerMe ? .regular.tint(.white.opacity(0.92)).interactive() : .regular.interactive(),
                        in: .capsule
                    )

                    Divider().overlay(.white.opacity(0.1)).padding(.vertical, 2)

                    if showGuestSection {
                        VStack(spacing: 10) {
                            Text("سجل شخص إضافي")
                                .font(TamrinFont.font(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            ForEach(guestNames.indices, id: \.self) { index in
                                TextField("الاسم الكامل", text: $guestNames[index])
                                    .font(TamrinFont.font(size: 16, weight: .medium))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .focused($focusedGuest, equals: index)
                                    .padding(.horizontal, 14)
                                    .frame(height: 52)
                                    .glassEffect(.regular, in: .capsule)
                            }

                            Button {
                                guestNames.append("")
                                focusedGuest = guestNames.count - 1
                            } label: {
                                Label("يسجل واحد زيادة", systemImage: "plus")
                                    .font(TamrinFont.font(size: 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 52)
                                    .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }
                    } else {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) {
                                showGuestSection = true
                                guestNames = [""]
                            }
                            focusedGuest = 0
                        } label: {
                            Label("يسجل معي أحد", systemImage: "plus")
                                .font(TamrinFont.font(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }

                    let others = store.registrations(for: occurrence).prefix(3)
                    if !others.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(Array(others), id: \.id) { person in
                                HStack(spacing: 12) {
                                    PlanMemberAvatar(name: person.displayName, size: 30, tint: .white.opacity(0.25))
                                    Text(person.displayName)
                                        .font(TamrinFont.font(size: 15, weight: .medium))
                                        .foregroundStyle(.white)
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 48)
                                .background(.white.opacity(0.06), in: .rect(cornerRadius: 15, style: .continuous))
                            }
                        }
                        .opacity(0.4)
                        .blur(radius: 1.6)
                        .allowsHitTesting(false)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }

            Button {
                submitRegistration()
            } label: {
                Text("سجـل")
                    .font(TamrinFont.font(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(Color(red: 0.20, green: 0.47, blue: 0.96))
            .disabled(!canSubmit)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func submitRegistration() {
        if registerMe { store.register(for: occurrence) }
        if !validGuests.isEmpty { store.registerGuests(names: validGuests, for: occurrence) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        let owesPayment = registerMe && occurrence.price > 0 && store.payment(for: occurrence)?.status == PaymentStatus.unpaid
        if owesPayment && !methods.isEmpty {
            step = .methodPicker
        } else {
            step = .success
        }
    }

    // MARK: - اختيار طريقة الدفع

    private var methodPickerStep: some View {
        VStack(spacing: 0) {
            sheetHeader(title: "اختر طريقة الدفع") { dismiss() }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(methods, id: \.id) { method in
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            step = .methodDetails(method.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: method.kind == .bank ? "building.columns.fill" : "banknote.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(TamrinTheme.ink)
                                    .frame(width: 38, height: 38)
                                    .background(.white, in: .circle)

                                Text(method.title)
                                    .font(TamrinFont.font(size: 16, weight: .medium))
                                    .foregroundStyle(.white)

                                Spacer()

                                Image(systemName: "chevron.backward")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 60)
                            .contentShape(.rect(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            Button {
                step = .success
            } label: {
                Text("أدفع لاحقًا")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)
        }
    }

    // MARK: - تفاصيل طريقة الدفع

    private func methodDetailsStep(id: UUID) -> some View {
        let method = methods.first { $0.id == id }

        return VStack(spacing: 0) {
            sheetHeader(title: "تفاصيل الدفع") { step = .methodPicker }

            if let method {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        VStack(spacing: 10) {
                            Image(systemName: method.kind == .bank ? "building.columns.fill" : "banknote.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 58, height: 58)
                                .background(Color(red: 0.20, green: 0.35, blue: 0.95), in: .circle)

                            Text(method.title)
                                .font(TamrinFont.font(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .padding(.top, 12)

                        if method.kind == .bank, !method.iban.isEmpty {
                            Button {
                                UIPasteboard.general.string = method.iban
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                withAnimation(.snappy) { didCopyIBAN = true }
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    withAnimation(.snappy) { didCopyIBAN = false }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: didCopyIBAN ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(didCopyIBAN ? TamrinTheme.lime : .white.opacity(0.6))

                                    Spacer()

                                    Text(method.iban)
                                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 52)
                                .contentShape(.rect(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }

                        HStack {
                            Text("القطة")
                                .font(TamrinFont.font(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            Text("\(occurrence.price.cleanAmount) ﷼")
                                .font(TamrinFont.font(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 52)
                        .glassEffect(.regular, in: .capsule)
                    }
                    .padding(.horizontal, 20)
                }

                VStack(spacing: 8) {
                    if method.kind == .bank {
                        Button {
                            UIPasteboard.general.string = method.iban
                            guard let url = URL(string: method.appURL), !method.appURL.isEmpty else {
                                fallbackAlert = true
                                return
                            }
                            openURL(url) { accepted in
                                if !accepted { fallbackAlert = true }
                            }
                        } label: {
                            Label("افتح تطبيق \(method.title)", systemImage: "arrow.up.forward.app")
                                .font(TamrinFont.font(size: 16, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .tint(Color(red: 0.16, green: 0.25, blue: 0.95))
                    }

                    Button {
                        store.declarePaid(occurrence)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        step = .success
                    } label: {
                        Text(method.kind == .bank ? "حوّلت المبلغ" : "سأدفع نقدًا في الملعب")
                            .font(TamrinFont.font(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            }
        }
    }

    // MARK: - النجاح

    private var successStep: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle().fill(Color(red: 0.30, green: 0.72, blue: 0.36))
                Image(systemName: "checkmark")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 84, height: 84)
            .shadow(color: Color(red: 0.30, green: 0.72, blue: 0.36).opacity(0.4), radius: 24, y: 8)

            Text("أنت مسجل")
                .font(TamrinFont.font(size: 26, weight: .bold))
                .foregroundStyle(.white)

            Text("حياك الله، نشوفك في التمرين")
                .font(TamrinFont.font(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("تم")
                    .font(TamrinFont.font(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(Color(red: 0.20, green: 0.47, blue: 0.96))
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func sheetHeader(title: String, onClose: @escaping () -> Void) -> some View {
        ZStack {
            Text(title)
                .font(TamrinFont.font(size: 17, weight: .bold))
                .foregroundStyle(.white)

            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

private enum PaymentOrganizerFilter: String, CaseIterable, Identifiable {
    case needsAction, unpaid, confirmed
    var id: String { rawValue }
    var title: String {
        switch self { case .needsAction: "تحتاج إجراء"; case .unpaid: "لم يدفعوا"; case .confirmed: "مكتملة" }
    }
}

struct PaymentOrganizerView: View {
    @Bindable var store: TamrinStore
    @Environment(\.dismiss) private var dismiss
    @State private var filter: PaymentOrganizerFilter = .needsAction
    @State private var selectedOccurrence: Occurrence?

    private var teamRecords: [PaymentRecord] {
        let occurrenceIDs = Set(store.teamOccurrences.map(\.id))
        return store.paymentRecords.filter { occurrenceIDs.contains($0.occurrenceID) }
    }
    private var displayedRecords: [PaymentRecord] {
        teamRecords.filter { record in
            switch filter {
            case .needsAction: record.status == .declared
            case .unpaid: record.status == .unpaid
            case .confirmed: record.status == .confirmed
            }
        }
    }
    private var pendingMembers: [Membership] {
        guard let teamID = store.currentTeam?.id else { return [] }
        return store.memberships.filter { $0.teamID == teamID && $0.isPending }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.055, green: 0.055, blue: 0.06).ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        if store.isAdmin { adminContent } else { memberContent }
                    }
                    .padding(20)
                    .padding(.bottom, 30)
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
            .colorScheme(.dark)
            .navigationTitle(store.isAdmin ? "تنظيم الدفع" : "دفعاتي")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("تم") { dismiss() } }
            }
            .sheet(item: $selectedOccurrence) { occurrence in
                if store.myRegistration(for: occurrence) == nil {
                    RegistrationFlowSheet(store: store, occurrence: occurrence)
                } else {
                    PaymentSheet(store: store, occurrence: occurrence)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var adminContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("صورة القَطّة")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("\(confirmedTotal.cleanAmount)")
                        .font(TamrinFont.font(size: 46, weight: .bold))
                    Text("﷼ مؤكدة")
                        .font(TamrinFont.font(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                HStack(spacing: 8) {
                    organizerStat("ينتظر التأكيد", count: teamRecords.filter { $0.status == .declared }.count, color: .orange)
                    organizerStat("متأخرة", count: teamRecords.filter { $0.status == .unpaid }.count, color: .pink)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [Color(red: 0.12, green: 0.24, blue: 0.18), Color(red: 0.08, green: 0.09, blue: 0.1)], startPoint: .topTrailing, endPoint: .bottomLeading),
                in: .rect(cornerRadius: 28, style: .continuous)
            )

            if !pendingMembers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("طلبات الانضمام", detail: "\(pendingMembers.count)")
                    ForEach(pendingMembers, id: \.id) { member in
                        HStack(spacing: 10) {
                            PlanMemberAvatar(name: member.displayName, size: 36, tint: .white.opacity(0.2))
                            Text(member.displayName).font(TamrinFont.font(size: 15, weight: .bold))
                            Spacer()
                            Button("رفض") { store.reject(member) }.buttonStyle(.bordered)
                            Button("قبول") { store.approve(member) }
                                .buttonStyle(.borderedProminent).tint(TamrinTheme.lime).foregroundStyle(TamrinTheme.ink)
                        }
                        .padding(12)
                        .background(.white.opacity(0.06), in: .rect(cornerRadius: 18, style: .continuous))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("التحويلات", detail: "مرتبة حسب الإجراء")
                Picker("حالة الدفع", selection: $filter) {
                    ForEach(PaymentOrganizerFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if displayedRecords.isEmpty {
                    ContentUnavailableView("كل شيء مرتب", systemImage: "checkmark.seal.fill", description: Text("لا توجد عمليات في هذا التصنيف الآن."))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                } else {
                    ForEach(displayedRecords, id: \.id) { record in
                        PaymentAdminRow(store: store, record: record, name: name(for: record))
                    }
                }
            }
        }
    }

    private var memberContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("القَطّات القادمة")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text("كل دفعة في مكانها")
                    .font(TamrinFont.font(size: 29, weight: .bold))
                Text("سجّل، حوّل، ثم أخبر المشرف — ثلاث خطوات واضحة بدون رسائل متفرقة.")
                    .font(TamrinFont.font(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .background(
                LinearGradient(colors: [Color(red: 0.18, green: 0.27, blue: 0.48), Color(red: 0.08, green: 0.09, blue: 0.12)], startPoint: .topTrailing, endPoint: .bottomLeading),
                in: .rect(cornerRadius: 28, style: .continuous)
            )

            ForEach(store.teamOccurrences.prefix(5), id: \.id) { occurrence in
                let registration = store.myRegistration(for: occurrence)
                let payment = store.payment(for: occurrence)
                Button { selectedOccurrence = occurrence } label: {
                    HStack(spacing: 13) {
                        VStack(spacing: 2) {
                            Text(occurrence.startAt.formatted(.dateTime.day()))
                                .font(TamrinFont.font(size: 22, weight: .bold))
                            Text(occurrence.startAt.formatted(.dateTime.month(.abbreviated)))
                                .font(TamrinFont.font(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .frame(width: 48, height: 54)
                        .background(.white.opacity(0.08), in: .rect(cornerRadius: 15, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.plan(for: occurrence)?.name ?? "تمرين المجموعة")
                                .font(TamrinFont.font(size: 16, weight: .bold))
                            Text(memberStatus(registration: registration, payment: payment, price: occurrence.price))
                                .font(TamrinFont.font(size: 12, weight: .medium))
                                .foregroundStyle(memberStatusColor(payment: payment))
                        }
                        Spacer()
                        Text(occurrence.price == 0 ? "مجاني" : "\(occurrence.price.cleanAmount) ﷼")
                            .font(TamrinFont.font(size: 14, weight: .bold))
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.white.opacity(0.06), in: .rect(cornerRadius: 21, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var confirmedTotal: Double {
        let confirmed = teamRecords.filter { $0.status == .confirmed }.count
        guard let price = store.teamOccurrences.first?.price else { return 0 }
        return Double(confirmed) * price
    }

    private func organizerStat(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(count) \(title)").font(TamrinFont.font(size: 12, weight: .medium))
        }
        .padding(.horizontal, 11).frame(height: 32)
        .background(.white.opacity(0.08), in: .capsule)
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack { Text(title).font(TamrinFont.font(size: 18, weight: .bold)); Spacer(); Text(detail).font(TamrinFont.font(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.45)) }
    }

    private func name(for record: PaymentRecord) -> String {
        store.registrations.first { $0.userID == record.userID && $0.occurrenceID == record.occurrenceID }?.displayName ?? "عضو"
    }

    private func memberStatus(registration: Registration?, payment: PaymentRecord?, price: Double) -> String {
        guard registration != nil else { return "متاح للتسجيل" }
        guard price > 0 else { return "مسجل — لا تحتاج دفع" }
        switch payment?.status {
        case .declared: return "بانتظار تأكيد المشرف"
        case .confirmed: return "تم تأكيد الدفع"
        default: return "مسجل — باقي الدفع"
        }
    }

    private func memberStatusColor(payment: PaymentRecord?) -> Color {
        switch payment?.status { case .declared: .orange; case .confirmed: TamrinTheme.lime; default: .white.opacity(0.55) }
    }
}

struct PaymentSheet: View {
    @Bindable var store: TamrinStore
    let occurrence: Occurrence
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var selectedID: UUID?
    @State private var attemptedOpen = false
    @State private var fallbackAlert = false

    private var methods: [PaymentMethod] { store.methodsForCurrentTeam() }
    private var selected: PaymentMethod? { methods.first { $0.id == selectedID } ?? methods.first }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(intensity: 0.7)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 30).fill(LinearGradient(colors: [TamrinTheme.ink, Color(red: 0.18, green: 0.23, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            Circle().fill(TamrinTheme.lime.opacity(0.28)).frame(width: 200, height: 200).blur(radius: 46).offset(x: 110, y: -70)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("قَطّة \(occurrence.startAt.arabicDay)").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.58))
                                Text("\(occurrence.price.cleanAmount) ر.س").font(TamrinFont.font(size: 54, weight: .bold)).foregroundStyle(.white)
                                Text("بعد التحويل، أخبر المشرف بضغطة واحدة.").font(.subheadline).foregroundStyle(.white.opacity(0.64))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                        }.frame(height: 190).clipShape(.rect(cornerRadius: 30)).shadow(color: .black.opacity(0.16), radius: 24, y: 12)
                        if methods.isEmpty { ContentUnavailableView("لا توجد طريقة دفع", systemImage: "creditcard", description: Text("اطلب من المشرف إضافة بيانات الدفع.")) }
                        else {
                            Picker("طريقة الدفع", selection: Binding(get: { selectedID ?? methods.first?.id }, set: { selectedID = $0 })) {
                                ForEach(methods, id: \.id) { method in
                                    Text(method.title).tag(Optional(method.id))
                                }
                            }.pickerStyle(.segmented)
                            if let method = selected { methodCard(method) }
                            if attemptedOpen {
                                VStack(alignment: .leading, spacing: 8) { Text("رجعت؟").font(TamrinFont.title2); Text("إذا تم التحويل، أخبر المشرف ليؤكد العملية.").foregroundStyle(.secondary) }
                                    .padding(18).background(TamrinTheme.glass, in: .rect(cornerRadius: 22))
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }.padding(22).padding(.bottom, 100)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button(attemptedOpen ? "دفعت" : (selected?.kind == .cash ? "سأدفع نقداً" : "دفعت")) { store.declarePaid(occurrence); UINotificationFeedbackGenerator().notificationOccurred(.success); dismiss() }.buttonStyle(PrimaryActionStyle())
                    Button("باقي") { dismiss() }.font(.subheadline.weight(.semibold)).padding(.vertical, 6)
                }.padding(.horizontal, 18).padding(.top, 12).background(.ultraThinMaterial)
            }
            .navigationTitle("الدفع").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
            .alert("تم نسخ الآيبان", isPresented: $fallbackAlert) { Button("حسناً") {} } message: { Text("تعذر فتح تطبيق البنك. افتحه يدوياً والصق رقم الآيبان المنسوخ.") }
            .animation(.snappy, value: attemptedOpen)
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    @ViewBuilder private func methodCard(_ method: PaymentMethod) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Image(systemName: method.kind == .bank ? "building.columns.fill" : "banknote.fill").font(.title2).frame(width: 48, height: 48).background(.black, in: .circle).foregroundStyle(.white); VStack(alignment: .leading) { Text(method.title).font(TamrinFont.headline); Text(method.kind == .bank ? "تحويل بنكي" : "دفع في الملعب").font(.caption).foregroundStyle(.secondary) }; Spacer() }
            if method.kind == .bank {
                VStack(alignment: .leading, spacing: 6) {
                    Text("IBAN").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack { Text(method.iban).font(.system(.body, design: .monospaced)).textSelection(.enabled); Spacer(); Button { UIPasteboard.general.string = method.iban; UIImpactFeedbackGenerator(style: .light).impactOccurred() } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.bordered) }
                    if !method.accountHolder.isEmpty { Text(method.accountHolder).font(.subheadline).foregroundStyle(.secondary) }
                }
                Button { openBank(method) } label: { Label("افتح تطبيق \(method.title)", systemImage: "arrow.up.forward.app") }.buttonStyle(SecondaryActionStyle())
            } else { Text("أخبر المشرف بعد تسليم المبلغ ليؤكد الدفعة.").font(.subheadline).foregroundStyle(.secondary) }
        }.padding(20).background(TamrinTheme.glass, in: .rect(cornerRadius: 26)).overlay(RoundedRectangle(cornerRadius: 26).stroke(TamrinTheme.hairline)).shadow(color: .black.opacity(0.05), radius: 20, y: 8)
    }

    private func openBank(_ method: PaymentMethod) {
        UIPasteboard.general.string = method.iban; attemptedOpen = true
        guard let url = URL(string: method.appURL), !method.appURL.isEmpty else { fallbackAlert = true; return }
        openURL(url) { accepted in if !accepted { fallbackAlert = true } }
    }
}

struct PaymentAdminRow: View {
    @Bindable var store: TamrinStore
    let record: PaymentRecord; let name: String
    var body: some View {
        VStack(spacing: 10) {
            HStack { Circle().fill(.black).frame(width: 36, height: 36).overlay(Text(String(name.prefix(1))).foregroundStyle(.white).font(.caption.bold())); Text(name).font(TamrinFont.headline); Spacer(); StatusPill(text: label, color: color, symbol: symbol) }
            if record.status == .declared { HStack { Button("رفض") { store.rejectPayment(record) }.buttonStyle(.bordered); Button("تأكيد الدفع") { store.confirmPayment(record) }.buttonStyle(.borderedProminent).tint(.black) } }
            else if record.status == .unpaid { Button { store.remind(record) } label: { Label("إرسال تذكير", systemImage: "bell") }.font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(14).background(TamrinTheme.secondary, in: .rect(cornerRadius: 16))
    }
    private var label: String { switch record.status { case .unpaid: "لم يدفع"; case .declared: "قال إنه دفع"; case .confirmed: "مؤكد" } }
    private var color: Color { switch record.status { case .unpaid: .secondary; case .declared: .orange; case .confirmed: .green } }
    private var symbol: String { switch record.status { case .unpaid: "clock"; case .declared: "questionmark"; case .confirmed: "checkmark" } }
}
