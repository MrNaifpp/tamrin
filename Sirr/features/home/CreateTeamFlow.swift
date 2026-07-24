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
        price > 0
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
                                    paymentMethods: $draft.paymentMethods,
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
                            MembersStepPage(draft: $draft, create: create)
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
        Task {
            if let team = await feed.createTeam(from: draft) {
                createdTeam = team
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
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
                .overlay(Circle().stroke(TamrinTheme.hairline))
                .accessibilityLabel(step == .identity ? "إغلاق" : "رجوع")

                Spacer()

                Text(step.title)
                    .font(TamrinFont.headline)
                    .contentTransition(.opacity)

                Spacer()

                Text(step.counter)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 42)
            }

            HStack(spacing: 6) {
                ForEach(CreationStep.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? TamrinTheme.ink : Color.primary.opacity(0.09))
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
                        .overlay(RoundedRectangle(cornerRadius: 42, style: .continuous).stroke(.white.opacity(0.85), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.09), radius: 26, y: 12)

                        Image(systemName: "camera.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(TamrinTheme.ink, in: .circle)
                            .overlay(Circle().stroke(.white, lineWidth: 2.5))
                            .offset(x: -6, y: 8)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("صورة المجموعة")

                Text(draft.avatarData == nil ? "أضف صورة للمجموعة" : "اضغط لتغيير الصورة")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 14)

                TextField("اسم المجموعة", text: $draft.teamName)
                    .font(TamrinFont.title)
                    .multilineTextAlignment(.center)
                    .focused($nameFocused)
                    .submitLabel(.continue)
                    .onSubmit(advance)
                    .padding(.vertical, 18)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(nameFocused ? TamrinTheme.ink : Color.primary.opacity(0.14))
                            .frame(height: nameFocused ? 2 : 1)
                            .animation(.easeOut(duration: 0.18), value: nameFocused)
                    }
                    .padding(.horizontal, 42)
                    .padding(.top, 26)

                VStack(spacing: 14) {
                    Text("أو اختر رمزًا يعبر عنكم")
                        .font(.footnote)
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
                                        .frame(width: TamrinControlMetrics.touchTarget, height: TamrinControlMetrics.touchTarget)
                                        .background(isSymbolSelected(symbol) ? AnyShapeStyle(TamrinTheme.ink) : AnyShapeStyle(TamrinTheme.glass), in: .circle)
                                        .overlay(Circle().stroke(TamrinTheme.hairline))
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
            Button("متابعة", action: advance)
                .buttonStyle(PrimaryActionStyle())
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
                        .font(.body)
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
                    .background {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(TamrinTheme.ink.opacity(0.28), style: StrokeStyle(lineWidth: 1.6, dash: [7, 6]))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(SpringCardPressStyle())

                Spacer(minLength: 30)
            }
            .padding(.horizontal, 22)
        }
        .safeAreaInset(edge: .bottom) {
            Button("متابعة", action: advance)
                .buttonStyle(PrimaryActionStyle())
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
                            .font(.subheadline)
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
                    TemplateTag(symbol: "banknote", text: plan.price == 0 ? "مجاني" : "\(plan.price.cleanAmount) ر.س")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TamrinTheme.glass, in: .rect(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.85)))
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
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(TamrinTheme.secondary.opacity(0.72), in: .capsule)
    }
}

// MARK: - Step 2: Template composer

private enum ComposerSheet: String, Identifiable {
    case schedule, location, capacity, price, publishing
    var id: String { rawValue }
}

private struct TemplateComposerPage: View {
    @Binding var plan: PlanDraft
    @Binding var paymentMethods: [PaymentMethodDraft]
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
                        .font(.body)
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
                        .overlay(RoundedRectangle(cornerRadius: 21).stroke(nameFocused ? TamrinTheme.ink.opacity(0.5) : Color.white.opacity(0.85)))

                    if plan.name.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(nameSuggestions, id: \.self) { suggestion in
                                Button {
                                    plan.name = suggestion
                                    UISelectionFeedbackGenerator().selectionChanged()
                                } label: {
                                    Text(suggestion)
                                        .font(.footnote.weight(.medium))
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
                        title: "القَطّة",
                        value: plan.price == 0 ? "مجاني" : "\(plan.price.cleanAmount) ر.س"
                    ) { activeSheet = .price }
                    ComposerTile(
                        symbol: "paperplane.fill",
                        title: "التجهيز والإرسال",
                        value: "قبلها بـ\(plan.publishLeadDays.arabicDigits) يوم\nالساعة \(plan.publishTime.arabicTime)"
                    ) { activeSheet = .publishing }
                }

                Text("تقدر تعدّل أي موعد لحاله لاحقًا بدون تغيير القالب.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)

                Spacer(minLength: 30)
            }
            .padding(.horizontal, 22)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button("احفظ التمرين", action: save)
                .buttonStyle(PrimaryActionStyle())
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
            case .price:
                PriceSheet(plan: $plan, paymentMethods: $paymentMethods)
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
                        .foregroundStyle(isSet ? .white : TamrinTheme.ink.opacity(0.75))
                        .frame(width: 40, height: 40)
                        .background(isSet ? AnyShapeStyle(TamrinTheme.ink) : AnyShapeStyle(TamrinTheme.secondary), in: .circle)
                    Spacer()
                    Image(systemName: isSet ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(isSet ? TamrinTheme.ink : Color.secondary.opacity(0.55))
                }
                Spacer(minLength: 12)
                Text(title)
                    .font(.footnote.weight(.medium))
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
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.85)))
            .shadow(color: .black.opacity(0.045), radius: 18, y: 9)
            .contentShape(.rect)
        }
        .buttonStyle(SpringCardPressStyle())
    }
}

// MARK: - Composer sheets

private struct SheetGrabberTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 5) {
            Text(title).font(TamrinFont.title2)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}

private struct ScheduleSheet: View {
    @Binding var plan: PlanDraft
    @Environment(\.dismiss) private var dismiss
    private let days = [(7, "س"), (1, "ح"), (2, "ن"), (3, "ث"), (4, "ر"), (5, "خ"), (6, "ج")]

    var body: some View {
        VStack(spacing: 22) {
            SheetGrabberTitle(title: "متى تتمرنون؟", subtitle: "حدد نوع الموعد ووقته")

            HStack(spacing: 8) {
                scheduleKindButton(.recurring, title: "متكرر", symbol: "repeat")
                scheduleKindButton(.oneOff, title: "مرة واحدة", symbol: "calendar.badge.clock")
            }

            if plan.scheduleKind == .recurring {
                VStack(spacing: 14) {
                HStack(spacing: 4) {
                    ForEach(days, id: \.0) { day, letter in
                        Button {
                            if plan.weekdays.contains(day) { plan.weekdays.remove(day) } else { plan.weekdays.insert(day) }
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            Text(letter)
                                .font(TamrinFont.font(size: 17, weight: .bold))
                                .foregroundStyle(plan.weekdays.contains(day) ? .white : .primary)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: TamrinControlMetrics.touchTarget)
                                .background(plan.weekdays.contains(day) ? AnyShapeStyle(TamrinTheme.ink) : AnyShapeStyle(TamrinTheme.secondary), in: .circle)
                                .scaleEffect(plan.weekdays.contains(day) ? 1.06 : 1)
                                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: plan.weekdays.contains(day))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(weekdayNames[day] ?? "")
                        .accessibilityAddTraits(plan.weekdays.contains(day) ? .isSelected : [])
                    }
                }

                Text(plan.weekdays.isEmpty ? "اختر يومًا واحدًا على الأقل" : "كل \(plan.daysSummary)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(plan.weekdays.isEmpty ? .tertiary : .secondary)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.18), value: plan.daysSummary)
                }
            } else {
                DatePicker("تاريخ التمرين", selection: $plan.oneOffDate, in: Date.now..., displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .padding(.horizontal, 18)
                    .frame(height: 58)
                    .background(TamrinTheme.secondary, in: .capsule)
            }

            HStack(spacing: 12) {
                TimeTile(title: "يبدأ", selection: $plan.startTime)
                TimeTile(title: "ينتهي", selection: $plan.endTime)
            }

            Button("تم") { dismiss() }
                .buttonStyle(PrimaryActionStyle())
                .disabled(plan.scheduleKind == .recurring && plan.weekdays.isEmpty)
        }
        .padding(22)
        .padding(.top, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.height(540)])
        .presentationDragIndicator(.visible)
    }

    private func scheduleKindButton(_ kind: FeedScheduleKind, title: String, symbol: String) -> some View {
        Button {
            plan.scheduleKind = kind
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Label(title, systemImage: symbol)
                .font(TamrinFont.font(size: 15, weight: .bold))
                .foregroundStyle(plan.scheduleKind == kind ? .white : .primary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: TamrinControlMetrics.touchTarget)
                .background(plan.scheduleKind == kind ? TamrinTheme.ink : TamrinTheme.secondary, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

private struct TimeTile: View {
    let title: String
    @Binding var selection: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
        VStack(spacing: 26) {
            SheetGrabberTitle(title: "كم لاعب يكفيكم؟", subtitle: "حدد سعة كل موعد")

            HStack(spacing: 26) {
                CapacityRoundButton(symbol: "minus", enabled: plan.capacity > 2) {
                    plan.capacity -= 1
                }
                Text(plan.capacity.arabicDigits)
                    .font(TamrinFont.font(size: 84, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.26, dampingFraction: 0.8), value: plan.capacity)
                    .frame(minWidth: 128)
                CapacityRoundButton(symbol: "plus", enabled: plan.capacity < 50) {
                    plan.capacity += 1
                }
            }

            HStack(spacing: 8) {
                ForEach(quickPicks, id: \.self) { value in
                    Button {
                        plan.capacity = value
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(value.arabicDigits)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(plan.capacity == value ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: TamrinControlMetrics.touchTarget)
                            .background(plan.capacity == value ? AnyShapeStyle(TamrinTheme.ink) : AnyShapeStyle(TamrinTheme.secondary), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                CapacityPolicyCard(
                    title: "قائمة انتظار",
                    subtitle: "ينضم من الانتظار تلقائيًا",
                    selected: plan.capacityPolicy == .waitlist
                ) { plan.capacityPolicy = .waitlist }
                CapacityPolicyCard(
                    title: "يقفل عند الاكتمال",
                    subtitle: "لا تسجيل بعد اكتمال العدد",
                    selected: plan.capacityPolicy == .closed
                ) { plan.capacityPolicy = .closed }
            }

            Button("تم") { dismiss() }
                .buttonStyle(PrimaryActionStyle())
        }
        .padding(22)
        .padding(.top, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.height(520)])
        .presentationDragIndicator(.visible)
    }
}

private struct CapacityRoundButton: View {
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
                .foregroundStyle(TamrinTheme.ink)
                .frame(width: TamrinControlMetrics.touchTarget, height: TamrinControlMetrics.touchTarget)
                .background(TamrinTheme.glass, in: .circle)
                .overlay(Circle().stroke(TamrinTheme.hairline))
                .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

private struct CapacityPolicyCard: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.subheadline.weight(.bold))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? TamrinTheme.ink : .secondary.opacity(0.5))
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .background(TamrinTheme.glass, in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? TamrinTheme.ink.opacity(0.55) : TamrinTheme.hairline, lineWidth: selected ? 1.5 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct PublishingReminderSheet: View {
    @Binding var plan: PlanDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 26) {
            SheetGrabberTitle(title: "متى نجهّزه للإرسال؟", subtitle: "بنذكّرك أنت بس، والأعضاء ما يشوفونه إلا بعد الإرسال")

            HStack(spacing: 24) {
                reminderButton("minus", enabled: plan.publishLeadDays > 1) { plan.publishLeadDays -= 1 }
                VStack(spacing: 1) {
                    Text(plan.publishLeadDays.arabicDigits)
                        .font(TamrinFont.font(size: 72, weight: .bold)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(plan.publishLeadDays == 1 ? "يوم قبله" : "أيام قبله")
                        .font(TamrinFont.font(size: 14, weight: .medium)).foregroundStyle(.secondary)
                }
                .frame(minWidth: 130)
                reminderButton("plus", enabled: plan.publishLeadDays < 14) { plan.publishLeadDays += 1 }
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("وقت التذكير").font(TamrinFont.font(size: 15, weight: .bold))
                    Text("الافتراضي ١٢ الظهر").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                DatePicker("وقت التذكير", selection: $plan.publishTime, displayedComponents: .hourAndMinute).labelsHidden()
            }
            .padding(.horizontal, 18).frame(height: 68)
            .background(TamrinTheme.secondary, in: .capsule)

            Button("تم") { dismiss() }.buttonStyle(PrimaryActionStyle())
        }
        .padding(22).padding(.top, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.height(470)])
        .presentationDragIndicator(.visible)
    }

    private func reminderButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { action(); UIImpactFeedbackGenerator(style: .light).impactOccurred() } label: {
            Image(systemName: symbol)
                .font(.system(size: TamrinControlMetrics.symbolSize, weight: .bold))
                .frame(width: TamrinControlMetrics.touchTarget, height: TamrinControlMetrics.touchTarget)
                .background(TamrinTheme.secondary, in: .circle)
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.3)
    }
}

private struct LocationSheet: View {
    @Binding var plan: PlanDraft
    @Bindable var search: LocationSearchService
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SheetGrabberTitle(title: "وين تلعبون؟", subtitle: "ابحث بالاسم أو الحي وسيظهر العنوان للجميع")

                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("مثلًا: ملعب الحي", text: $plan.locationName)
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit { Task { await search.search(plan.locationName) } }
                    if !plan.locationName.isEmpty {
                        Button {
                            plan.locationName = ""
                            search.results = []
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
                .background(TamrinTheme.glass, in: .capsule)

                if search.results.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "sportscourt")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("اكتب اسم الملعب ثم اضغط بحث")
                            .font(.headline)
                        Text("أو اكتب الاسم مباشرة إن كان مكانًا خاصًا.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)

                    if !plan.locationName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("اعتمد «\(plan.locationName)»") { dismiss() }
                            .buttonStyle(SecondaryActionStyle())
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(search.results) { result in
                            Button {
                                plan.locationName = result.title
                                plan.locationAddress = result.subtitle
                                plan.latitude = result.latitude
                                plan.longitude = result.longitude
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    IconOrb(symbol: "mappin", tint: TamrinTheme.ink, size: 42)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.title).font(.headline)
                                        Text(result.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.left").font(.caption.bold()).foregroundStyle(.tertiary)
                                }
                                .foregroundStyle(.primary)
                                .padding(14)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            if result.id != search.results.last?.id { Divider().padding(.leading, 70) }
                        }
                    }
                    .background(TamrinTheme.glass, in: .rect(cornerRadius: 24))
                }
            }
            .padding(22)
            .padding(.top, 12)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { focused = true }
    }
}

private struct PriceSheet: View {
    @Binding var plan: PlanDraft
    @Binding var paymentMethods: [PaymentMethodDraft]
    @Environment(\.dismiss) private var dismiss
    @State private var showAddMethod = false
    private let quickAmounts: [Double] = [20, 35, 50, 75]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                SheetGrabberTitle(title: "كم القَطّة؟", subtitle: "المبلغ على كل لاعب في الموعد الواحد")
                amountField
                quickChips
                if plan.price > 0 {
                    methodsSection
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                Button("تم") { dismiss() }
                    .buttonStyle(PrimaryActionStyle())
            }
            .padding(22)
            .padding(.top, 12)
            .animation(.spring(response: 0.34, dampingFraction: 0.88), value: plan.price > 0)
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.height(620), .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showAddMethod) { PaymentMethodEditor(methods: $paymentMethods) }
    }

    private var amountField: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            TextField("0", value: $plan.price, format: .number)
                .font(TamrinFont.font(size: 64, weight: .bold))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .fixedSize()
            Text("ر.س")
                .font(TamrinFont.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var quickChips: some View {
        HStack(spacing: 8) {
            ForEach(quickAmounts, id: \.self) { amount in
                Button {
                    plan.price = amount
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(amount == 0 ? "مجاني" : amount.cleanAmount)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(plan.price == amount ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: TamrinControlMetrics.touchTarget)
                        .background(plan.price == amount ? AnyShapeStyle(TamrinTheme.ink) : AnyShapeStyle(TamrinTheme.secondary), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var methodsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("طرق الدفع").font(TamrinFont.title3)
                Spacer()
                Button { showAddMethod = true } label: { Label("إضافة", systemImage: "plus") }
                    .buttonStyle(.bordered)
                    .tint(.primary)
            }
            if paymentMethods.isEmpty {
                emptyMethodsButton
            } else {
                VStack(spacing: 10) {
                    ForEach(paymentMethods) { method in
                        methodRow(method)
                    }
                }
            }
        }
    }

    private var emptyMethodsButton: some View {
        Button { showAddMethod = true } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").font(.title)
                Text("أضف حسابًا بنكيًا أو خيار الدفع نقدًا")
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(TamrinTheme.ink.opacity(0.2), style: StrokeStyle(lineWidth: 1.4, dash: [7, 6]))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func methodRow(_ method: PaymentMethodDraft) -> some View {
        HStack(spacing: 14) {
            IconOrb(symbol: method.kind == .cash ? "banknote" : "building.columns", size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(method.title).font(.headline)
                Text(method.kind == .cash ? "في الملعب" : method.iban)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                paymentMethods.removeAll { $0.id == method.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(TamrinTheme.glass, in: .rect(cornerRadius: 20))
    }
}

struct PaymentMethodEditor: View {
    @Binding var methods: [PaymentMethodDraft]
    @Environment(\.dismiss) private var dismiss
    @State private var method = PaymentMethodDraft()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        IconOrb(symbol: "creditcard.fill", tint: TamrinTheme.ink, size: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("طريقة دفع").font(TamrinFont.title2)
                            Text("أدخل ما يحتاجه اللاعب للتحويل").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        FloatingCloseButton { dismiss() }
                    }
                    Picker("النوع", selection: $method.kind) {
                        Text("حساب بنكي").tag(FeedPaymentKind.bank)
                        Text("نقداً").tag(FeedPaymentKind.cash)
                    }.pickerStyle(.segmented)
                    VStack(spacing: 0) {
                        FloatingField(title: method.kind == .bank ? "اسم البنك" : "اسم الخيار", text: $method.title)
                        if method.kind == .bank {
                            Divider().padding(.leading, 16)
                            FloatingField(title: "اسم المستفيد", text: $method.accountHolder)
                            Divider().padding(.leading, 16)
                            FloatingField(title: "IBAN", text: $method.iban)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            Divider().padding(.leading, 16)
                            FloatingField(title: "رقم الحساب — اختياري", text: $method.accountNumber)
                            Divider().padding(.leading, 16)
                            FloatingField(title: "رابط تطبيق البنك — اختياري", text: $method.appURL)
                                .textInputAutocapitalization(.never).keyboardType(.URL)
                        }
                    }
                    .background(TamrinTheme.glass, in: .rect(cornerRadius: 24))
                    Button("إضافة الطريقة") { methods.append(method); dismiss() }
                        .buttonStyle(PrimaryActionStyle())
                        .disabled(method.title.isEmpty || (method.kind == .bank && method.iban.isEmpty))
                }
                .padding(22)
            }
            .background(Color(uiColor: .secondarySystemBackground))
        }
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct FloatingField: View {
    let title: String
    @Binding var text: String
    var body: some View { TextField(title, text: $text).padding(.horizontal, 16).frame(height: 58) }
}

// MARK: - Step 3: Members

private struct MembersStepPage: View {
    @Binding var draft: TeamDraft
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
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                Button { showContacts = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(TamrinTheme.ink, in: .circle)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("أضف من جهات الاتصال").font(TamrinFont.headline)
                            Text("اختر عدة أشخاص دفعة واحدة").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.left").font(.caption.bold()).foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(TamrinTheme.glass, in: .rect(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.85)))
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
                        .overlay(Capsule().stroke(TamrinTheme.hairline))
                    Button(action: addManualName) {
                        Image(systemName: "plus")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: TamrinControlMetrics.actionHeight, height: TamrinControlMetrics.actionHeight)
                            .background(TamrinTheme.ink, in: .circle)
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
                                    Text(name).font(.body.weight(.medium))
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
                                if name != draft.invitedNames.last { Divider().padding(.leading, 68) }
                            }
                        }
                        .background(TamrinTheme.glass, in: .rect(cornerRadius: 24))
                        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.85)))
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
            Button("أنشئ المجموعة", action: create)
                .buttonStyle(PrimaryActionStyle())
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
            .overlay(RoundedRectangle(cornerRadius: 38, style: .continuous).stroke(.white.opacity(0.85), lineWidth: 1.5))
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
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            VStack(spacing: 6) {
                Text("رمز الانضمام")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(team.inviteCode)
                    .font(.title.monospaced().bold())
                    .tracking(5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(TamrinTheme.glass, in: .rect(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.85)))
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
                    }
                    .buttonStyle(PrimaryActionStyle())
                }

                Button("ادخل إلى المجموعة", action: done)
                    .buttonStyle(SecondaryActionStyle())
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
    @State private var paymentMethods: [PaymentMethodDraft] = []
    @State private var saving = false

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
                    paymentMethods: $paymentMethods,
                    initialSheet: nil,
                    save: {
                        guard !saving else { return }
                        saving = true
                        Task {
                            if let eventID = editingEventID {
                                await feed.updateSession(plan, eventID: eventID, templateID: editingTemplateID)
                            } else {
                                await feed.addSession(plan)
                            }
                            isPresented = false
                        }
                    },
                    cancel: { isPresented = false }
                )
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
    }
}
