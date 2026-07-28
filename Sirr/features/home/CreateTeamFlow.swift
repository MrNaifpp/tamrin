import SwiftUI
import MapKit
import PhotosUI
import Observation
import Contacts
import ContactsUI

@MainActor @Observable
final class LocationSearchService {
    struct Result: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let latitude: Double
        let longitude: Double
    }

    var results: [Result] = []

    func search(_ query: String) async {
        guard query.count > 2 else { results = []; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753),
            span: MKCoordinateSpan(latitudeDelta: 0.7, longitudeDelta: 0.7)
        )
        guard let response = try? await MKLocalSearch(request: request).start() else { return }
        results = response.mapItems.prefix(6).map {
            let coordinate = $0.location.coordinate
            let address = $0.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true) ?? "الرياض"
            return Result(title: $0.name ?? query, subtitle: address, latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }
}

private enum CreationStep: Int, CaseIterable {
    case identity, templates, members

    var title: String {
        switch self {
        case .identity: "هوية المجموعة"
        case .templates: "تمارين المجموعة"
        case .members: "الأعضاء"
        }
    }

    var counter: String {
        switch self {
        case .identity: "١ من ٣"
        case .templates: "٢ من ٣"
        case .members: "٣ من ٣"
        }
    }
}

private let weekdayNames: [Int: String] = [1: "الأحد", 2: "الاثنين", 3: "الثلاثاء", 4: "الأربعاء", 5: "الخميس", 6: "الجمعة", 7: "السبت"]

private extension Int {
    var arabicDigits: String { formatted(.number.locale(Locale(identifier: "ar_SA")).grouping(.never)) }
}

private extension PlanDraft {
    var daysSummary: String {
        if scheduleKind == .oneOff { return oneOffDate.arabicDate }
        if weekdays.count == 7 { return "كل يوم" }
        if weekdays.isEmpty { return "" }
        return weekdays.sorted().compactMap { weekdayNames[$0] }.joined(separator: "، ")
    }

    var timeSummary: String { "\(startTime.arabicTime) – \(endTime.arabicTime)" }

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (scheduleKind == .oneOff || !weekdays.isEmpty) &&
        !locationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        totalVenueCost > 0 &&
        !paymentMethods.isEmpty &&
        paymentMethods.allSatisfy(\.isValid)
    }
}

struct CreateTeamFlow: View {
    @Bindable var feed: HomeStore
    @Binding var isPresented: Bool
    @State private var draft = TeamDraft()
    @State private var step: CreationStep = .identity
    @State private var goingForward = true
    @State private var isComposing = false
    @State private var composerPlan = PlanDraft()
    @State private var composerInitialSheet: ComposerSheet?
    @State private var createdTeam: FeedTeam?
    @State private var isCreating = false
    @State private var failureMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .push(from: goingForward ? .trailing : .leading)
    }

    var body: some View {
        ZStack {
            TamrinTheme.page.ignoresSafeArea()
            Circle().fill(.primary.opacity(0.035)).frame(width: 340, height: 340).blur(radius: 70)
                .offset(x: 150, y: -300).ignoresSafeArea().allowsHitTesting(false)

            if let createdTeam {
                CreationSuccessPage(team: createdTeam, draft: draft) { isPresented = false }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                VStack(spacing: 0) {
                    FlowHeader(step: step, back: goBack)
                    ZStack {
                        switch step {
                        case .identity:
                            IdentityStepPage(draft: $draft, advance: advanceFromIdentity)
                                .transition(stepTransition)
                        case .templates:
                            if isComposing {
                                TemplateComposerPage(
                                    plan: $composerPlan,
                                    initialSheet: composerInitialSheet,
                                    save: savePlan,
                                    cancel: cancelComposer
                                )
                                .transition(stepTransition)
                            } else {
                                TemplatesListPage(
                                    draft: $draft,
                                    addPlan: { startComposer(with: PlanDraft()) },
                                    editPlan: { startComposer(with: $0) },
                                    advance: { move(to: .members) }
                                )
                                .transition(stepTransition)
                            }
                        case .members:
                            MembersStepPage(draft: $draft, isCreating: isCreating, create: create)
                                .transition(stepTransition)
                        }
                    }
                    .animation(reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.9), value: step)
                    .animation(reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.9), value: isComposing)
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.9), value: createdTeam?.id)
        .environment(\.layoutDirection, .rightToLeft)
        .interactiveDismissDisabled()
        .alert("تعذر إنشاء المجموعة", isPresented: Binding(
            get: { failureMessage != nil },
            set: { if !$0 { failureMessage = nil } }
        )) {
            Button("حسنًا", role: .cancel) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
                .font(TamrinFont.body)
        }
    }

    private func move(to next: CreationStep) {
        goingForward = next.rawValue > step.rawValue
        withAnimation { step = next }
    }

    private func advanceFromIdentity() {
        guard !draft.teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        goingForward = true
        if draft.plans.isEmpty {
            composerPlan = PlanDraft()
            isComposing = true
        }
        withAnimation { step = .templates }
    }

    private func startComposer(with plan: PlanDraft) {
        composerPlan = plan
        goingForward = true
        composerInitialSheet = nil
        withAnimation { isComposing = true }
    }

    private func savePlan() {
        if let index = draft.plans.firstIndex(where: { $0.id == composerPlan.id }) {
            draft.plans[index] = composerPlan
        } else {
            draft.plans.append(composerPlan)
        }
        goingForward = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { isComposing = false }
    }

    private func cancelComposer() {
        goingForward = false
        if draft.plans.isEmpty {
            withAnimation { isComposing = false; step = .identity }
        } else {
            withAnimation { isComposing = false }
        }
    }

    private func create() {
        guard !isCreating else { return }
        isCreating = true
        Task {
            do {
                let team = try await feed.createTeam(from: draft)
                createdTeam = team
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                failureMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isCreating = false
        }
    }

    private func goBack() {
        switch step {
        case .identity:
            isPresented = false
        case .templates:
            if isComposing { cancelComposer() } else { move(to: .identity) }
        case .members:
            move(to: .templates)
        }
    }
}

// MARK: - Header

private struct FlowHeader: View {
    let step: CreationStep
    let back: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button(action: back) {
                    Image(systemName: step == .identity ? "xmark" : "chevron.right")
                        .font(.system(size: TamrinControlMetrics.symbolSize, weight: .semibold))
                        .frame(width: TamrinControlMetrics.touchTarget, height: TamrinControlMetrics.touchTarget)
                }
                .buttonStyle(.plain)
                .background(TamrinTheme.glass, in: .circle)
                .accessibilityLabel(step == .identity ? "إغلاق" : "رجوع")

                Spacer()

                Text(step.title)
                    .font(TamrinFont.headline)
                    .contentTransition(.opacity)

                Spacer()

                Text(step.counter)
                    .font(TamrinFont.font(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 42)
            }

            HStack(spacing: 6) {
                ForEach(CreationStep.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.09)))
                        .frame(height: 4)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: step)
    }
}

// MARK: - Step 1: Identity

private struct IdentityStepPage: View {
    @Binding var draft: TeamDraft
    let advance: () -> Void
    @State private var photoItem: PhotosPickerItem?
    @FocusState private var nameFocused: Bool

    private let symbols = ["figure.soccer", "figure.run", "figure.strengthtraining.traditional", "figure.basketball", "figure.hiking", "figure.pool.swim", "figure.volleyball", "figure.badminton"]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 18)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        Group {
                            if let data = draft.avatarData, let image = UIImage(data: data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                ZStack {
                                    TamrinTheme.secondary
                                    Image(systemName: draft.teamSymbol)
                                        .font(.system(size: 52, weight: .semibold))
                                        .foregroundStyle(TamrinTheme.ink.opacity(0.72))
                                }
                            }
                        }
                        .frame(width: 138, height: 138)
                        .clipShape(.rect(cornerRadius: 42, style: .continuous))
                        .shadow(color: .black.opacity(0.09), radius: 26, y: 12)

                        Image(systemName: "camera.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(TamrinTheme.ink, in: .circle)
                            .offset(x: -6, y: 8)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("صورة المجموعة")

                Text(draft.avatarData == nil ? "أضف صورة للمجموعة" : "اضغط لتغيير الصورة")
                    .font(TamrinFont.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 14)

                TextField("اسم المجموعة", text: $draft.teamName)
                    .font(TamrinFont.title)
                    .multilineTextAlignment(.center)
                    .focused($nameFocused)
                    .submitLabel(.continue)
                    .onSubmit(advance)
                    .padding(.vertical, 18)
                    .padding(.horizontal, 42)
                    .padding(.top, 26)

                VStack(spacing: 14) {
                    Text("أو اختر رمزًا يعبر عنكم")
                        .font(TamrinFont.footnote)
                        .foregroundStyle(.tertiary)
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(symbols, id: \.self) { symbol in
                                Button {
                                    draft.teamSymbol = symbol
                                    draft.avatarData = nil
                                    photoItem = nil
                                    UISelectionFeedbackGenerator().selectionChanged()
                                } label: {
                                    Image(systemName: symbol)
                                        .font(.system(size: TamrinControlMetrics.symbolSize, weight: .semibold))
                                        .foregroundStyle(isSymbolSelected(symbol) ? .white : .secondary)
                                        .frame(width: TamrinControlMetrics.roundButton, height: TamrinControlMetrics.roundButton)
                                        .background(isSymbolSelected(symbol) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(TamrinTheme.glass), in: .circle)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(isSymbolSelected(symbol) ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 6)
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(.top, 34)

                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            TamrinActionButton(title: "متابعة", action: advance)
                .disabled(draft.teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, 22)
                .padding(.bottom, 10)
        }
        .onChange(of: photoItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) { draft.avatarData = data }
            }
        }
        .onAppear { if draft.teamName.isEmpty { nameFocused = true } }
    }

    private func isSymbolSelected(_ symbol: String) -> Bool {
        draft.avatarData == nil && draft.teamSymbol == symbol
    }
}

// MARK: - Step 2: Templates list

private struct TemplatesListPage: View {
    @Binding var draft: TeamDraft
    let addPlan: () -> Void
    let editPlan: (PlanDraft) -> Void
    let advance: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("تمارينكم جاهزة")
                        .font(TamrinFont.largeTitle)
                        .tracking(-0.8)
                    Text("كل قالب ينشئ مواعيده أسبوعيًا بشكل تلقائي. أضف ما تحتاجه من تمارين.")
                        .font(TamrinFont.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                VStack(spacing: 12) {
                    ForEach(draft.plans) { plan in
                        TemplateCard(plan: plan) {
                            editPlan(plan)
                        } delete: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                draft.plans.removeAll { $0.id == plan.id }
                            }
                        }
                    }
                }

                Button(action: addPlan) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.headline)
                        Text("أنشئ تمرينًا آخر")
                            .font(TamrinFont.headline)
                    }
                    .foregroundStyle(TamrinTheme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: TamrinControlMetrics.actionHeight)
                    .background(TamrinTheme.secondary.opacity(0.78), in: .rect(cornerRadius: 24, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(SpringCardPressStyle())

                Spacer(minLength: 30)
            }
            .padding(.horizontal, 22)
        }
        .safeAreaInset(edge: .bottom) {
            TamrinActionButton(title: "متابعة", action: advance)
                .disabled(draft.plans.isEmpty)
                .padding(.horizontal, 22)
                .padding(.bottom, 10)
        }
    }
}

private struct TemplateCard: View {
    let plan: PlanDraft
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: edit) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(plan.name)
                            .font(TamrinFont.title3)
                        Text("\(plan.daysSummary) · \(plan.timeSummary)")
                            .font(TamrinFont.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        Button("تعديل", systemImage: "pencil", action: edit)
                        Button("حذف", systemImage: "trash", role: .destructive, action: delete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(TamrinTheme.secondary, in: .circle)
                    }
                }
                HStack(spacing: 8) {
                    TemplateTag(symbol: "mappin", text: plan.locationName)
                    TemplateTag(symbol: "person.2", text: "\(plan.capacity.arabicDigits) لاعب")
                    TemplateTag(
                        symbol: "banknote",
                        text: plan.totalVenueCost == 0
                            ? "بدون تكلفة"
                            : "القطة \(plan.pricePerPerson.cleanAmount) ر.س"
                    )
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TamrinTheme.glass, in: .rect(cornerRadius: 26))
            .shadow(color: .black.opacity(0.05), radius: 20, y: 10)
            .contentShape(.rect)
        }
        .buttonStyle(SpringCardPressStyle())
    }
}

private struct TemplateTag: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).lineLimit(1)
        } icon: {
            Image(systemName: symbol)
        }
        .font(TamrinFont.font(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(TamrinTheme.secondary.opacity(0.72), in: .capsule)
    }
}

// MARK: - Step 2: Template composer

private enum ComposerSheet: String, Identifiable {
    case schedule, location, capacity, venueCost, payment, publishing
    var id: String { rawValue }
}

private struct TemplateComposerPage: View {
    @Binding var plan: PlanDraft
    var initialSheet: ComposerSheet?
    let save: () -> Void
    let cancel: () -> Void

    @State private var activeSheet: ComposerSheet?
    @State private var locationSearch = LocationSearchService()
    @FocusState private var nameFocused: Bool

    private let nameSuggestions = ["كورة الأسبوع", "تمرين اللياقة", "شوط الخميس"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("صمّم التمرين")
                        .font(TamrinFont.largeTitle)
                        .tracking(-0.8)
                    Text("سمّه، وحدد تفاصيله بلمسة على كل بطاقة.")
                        .font(TamrinFont.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 10) {
                    TextField("اسم التمرين", text: $plan.name)
                        .font(TamrinFont.title2)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .padding(.horizontal, 18)
                        .frame(height: 62)
                        .background(TamrinTheme.glass, in: .rect(cornerRadius: 21))

                    if plan.name.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(nameSuggestions, id: \.self) { suggestion in
                                Button {
                                    plan.name = suggestion
                                    UISelectionFeedbackGenerator().selectionChanged()
                                } label: {
                                    Text(suggestion)
                                        .font(TamrinFont.font(size: 13, weight: .medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(TamrinTheme.secondary, in: .capsule)
                                        .foregroundStyle(.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: plan.name.isEmpty)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ComposerTile(
                        symbol: "calendar",
                        title: "الأيام والوقت",
                        value: plan.weekdays.isEmpty ? nil : "\(plan.daysSummary)\n\(plan.timeSummary)"
                    ) { activeSheet = .schedule }
                    ComposerTile(
                        symbol: "mappin.and.ellipse",
                        title: "الملعب",
                        value: plan.locationName.isEmpty ? nil : plan.locationName
                    ) { activeSheet = .location }
                    ComposerTile(
                        symbol: "person.2.fill",
                        title: "عدد اللاعبين",
                        value: "حتى \(plan.capacity.arabicDigits)\n\(plan.capacityPolicy == .waitlist ? "مع قائمة انتظار" : "يقفل عند الاكتمال")"
                    ) { activeSheet = .capacity }
                    ComposerTile(
                        symbol: "banknote.fill",
                        title: "قيمة الملعب",
                        value: plan.totalVenueCost == 0
                            ? nil
                            : "\(plan.totalVenueCost.cleanAmount) ر.س\nالقطة \(plan.pricePerPerson.cleanAmount) ر.س"
                    ) { activeSheet = .venueCost }
                    ComposerTile(
                        symbol: "creditcard.fill",
                        title: "وسائل الدفع",
                        value: plan.paymentMethods.isEmpty
                            ? nil
                            : (plan.paymentMethods.count == 1
                               ? plan.paymentMethods[0].provider.displayName
                               : "\(plan.paymentMethods.count.arabicDigits) وسائل دفع")
                    ) { activeSheet = .payment }
                    ComposerTile(
                        symbol: "paperplane.fill",
                        title: "التجهيز والإرسال",
                        value: "قبلها بـ\(plan.publishLeadDays.arabicDigits) يوم\nالساعة \(plan.publishTime.arabicTime)"
                    ) { activeSheet = .publishing }
                }

                Text("تقدر تعدّل أي موعد لحاله لاحقًا بدون تغيير القالب.")
                    .font(TamrinFont.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)

                Spacer(minLength: 30)
            }
            .padding(.horizontal, 22)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            TamrinActionButton(title: "احفظ التمرين", action: save)
                .disabled(!plan.isComplete)
                .padding(.horizontal, 22)
                .padding(.bottom, 10)
        }
        .sheet(item: $activeSheet) { item in
            switch item {
            case .schedule:
                ScheduleSheet(plan: $plan)
            case .location:
                LocationSheet(plan: $plan, search: locationSearch)
            case .capacity:
                CapacitySheet(plan: $plan)
            case .venueCost:
                VenueCostSheet(plan: $plan)
            case .payment:
                PaymentMethodSelectionSheet(selections: $plan.paymentMethods)
            case .publishing:
                PublishingReminderSheet(plan: $plan)
            }
        }
        .onAppear {
            if let initialSheet { activeSheet = initialSheet }
            else if plan.name.isEmpty { nameFocused = true }
        }
    }
}

private struct ComposerTile: View {
    let symbol: String
    let title: String
    let value: String?
    let action: () -> Void

    private var isSet: Bool { value != nil }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isSet ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                        .frame(width: 40, height: 40)
                        .background(isSet ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(TamrinTheme.secondary), in: .circle)
                    Spacer()
                    Image(systemName: isSet ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(isSet ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.55)))
                }
                Spacer(minLength: 12)
                Text(title)
                    .font(TamrinFont.font(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value ?? "اضغط للتحديد")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(isSet ? .primary : .tertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 3)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 136, alignment: .leading)
            .background(TamrinTheme.glass, in: .rect(cornerRadius: 26))
            .shadow(color: .black.opacity(0.045), radius: 18, y: 9)
            .contentShape(.rect)
        }
        .buttonStyle(SpringCardPressStyle())
    }
}

// MARK: - Composer sheets

private struct ScheduleSheet: View {
    @Binding var plan: PlanDraft
    @Environment(\.dismiss) private var dismiss
    private let days = [(7, "س"), (1, "ح"), (2, "ن"), (3, "ث"), (4, "ر"), (5, "خ"), (6, "ج")]

    private var canConfirm: Bool {
        plan.scheduleKind == .oneOff || !plan.weekdays.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // A two-way choice is a segmented picker on iOS, not a pair of
                // hand-filled capsules.
                Picker("نوع الموعد", selection: $plan.scheduleKind.animation(.smooth(duration: 0.3))) {
                    Text("متكرر").tag(FeedScheduleKind.recurring)
                    Text("مرة واحدة").tag(FeedScheduleKind.oneOff)
                }
                .pickerStyle(.segmented)

                if plan.scheduleKind == .recurring {
                    VStack(spacing: 12) {
                        HStack(spacing: 5) {
                            ForEach(days, id: \.0) { day, letter in
                                weekdayToggle(day: day, letter: letter)
                            }
                        }

                        Text(plan.weekdays.isEmpty ? "اختر يومًا واحدًا على الأقل" : "كل \(plan.daysSummary)")
                            .font(TamrinFont.footnote)
                            .foregroundStyle(plan.weekdays.isEmpty ? .tertiary : .secondary)
                            .contentTransition(.numericText())
                    }
                    .transition(.blurReplace)
                } else {
                    DatePicker("تاريخ التمرين", selection: $plan.oneOffDate, in: Date.now..., displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .padding(.horizontal, 16)
                        .frame(height: 54)
                        .background(TamrinTheme.secondary, in: .rect(cornerRadius: 16, style: .continuous))
                        .transition(.blurReplace)
                }

                HStack(spacing: 12) {
                    TimeTile(title: "يبدأ", selection: $plan.startTime)
                    TimeTile(title: "ينتهي", selection: $plan.endTime)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 18)
            // Measured before the expanding frame below, so the sheet's
            // detent follows the content rather than the NavigationStack.
            .sheetContentHeight()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.smooth(duration: 0.3), value: plan.scheduleKind)
            .animation(.smooth(duration: 0.25), value: plan.weekdays)
            .navigationTitle("متى تتمرنون؟")
            .navigationSubtitle("حدد نوع الموعد ووقته")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }
                        .fontWeight(.semibold)
                        .disabled(!canConfirm)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .fittedSheet(includesNavigationBar: true)
    }

    /// A day is on/off, so it is a native bordered button that swaps to the
    /// prominent style when selected — the fill, press feedback and tint all
    /// come from the system.
    private func weekdayToggle(day: Int, letter: String) -> some View {
        let isOn = plan.weekdays.contains(day)
        return Button {
            if isOn { plan.weekdays.remove(day) } else { plan.weekdays.insert(day) }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Text(letter)
                .font(TamrinFont.font(size: 16, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .modifier(WeekdayToggleStyle(isOn: isOn))
        .accessibilityLabel(weekdayNames[day] ?? "")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Selected days use the prominent glass style, unselected the plain one.
private struct WeekdayToggleStyle: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
        } else {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
        }
    }
}

private struct TimeTile: View {
    let title: String
    @Binding var selection: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(TamrinFont.font(size: 12, weight: .medium)).foregroundStyle(.secondary)
            DatePicker(title, selection: $selection, displayedComponents: .hourAndMinute).labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(TamrinTheme.glass, in: .rect(cornerRadius: 20))
    }
}

private struct CapacitySheet: View {
    @Binding var plan: PlanDraft
    @Environment(\.dismiss) private var dismiss
    private let quickPicks = [6, 10, 12, 16, 22]

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                HStack(spacing: 24) {
                    CapacityStepButton(symbol: "minus", enabled: plan.capacity > 2) {
                        plan.capacity -= 1
                    }
                    Text(plan.capacity.arabicDigits)
                        .font(TamrinFont.font(size: 76, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(minWidth: 120)
                    CapacityStepButton(symbol: "plus", enabled: plan.capacity < 50) {
                        plan.capacity += 1
                    }
                }
                .animation(.bouncy(duration: 0.35), value: plan.capacity)

                HStack(spacing: 8) {
                    ForEach(quickPicks, id: \.self) { value in
                        Button {
                            plan.capacity = value
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Text(value.arabicDigits)
                                .font(TamrinFont.font(size: 15, weight: .medium))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity)
                        }
                        .modifier(SelectableCapsuleStyle(isOn: plan.capacity == value))
                        .accessibilityAddTraits(plan.capacity == value ? .isSelected : [])
                    }
                }

                // Two mutually exclusive policies — a segmented picker, with the
                // explanation below it rather than duplicated into two cards.
                VStack(spacing: 8) {
                    Picker("سياسة الاكتمال", selection: $plan.capacityPolicy.animation(.smooth(duration: 0.25))) {
                        Text("قائمة انتظار").tag(FeedCapacityPolicy.waitlist)
                        Text("يقفل عند الاكتمال").tag(FeedCapacityPolicy.closed)
                    }
                    .pickerStyle(.segmented)

                    Text(plan.capacityPolicy == .waitlist
                         ? "ينضم من قائمة الانتظار تلقائيًا عند تحرر مكان."
                         : "يتوقف التسجيل نهائيًا عند اكتمال العدد.")
                        .font(TamrinFont.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 18)
            // Measured before the expanding frame below, so the sheet's
            // detent follows the content rather than the NavigationStack.
            .sheetContentHeight()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("كم لاعب يكفيكم؟")
            .navigationSubtitle("حدد سعة كل موعد")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .fittedSheet(includesNavigationBar: true)
    }
}

/// Selected capsule uses the prominent system style, unselected the plain one.
private struct SelectableCapsuleStyle: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        } else {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        }
    }
}

/// Stepper affordance on the system's glass circle button, so the press
/// animation and disabled state are the platform's.
private struct CapacityStepButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: TamrinControlMetrics.symbolSize, weight: .bold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(!enabled)
    }
}

private struct PublishingReminderSheet: View {
    @Binding var plan: PlanDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                HStack(spacing: 24) {
                    CapacityStepButton(symbol: "minus", enabled: plan.publishLeadDays > 1) {
                        plan.publishLeadDays -= 1
                    }
                    VStack(spacing: 1) {
                        Text(plan.publishLeadDays.arabicDigits)
                            .font(TamrinFont.font(size: 66, weight: .bold)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(plan.publishLeadDays == 1 ? "يوم قبله" : "أيام قبله")
                            .font(TamrinFont.subheadline).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    .frame(minWidth: 126)
                    CapacityStepButton(symbol: "plus", enabled: plan.publishLeadDays < 14) {
                        plan.publishLeadDays += 1
                    }
                }
                .animation(.bouncy(duration: 0.35), value: plan.publishLeadDays)

                LabeledContent("وقت التذكير") {
                    DatePicker("وقت التذكير", selection: $plan.publishTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                .font(TamrinFont.headline)
                .padding(.horizontal, 16)
                .frame(height: 60)
                .background(TamrinTheme.secondary, in: .rect(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 18)
            // Measured before the expanding frame below, so the sheet's
            // detent follows the content rather than the NavigationStack.
            .sheetContentHeight()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("متى نجهّزه للإرسال؟")
            .navigationSubtitle("بنذكّرك أنت بس، والأعضاء ما يشوفونه إلا بعد الإرسال")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .fittedSheet(includesNavigationBar: true)
    }
}

/// Venue search. A `NavigationStack` with the system search field and a plain
/// `List` of results — the same shape Maps uses — plus `ContentUnavailableView`
/// for the empty state. Full height is deliberate here: the keyboard is up and
/// the result list grows, which is exactly when iOS uses a full-height sheet.
private struct LocationSheet: View {
    @Binding var plan: PlanDraft
    @Bindable var search: LocationSearchService
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                if search.results.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("ابحث عن الملعب", systemImage: "sportscourt")
                        } description: {
                            Text("اكتب اسم الملعب أو الحي ثم اضغط بحث، أو اعتمد الاسم كما كتبته إن كان مكانًا خاصًا.")
                        } actions: {
                            if !trimmedQuery.isEmpty {
                                Button("اعتمد «\(trimmedQuery)»") {
                                    plan.locationName = trimmedQuery
                                    dismiss()
                                }
                                .buttonStyle(.glassProminent)
                                .buttonBorderShape(.capsule)
                                .controlSize(.large)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(search.results) { result in
                        Button {
                            plan.locationName = result.title
                            plan.locationAddress = result.subtitle
                            plan.latitude = result.latitude
                            plan.longitude = result.longitude
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            dismiss()
                        } label: {
                            LabeledContent {
                                Image(systemName: "chevron.left")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.title).font(TamrinFont.headline)
                                        Text(result.subtitle)
                                            .font(TamrinFont.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                } icon: {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .transition(.blurReplace)
                }
            }
            .listStyle(.plain)
            .animation(.smooth(duration: 0.3), value: search.results.map(\.id))
            .searchable(text: $query, prompt: "مثلًا: ملعب الحي")
            .onSubmit(of: .search) {
                Task { await search.search(trimmedQuery) }
            }
            .onChange(of: query) { _, newValue in
                if newValue.isEmpty { search.results = [] }
            }
            .navigationTitle("وين تلعبون؟")
            .navigationSubtitle("سيظهر العنوان لكل الأعضاء")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء", role: .cancel) { dismiss() }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { query = plan.locationName }
    }
}

private struct VenueCostSheet: View {
    @Binding var plan: PlanDraft
    @Environment(\.dismiss) private var dismiss
    @FocusState private var amountFocused: Bool
    private let quickAmounts: [Double] = [300, 400, 480, 600]

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                TextField(
                    "0",
                    value: $plan.totalVenueCost,
                    format: .number.precision(.fractionLength(0))
                )
                .font(TamrinFont.font(size: 56, weight: .bold))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .focused($amountFocused)
                .fixedSize()

                Text("ر.س")
                    .font(TamrinFont.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                ForEach(quickAmounts, id: \.self) { amount in
                    Button {
                        plan.totalVenueCost = amount
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(amount.cleanAmount)
                            .font(TamrinFont.font(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .modifier(SelectableCapsuleStyle(isOn: plan.totalVenueCost == amount))
                    .accessibilityAddTraits(plan.totalVenueCost == amount ? .isSelected : [])
                }
            }

            HStack(spacing: 14) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(.tint.opacity(0.14), in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text("قطة اللاعب الواحد")
                        .font(TamrinFont.caption)
                        .foregroundStyle(.secondary)
                    Text("\(plan.pricePerPerson.cleanAmount) ر.س")
                        .font(TamrinFont.title2)
                        .contentTransition(.numericText())
                }
                Spacer()
                Text("على \(plan.capacity.arabicDigits) لاعب")
                    .font(TamrinFont.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(TamrinTheme.secondary, in: .rect(cornerRadius: 20, style: .continuous))
            .animation(.smooth(duration: 0.3), value: plan.pricePerPerson)
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 18)
            // Measured before the expanding frame below, so the sheet's
            // detent follows the content rather than the NavigationStack.
            .sheetContentHeight()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("كم قيمة الملعب؟")
            .navigationSubtitle("أدخل إجمالي الإيجار ونحسب القطة تلقائيًا")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("اعتماد") { dismiss() }
                        .fontWeight(.semibold)
                        .disabled(plan.totalVenueCost <= 0)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .fittedSheet(includesNavigationBar: true)
        .onAppear { amountFocused = plan.totalVenueCost == 0 }
    }
}

// MARK: - Step 3: Members

private struct MembersStepPage: View {
    @Binding var draft: TeamDraft
    let isCreating: Bool
    let create: () -> Void
    @State private var showContacts = false
    @State private var manualName = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("مين معك في\n«\(draft.teamName)»؟")
                        .font(TamrinFont.largeTitle)
                        .tracking(-0.8)
                    Text("أضفهم الآن أو شارك رابط الدعوة بعد الإنشاء — الخطوة اختيارية.")
                        .font(TamrinFont.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                Button { showContacts = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.accentColor, in: .circle)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("أضف من جهات الاتصال").font(TamrinFont.headline)
                            Text("اختر عدة أشخاص دفعة واحدة").font(TamrinFont.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.left").font(.caption.bold()).foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(TamrinTheme.glass, in: .rect(cornerRadius: 24))
                    .shadow(color: .black.opacity(0.05), radius: 18, y: 9)
                    .contentShape(.rect)
                }
                .buttonStyle(SpringCardPressStyle())

                HStack(spacing: 10) {
                    TextField("أو اكتب اسمًا يدويًا", text: $manualName)
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .onSubmit(addManualName)
                        .padding(.horizontal, 16)
                        .frame(height: TamrinControlMetrics.actionHeight)
                        .background(TamrinTheme.glass, in: .capsule)
                    Button(action: addManualName) {
                        Image(systemName: "plus")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: TamrinControlMetrics.actionHeight, height: TamrinControlMetrics.actionHeight)
                            .background(Color.accentColor, in: .circle)
                            .opacity(manualName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.3 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(manualName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !draft.invitedNames.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionEyebrow(text: "بانتظار الدعوة · \(draft.invitedNames.count.arabicDigits)")
                        VStack(spacing: 0) {
                            ForEach(draft.invitedNames, id: \.self) { name in
                                HStack(spacing: 14) {
                                    Text(String(name.prefix(1)))
                                        .font(TamrinFont.headline)
                                        .frame(width: 40, height: 40)
                                        .background(TamrinTheme.secondary, in: .circle)
                                    Text(name).font(TamrinFont.font(size: 17, weight: .medium))
                                    Spacer()
                                    Button {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            draft.invitedNames.removeAll { $0 == name }
                                        }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 30, height: 30)
                                            .background(TamrinTheme.secondary.opacity(0.7), in: .circle)
                                            .frame(width: TamrinControlMetrics.touchTarget, height: TamrinControlMetrics.touchTarget)
                                            .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 60)
                            }
                        }
                        .background(TamrinTheme.glass, in: .rect(cornerRadius: 24))
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Spacer(minLength: 30)
            }
            .padding(.horizontal, 22)
            .animation(.spring(response: 0.34, dampingFraction: 0.88), value: draft.invitedNames)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            TamrinActionButton(title: "أنشئ المجموعة", isLoading: isCreating, action: create)
                .padding(.horizontal, 22)
                .padding(.bottom, 10)
        }
        .sheet(isPresented: $showContacts) {
            ContactPicker(names: $draft.invitedNames).ignoresSafeArea()
        }
    }

    private func addManualName() {
        let name = manualName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !draft.invitedNames.contains(name) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                draft.invitedNames.append(name)
            }
        }
        manualName = ""
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Success

private struct CreationSuccessPage: View {
    let team: FeedTeam
    let draft: TeamDraft
    let done: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Group {
                if let data = team.avatarData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 118, height: 118)
                        .clipShape(.rect(cornerRadius: 38, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 38, style: .continuous).fill(TamrinTheme.ink)
                        Image(systemName: team.symbol)
                            .font(.system(size: 46, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 118, height: 118)
                }
            }
            .shadow(color: .black.opacity(0.16), radius: 30, y: 14)
            .scaleEffect(appeared ? 1 : 0.6)
            .animation(.spring(response: 0.5, dampingFraction: 0.68), value: appeared)

            VStack(spacing: 8) {
                Text("«\(team.name)» جاهزة!")
                    .font(TamrinFont.largeTitle)
                    .tracking(-0.8)
                Text(draft.plans.count == 1
                     ? "التمرين ومواعيده القادمة صارت جاهزة. شارك الرمز وخل الربع يوفرون أماكنهم."
                     : "\(draft.plans.count.arabicDigits) تمارين ومواعيدها صارت جاهزة. شارك الرمز وخل الربع يوفرون أماكنهم.")
                    .font(TamrinFont.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            VStack(spacing: 6) {
                Text("رمز الانضمام")
                    .font(TamrinFont.font(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(team.inviteCode)
                    .font(TamrinFont.font(size: 28, weight: .bold))
                    .tracking(5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(TamrinTheme.glass, in: .rect(cornerRadius: 26))
            .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 10) {
                if let url = team.inviteURL {
                    ShareLink(
                        item: url,
                        subject: Text("انضم لمجموعة \(team.name)"),
                        message: Text("هذا رابط الانضمام لمجموعتنا في تمرين")
                    ) {
                        Label("شارك رابط الدعوة", systemImage: "square.and.arrow.up")
                            .font(TamrinFont.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .tamrinPrimaryAction()
                }

                TamrinActionButton(title: "ادخل إلى المجموعة", prominent: false, action: done)
            }
        }
        .padding(22)
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear { appeared = true }
    }
}

// Ported from the designer's OnboardingViews.swift — used by MembersStepPage.
struct ContactPicker: UIViewControllerRepresentable {
    @Binding var names: [String]
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController(); picker.delegate = context.coordinator
        picker.predicateForEnablingContact = NSPredicate(value: true); return picker
    }
    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: ContactPicker
        init(parent: ContactPicker) { self.parent = parent }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            let formatter = CNContactFormatter()
            let newNames = contacts.compactMap { formatter.string(from: $0) }.filter { !$0.isEmpty }
            parent.names = Array(Set(parent.names + newNames)).sorted(); parent.dismiss()
        }
    }
}

/// Standalone session composer — reuses the wizard's TemplateComposerPage.
/// Create mode (no editingEventID) adds event(s) to the current workspace;
/// edit mode opens prefilled from the existing session and updates it on save.
/// Opened from the team-details ••• menu.
struct AddSessionSheet: View {
    @Bindable var feed: HomeStore
    @Binding var isPresented: Bool
    let editingEventID: UUID?
    let editingTemplateID: UUID?
    @State private var plan: PlanDraft
    @State private var saving = false
    @State private var failureMessage: String?
    @State private var showSaveScope = false

    init(feed: HomeStore, isPresented: Binding<Bool>,
         editingEventID: UUID? = nil, editingTemplateID: UUID? = nil,
         initialPlan: PlanDraft = PlanDraft()) {
        self.feed = feed
        self._isPresented = isPresented
        self.editingEventID = editingEventID
        self.editingTemplateID = editingTemplateID
        self._plan = State(initialValue: initialPlan)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TamrinTheme.page.ignoresSafeArea()
                TemplateComposerPage(
                    plan: $plan,
                    initialSheet: nil,
                    save: {
                        guard !saving else { return }
                        if editingEventID != nil, editingTemplateID != nil {
                            showSaveScope = true
                        } else {
                            save(scope: .occurrenceOnly)
                        }
                    },
                    cancel: { isPresented = false }
                )
            }
            .allowsHitTesting(!saving)
            .overlay {
                if saving {
                    ProgressView("جاري الحفظ…")
                        .font(TamrinFont.subheadline)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial, in: .capsule)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { isPresented = false }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .interactiveDismissDisabled(saving)
        .confirmationDialog(
            "أين تريد حفظ التعديل؟",
            isPresented: $showSaveScope,
            titleVisibility: .visible
        ) {
            Button("حفظ في القالب والتمارين القادمة") {
                save(scope: .seriesTemplate)
            }
            Button("حفظ لهذا التمرين فقط") {
                save(scope: .occurrenceOnly)
            }
            Button("تراجع", role: .cancel) {}
        } message: {
            Text("يمكنك تعديل هذا الموعد وحده، أو اعتماد التغييرات في القالب الذي تُنشأ منه التمارين القادمة.")
        }
        .alert("تعذر حفظ التمرين", isPresented: Binding(
            get: { failureMessage != nil },
            set: { if !$0 { failureMessage = nil } }
        )) {
            Button("حسنًا", role: .cancel) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
                .font(TamrinFont.body)
        }
    }

    private func save(scope: EventEditScope) {
        guard !saving else { return }
        saving = true
        Task {
            do {
                if let eventID = editingEventID {
                    try await feed.updateSession(
                        plan,
                        eventID: eventID,
                        templateID: editingTemplateID,
                        scope: scope
                    )
                } else {
                    try await feed.addSession(plan)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                isPresented = false
            } catch {
                saving = false
                failureMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
