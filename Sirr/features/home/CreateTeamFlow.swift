import SwiftUI
import MapKit
import PhotosUI
import Observation
import Combine

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
    var isSearching = false
    /// Results arrive out of order when the organizer keeps typing, so every
    /// response is checked against the query that is still current.
    private var latestQuery = ""

    func search(_ query: String) async {
        latestQuery = query
        guard query.count > 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753),
            span: MKCoordinateSpan(latitudeDelta: 0.7, longitudeDelta: 0.7)
        )
        let response = try? await MKLocalSearch(request: request).start()
        guard latestQuery == query else { return }
        isSearching = false
        guard let response else { return }
        results = response.mapItems.prefix(6).map {
            let coordinate = $0.location.coordinate
            let address = $0.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true) ?? "الرياض"
            return Result(title: $0.name ?? query, subtitle: address, latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }
}

private enum CreationStep: Int, CaseIterable {
    case identity, details, invite

    var title: String {
        switch self {
        case .identity: "هوية التمرين"
        case .details: "تفاصيل التمرين"
        case .invite: "دعوة الأعضاء"
        }
    }

    var counter: String {
        switch self {
        case .identity: "1 من 3"
        case .details: "2 من 3"
        case .invite: "3 من 3"
        }
    }
}

private let weekdayNames: [Int: String] = [1: "الأحد", 2: "الاثنين", 3: "الثلاثاء", 4: "الأربعاء", 5: "الخميس", 6: "الجمعة", 7: "السبت"]

private extension Int {
    /// Western digits in Arabic copy — see `Locale.tamrin`.
    var appDigits: String { formatted(.number.locale(.tamrin).grouping(.never)) }
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
    /// The one exercise this flow creates. It carries the name typed on the
    /// identity step, so the composer never asks for it a second time.
    @State private var plan = PlanDraft()
    @State private var step: CreationStep = .identity
    @State private var goingForward = true
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

            VStack(spacing: 0) {
                FlowHeader(step: step, back: goBack)
                ZStack {
                    switch step {
                    case .identity:
                        IdentityStepPage(draft: $draft, advance: advanceFromIdentity)
                            .transition(stepTransition)
                    case .details:
                        TemplateComposerPage(
                            plan: $plan,
                            showsNameField: false,
                            actionTitle: "أنشئ التمرين",
                            isSaving: isCreating,
                            save: create
                        )
                        .transition(stepTransition)
                    case .invite:
                        // Reached only once the workspace exists, because the
                        // join link is issued by the backend on creation.
                        if let createdTeam {
                            InviteStepPage(team: createdTeam) {
                                isPresented = false
                            }
                            .transition(stepTransition)
                        }
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.9), value: step)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .interactiveDismissDisabled()
        .alert("تعذر إنشاء التمرين", isPresented: Binding(
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

    /// The name belongs to the exercise itself, so it travels from this step
    /// into the plan rather than being asked for again on the next one.
    private func advanceFromIdentity() {
        let name = draft.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        plan.name = name
        move(to: .details)
    }

    /// Creating the exercise is what issues the join link, so it happens when
    /// the organizer leaves the details step — the invite step then has a real
    /// link to share instead of a placeholder.
    private func create() {
        guard !isCreating else { return }
        isCreating = true
        draft.plans = [plan]
        Task {
            do {
                let team = try await feed.createTeam(from: draft)
                createdTeam = team
                Haptics.success()
                move(to: .invite)
            } catch {
                failureMessage = error.localizedDescription
                Haptics.error()
            }
            isCreating = false
        }
    }

    private func goBack() {
        switch step {
        case .identity:
            isPresented = false
        case .details:
            move(to: .identity)
        case .invite:
            // The exercise already exists — there is nothing to go back to.
            break
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
                // The last step has no way back: the exercise already exists.
                Group {
                    if step == .invite {
                        Color.clear
                    } else {
                        Button(action: back) {
                            Image(systemName: step == .identity ? "xmark" : "chevron.right")
                                .font(.system(size: TamrinControlMetrics.symbolSize, weight: .semibold))
                                .frame(width: TamrinControlMetrics.touchTarget, height: TamrinControlMetrics.touchTarget)
                        }
                        .buttonStyle(.plain)
                        .background(TamrinTheme.glass, in: .circle)
                        .accessibilityLabel(step == .identity ? "إغلاق" : "رجوع")
                    }
                }
                .frame(width: TamrinControlMetrics.touchTarget, height: TamrinControlMetrics.touchTarget)

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

    /// Every sport SF Symbols draws a figure for, filtered at runtime against
    /// what this OS actually ships: `Image(systemName:)` renders nothing for a
    /// name the system does not know, so a hardcoded list would quietly leave
    /// holes in the grid on an older iOS.
    private static let sportSymbols: [String] = [
        "figure.soccer", "figure.basketball", "figure.american.football",
        "figure.australian.football", "figure.rugby", "figure.baseball",
        "figure.softball", "figure.cricket", "figure.volleyball",
        "figure.handball", "figure.tennis", "figure.badminton",
        "figure.table.tennis", "figure.racquetball", "figure.squash",
        "figure.golf", "figure.bowling", "figure.archery",
        "figure.run", "figure.walk", "figure.hiking", "figure.track.and.field",
        "figure.outdoor.cycle", "figure.indoor.cycle", "figure.rolling",
        "figure.pool.swim", "figure.open.water.swim", "figure.water.fitness",
        "figure.surfing", "figure.sailing", "figure.rowing", "figure.fishing",
        "figure.strengthtraining.traditional", "figure.strengthtraining.functional",
        "figure.core.training", "figure.highintensity.intervaltraining",
        "figure.cross.training", "figure.mixed.cardio", "figure.elliptical",
        "figure.stair.stepper", "figure.jumprope", "figure.flexibility",
        "figure.cooldown", "figure.yoga", "figure.pilates", "figure.mind.and.body",
        "figure.boxing", "figure.kickboxing", "figure.martial.arts",
        "figure.wrestling", "figure.fencing", "figure.climbing",
        "figure.skiing.downhill", "figure.skiing.crosscountry",
        "figure.snowboarding", "figure.curling", "figure.ice.skating",
        "figure.ice.hockey", "figure.field.hockey", "figure.lacrosse",
        "figure.disc.sports", "figure.equestrian.sports", "figure.gymnastics",
        "figure.dance", "figure.socialdance", "figure.play", "figure.step.training"
    ].filter { UIImage(systemName: $0) != nil }

    private let symbolColumns = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: 6
    )

    /// The exercise as it will be seen everywhere else, shown once at the size a
    /// choice deserves. The symbol scales with it, so this is the only number
    /// to touch.
    private static let identityDiameter: CGFloat = 112

    /// A step lighter than `TamrinTheme.secondary`. That token is tuned to clear
    /// a sheet background by a visible margin; here the chips sit on `card` —
    /// plain white in light mode — so they can be softer without disappearing,
    /// and a wall of sixty icon discs is calmer for it.
    private static let chipFill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.28, alpha: 1)
            : UIColor(white: 0.945, alpha: 1)
    })

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                identityCard
                colorRow
                symbolGrid
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
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

    /// The exercise as it will look, over the field that names it.
    private var identityCard: some View {
        VStack(spacing: 18) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Group {
                    if let data = draft.avatarData, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            draft.teamColor.color
                            Image(systemName: draft.teamSymbol)
                                .font(.system(size: Self.identityDiameter * 0.48, weight: .semibold))
                                .foregroundStyle(draft.teamColor.symbolColor)
                        }
                    }
                }
                .frame(width: Self.identityDiameter, height: Self.identityDiameter)
                .clipShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("صورة التمرين")

            TextField("اسم التمرين", text: $draft.teamName)
                .font(TamrinFont.font(size: 20, weight: .medium))
                .multilineTextAlignment(.center)
                .focused($nameFocused)
                .submitLabel(.continue)
                .onSubmit(advance)
                .padding(.vertical, 15)
                .padding(.horizontal, 18)
                .background(Self.chipFill, in: .capsule)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(TamrinTheme.card, in: .rect(cornerRadius: 26, style: .continuous))
    }

    /// One row, no scrolling: these are the colours worth a tap, and an
    /// exercise's tint is not a decision worth paging through.
    private var colorRow: some View {
        HStack(spacing: 0) {
            ForEach(TeamColor.allCases) { option in
                Button {
                    draft.teamColor = option
                    Haptics.selection()
                } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 34, height: 34)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.45), lineWidth: 2)
                                .padding(-4)
                                .opacity(draft.teamColor == option ? 1 : 0)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: TamrinControlMetrics.touchTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.rawValue)
                .accessibilityAddTraits(draft.teamColor == option ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(TamrinTheme.card, in: .rect(cornerRadius: 26, style: .continuous))
        .animation(.smooth(duration: 0.2), value: draft.teamColor)
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: symbolColumns, spacing: 12) {
            ForEach(Self.sportSymbols, id: \.self) { symbol in
                Button {
                    draft.teamSymbol = symbol
                    draft.avatarData = nil
                    photoItem = nil
                    Haptics.selection()
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(
                            isSymbolSelected(symbol) ? draft.teamColor.symbolColor : Color.primary
                        )
                        .frame(width: 44, height: 44)
                        .background(
                            isSymbolSelected(symbol)
                                ? AnyShapeStyle(draft.teamColor.color)
                                : AnyShapeStyle(Self.chipFill),
                            in: .circle
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSymbolSelected(symbol) ? .isSelected : [])
            }
        }
        .padding(16)
        .background(TamrinTheme.card, in: .rect(cornerRadius: 26, style: .continuous))
    }

    private func isSymbolSelected(_ symbol: String) -> Bool {
        draft.avatarData == nil && draft.teamSymbol == symbol
    }
}

// MARK: - Step 2: Exercise details

private enum ComposerSheet: String, Identifiable {
    case schedule, location, capacity, venueCost, payment, publishing
    var id: String { rawValue }
}

private struct TemplateComposerPage: View {
    @Binding var plan: PlanDraft
    /// The creation wizard already asked for the name on its identity step, so
    /// it hides this field rather than asking for the same thing twice. The
    /// standalone session composer still needs it.
    var showsNameField = true
    var actionTitle = "احفظ الموعد"
    var isSaving = false
    let save: () -> Void

    @State private var activeSheet: ComposerSheet?
    @State private var locationSearch = LocationSearchService()
    @FocusState private var nameFocused: Bool

    private let nameSuggestions = ["كورة الأسبوع", "تمرين اللياقة", "شوط الخميس"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(showsNameField ? "صمّم الموعد" : "صمّم التمرين")
                        .font(TamrinFont.largeTitle)
                        .tracking(-0.8)
                    // With the name already settled, the subtitle says whose
                    // details these are instead of asking for one.
                    Text(showsNameField
                         ? "سمّه، وحدد تفاصيله بلمسة على كل بطاقة."
                         : "حدد تفاصيل «\(plan.name)» بلمسة على كل بطاقة.")
                        .font(TamrinFont.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                if showsNameField {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("اسم الموعد", text: $plan.name)
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
                                        Haptics.selection()
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
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ComposerTile(
                        symbol: "calendar",
                        title: "الأيام والوقت",
                        // Nothing to summarize only when it's a recurring plan
                        // with no weekday chosen yet — a one-off plan always
                        // has a real date and times, even before the sheet is
                        // opened, so weekdays.isEmpty (which is also true for
                        // every one-off plan) cannot gate it here.
                        value: (plan.scheduleKind == .recurring && plan.weekdays.isEmpty)
                            ? nil
                            : "\(plan.daysSummary)\n\(plan.timeSummary)"
                    ) { activeSheet = .schedule }
                    ComposerTile(
                        symbol: "mappin.and.ellipse",
                        title: "الملعب",
                        value: plan.locationName.isEmpty
                            ? nil
                            : "\(plan.locationName)\n\(plan.venueKind.title)"
                    ) { activeSheet = .location }
                    ComposerTile(
                        symbol: "person.2.fill",
                        title: "عدد اللاعبين",
                        value: "حتى \(plan.capacity.appDigits)\n\(plan.capacityPolicy == .waitlist ? "مع قائمة انتظار" : "يقفل عند الاكتمال")"
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
                               : "\(plan.paymentMethods.count.appDigits) وسائل دفع")
                    ) { activeSheet = .payment }
                    ComposerTile(
                        symbol: "paperplane.fill",
                        title: "التجهيز والإرسال",
                        value: "قبلها بـ\(plan.publishLeadDays.appDigits) يوم\nالساعة \(plan.publishTime.arabicTime)"
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
            TamrinActionButton(title: actionTitle, isLoading: isSaving, action: save)
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
            if showsNameField, plan.name.isEmpty { nameFocused = true }
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
            .sheetTitle("متى تتمرنون؟", subtitle: "حدد نوع الموعد ووقته")
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
            Haptics.selection()
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
                    Text(plan.capacity.appDigits)
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
                            Haptics.impact(.light)
                        } label: {
                            Text(value.appDigits)
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
            .sheetTitle("كم لاعب يكفيكم؟", subtitle: "حدد سعة كل موعد")
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
            Haptics.impact(.light)
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
                        Text(plan.publishLeadDays.appDigits)
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
            .sheetTitle("متى نجهّزه للإرسال؟", subtitle: "بنذكّرك أنت بس، وما يشوفونه إلا بعد الإرسال")
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

/// Picking a venue is two different jobs, so the sheet asks which one first.
/// A custom venue — the rest house, the neighbourhood pitch — has no entry on
/// the map, so searching for it is pointless and the organizer describes it by
/// hand instead. A rented pitch is commercial, so it is found by search. The
/// choice is pushed onto a `NavigationStack`, so «رجوع» returns to it rather
/// than closing the sheet.
private struct LocationSheet: View {
    @Binding var plan: PlanDraft
    @Bindable var search: LocationSearchService
    @Environment(\.dismiss) private var dismiss
    @State private var path: [FeedVenueKind] = []
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack(path: $path) {
            VenueKindPicker(selected: plan.locationName.isEmpty ? nil : plan.venueKind) { kind in
                path = [kind]
            }
            .sheetTitle("وين تلعبون؟", subtitle: "اختر نوع الملعب")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء", role: .cancel) { dismiss() }
                }
            }
            .navigationDestination(for: FeedVenueKind.self) { kind in
                switch kind {
                case .custom:
                    CustomVenueForm(plan: $plan) { dismiss() }
                case .rented:
                    RentedVenueSearch(plan: $plan, search: search) { dismiss() }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(TamrinTheme.sheet)
        // Both destinations raise the keyboard, so they take the whole sheet
        // while the choice screen stays a short card.
        .onChange(of: path) { _, newPath in
            detent = newPath.isEmpty ? .medium : .large
        }
        .onAppear {
            // Re-opening an answered tile lands on the step that answered it.
            if !plan.locationName.isEmpty { path = [plan.venueKind] }
        }
    }
}

private struct VenueKindPicker: View {
    var selected: FeedVenueKind?
    let choose: (FeedVenueKind) -> Void

    var body: some View {
        VStack(spacing: 12) {
            ForEach(FeedVenueKind.allCases, id: \.self) { kind in
                Button {
                    Haptics.selection()
                    choose(kind)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.accentColor, in: .circle)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(kind.title)
                                .font(TamrinFont.headline)
                                .foregroundStyle(.primary)
                            Text(kind.detail)
                                .font(TamrinFont.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 6)

                        Image(systemName: selected == kind ? "checkmark.circle.fill" : "chevron.left")
                            .font(.footnote.bold())
                            .foregroundStyle(selected == kind ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TamrinTheme.card, in: .rect(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == kind ? .isSelected : [])
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
    }
}

/// A venue only the team knows can't be searched for, so it is described
/// instead: a name, where it is, and — when they have one — a Maps link.
/// Everything but the name is optional.
private struct CustomVenueForm: View {
    @Binding var plan: PlanDraft
    let done: () -> Void

    @State private var name = ""
    @State private var address = ""
    @State private var mapsLink = ""
    @State private var linkSourceIndex = 0
    @FocusState private var nameFocused: Bool

    /// The map apps people around here actually share a pin from.
    private static let linkSources = ["هدهد", "خرائط قوقل", "بلدي"]
    private static let linkSourceInterval: TimeInterval = 2

    private let linkSourceTimer = Timer
        .publish(every: linkSourceInterval, on: .main, in: .common)
        .autoconnect()

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedLink: String { mapsLink.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isLinkValid: Bool {
        trimmedLink.isEmpty || URL(string: trimmedLink)?.scheme?.hasPrefix("http") == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VenueField(title: "اسم الملعب", caption: nil) {
                    TextField("مثلًا: ملعب الاستراحة", text: $name)
                        .font(TamrinFont.headline)
                        .focused($nameFocused)
                        .submitLabel(.next)
                }

                VenueField(title: "موقعه", caption: "وصف يوصّل الأعضاء للمكان.") {
                    TextField("مثلًا: حي النرجس، خلف مسجد الفرقان", text: $address, axis: .vertical)
                        .font(TamrinFont.body)
                        .lineLimit(1...3)
                }

                VenueField(title: "رابط الموقع", caption: mapsCaption) {
                    TextField("", text: $mapsLink)
                        .font(TamrinFont.body)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                        .multilineTextAlignment(.leading)
                        // The placeholder names the map apps a link may come
                        // from, cycling through them, so it answers "from
                        // where?" rather than showing one vendor's URL shape.
                        // It is drawn as an overlay because a `prompt` cannot
                        // animate between values.
                        .overlay {
                            if trimmedLink.isEmpty {
                                // Pinned right the explicit way: the field runs
                                // left-to-right for the URL, so a `.trailing`
                                // alignment here would resolve against the
                                // wrong direction. The spacer settles it.
                                HStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    Text(Self.linkSources[linkSourceIndex])
                                        .font(TamrinFont.body)
                                        .foregroundStyle(.tertiary)
                                        .id(linkSourceIndex)
                                        .transition(.blurReplace)
                                }
                                .environment(\.layoutDirection, .leftToRight)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                        }
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
        }
        // The scroll view paints itself over the sheet's presentation
        // background, so the off-white is restored here — the white belongs to
        // the fields, not to what they sit on.
        .background(TamrinTheme.sheet)
        .scrollDismissesKeyboard(.interactively)
        .sheetTitle("ملعب مخصص", subtitle: "عرّف أعضاءك على ملعبكم")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("تم", action: save)
                    .fontWeight(.semibold)
                    .disabled(trimmedName.isEmpty || !isLinkValid)
            }
        }
        .onReceive(linkSourceTimer) { _ in
            guard trimmedLink.isEmpty else { return }
            withAnimation(.smooth(duration: 0.35)) {
                linkSourceIndex = (linkSourceIndex + 1) % Self.linkSources.count
            }
        }
        .onAppear {
            guard plan.venueKind == .custom else { nameFocused = true; return }
            name = plan.locationName
            address = plan.locationAddress
            mapsLink = plan.mapsURL
            nameFocused = name.isEmpty
        }
    }

    private var mapsCaption: String {
        isLinkValid ? "إن كان لكم موقع على الخريطة، الصقه هنا." : "الرابط غير صحيح — الصق رابطًا يبدأ بـ https."
    }

    private func save() {
        plan.venueKind = .custom
        plan.locationName = trimmedName
        plan.locationAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.mapsURL = trimmedLink
        if let coordinate = Self.coordinate(from: trimmedLink) {
            plan.latitude = coordinate.latitude
            plan.longitude = coordinate.longitude
        }
        Haptics.impact(.light)
        done()
    }

    /// Maps links carry the pin as `@lat,lng`, `?q=lat,lng` or `!3dlat!4dlng`.
    /// Reading it saves the organizer from placing the pin a second time; a
    /// shortened link (`maps.app.goo.gl/…`) carries nothing, and the venue then
    /// simply keeps the default pin.
    private static func coordinate(from link: String) -> CLLocationCoordinate2D? {
        let patterns: [Regex<(Substring, Substring, Substring)>] = [
            /[@=](-?\d{1,2}\.\d+),\s*(-?\d{1,3}\.\d+)/,
            /!3d(-?\d{1,2}\.\d+)!4d(-?\d{1,3}\.\d+)/
        ]
        for pattern in patterns {
            guard let match = link.firstMatch(of: pattern),
                  let latitude = Double(match.1),
                  let longitude = Double(match.2),
                  (-90.0...90.0).contains(latitude),
                  (-180.0...180.0).contains(longitude)
            else { continue }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        return nil
    }
}

private struct VenueField<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TamrinFont.font(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Fields are the white surface; the sheet under them is the
                // off-white one. Never the other way round.
                .background(TamrinTheme.card, in: .capsule)
            if let caption {
                Text(caption)
                    .font(TamrinFont.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// A commercial pitch is on the map, so this is a search: the system's own
/// search field, pinned under the navigation bar, with results landing while
/// the organizer types — no submit.
private struct RentedVenueSearch: View {
    @Binding var plan: PlanDraft
    @Bindable var search: LocationSearchService
    let done: () -> Void

    @State private var query = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        results
            .sheetTitle("ملعب مؤجر", subtitle: "سيظهر العنوان لكل الأعضاء")
            // Pinned under the bar, not auto-presented: presenting it takes
            // the bar over and hides both the title and the back button.
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "مثلًا: ملعب الحي"
            )
            .autocorrectionDisabled()
            // Results follow the typing, one request per pause rather than one
            // per keystroke; a new query cancels the sleep of the one before it.
            .task(id: trimmedQuery) {
                guard trimmedQuery.count > 2 else {
                    await search.search(trimmedQuery)
                    return
                }
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                await search.search(trimmedQuery)
            }
            .onAppear {
                if plan.venueKind == .rented { query = plan.locationName }
            }
    }

    @ViewBuilder
    private var results: some View {
        if search.results.isEmpty {
            ContentUnavailableView {
                Label("ابحث عن الملعب", systemImage: "sportscourt")
            } description: {
                // No "use what I typed" escape hatch here: a venue that isn't on
                // the map is a custom venue, and that is the other step.
                Text(trimmedQuery.count > 2 && !search.isSearching
                     ? "ما لقينا ملعبًا بهذا الاسم. جرّب اسمًا أقصر، أو ارجع واختر «ملعب مخصص»."
                     : "اكتب اسم الملعب أو الحي وتظهر النتائج وأنت تكتب.")
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(search.results) { result in
                    Button {
                        select(
                            name: result.title,
                            address: result.subtitle,
                            latitude: result.latitude,
                            longitude: result.longitude
                        )
                    } label: {
                        // An explicit row, not `LabeledContent`: a two-line
                        // address pushes its trailing chevron onto a line of
                        // its own there.
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.tint)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.title).font(TamrinFont.headline)
                                Text(result.subtitle)
                                    .font(TamrinFont.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 6)

                            Image(systemName: "chevron.left")
                                .font(.caption.bold())
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .transition(.blurReplace)
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
            .animation(.smooth(duration: 0.3), value: search.results.map(\.id))
        }
    }

    private func select(name: String, address: String, latitude: Double? = nil, longitude: Double? = nil) {
        plan.venueKind = .rented
        plan.locationName = name
        plan.locationAddress = address
        // A rented pitch carries no hand-written directions of its own.
        plan.mapsURL = ""
        if let latitude { plan.latitude = latitude }
        if let longitude { plan.longitude = longitude }
        Haptics.impact(.light)
        done()
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
                        Haptics.impact(.light)
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
                Text("على \(plan.capacity.counted(.player))")
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
            .sheetTitle("كم قيمة الملعب؟", subtitle: "أدخل إجمالي الإيجار ونحسب القطة تلقائيًا")
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

// MARK: - Step 3: Invite

/// By the time this step appears the exercise already exists, so the whole page
/// is about getting its join link out: read it, copy it, or hand it straight to
/// WhatsApp or Messages — the two apps organizers actually use to round people
/// up. The system share sheet stays available for everything else.
private struct InviteStepPage: View {
    let team: FeedTeam
    let done: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var didCopy = false
    @State private var appeared = false

    /// The join link once the backend has issued one, otherwise the invite code
    /// on its own — the code is enough to join from the "انضم بالرمز" screen.
    private var shareValue: String {
        team.inviteURL?.absoluteString ?? team.inviteCode
    }

    private var shareMessage: String {
        team.inviteURL == nil
            ? "انضم إلى «\(team.name)» في تمرين برمز الدعوة: \(team.inviteCode)"
            : "انضم إلى «\(team.name)» في تمرين:\n\(shareValue)"
    }

    private var whatsAppURL: URL? {
        URL(string: "whatsapp://send?text=\(shareMessage.urlQueryEncoded)")
    }

    private var messagesURL: URL? {
        URL(string: "sms:&body=\(shareMessage.urlQueryEncoded)")
    }

    /// WhatsApp is hidden rather than shown broken when it isn't installed.
    /// Needs `whatsapp` in LSApplicationQueriesSchemes to answer truthfully.
    private var isWhatsAppInstalled: Bool {
        guard let whatsAppURL else { return false }
        return UIApplication.shared.canOpenURL(whatsAppURL)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                teamBadge

                VStack(spacing: 8) {
                    Text("«\(team.name)» جاهز!")
                        .font(TamrinFont.largeTitle)
                        .tracking(-0.8)
                        .multilineTextAlignment(.center)
                    Text("المواعيد القادمة جاهزة. أرسل الرابط للأعضاء وخلهم ينضمون.")
                        .font(TamrinFont.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                }

                linkCard
                copyButton
                channels

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            TamrinActionButton(title: "ادخل إلى التمرين", prominent: false, action: done)
                .padding(.horizontal, 22)
                .padding(.bottom, 10)
        }
        .onAppear { appeared = true }
    }

    private var teamBadge: some View {
        Group {
            if let data = team.avatarData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(.rect(cornerRadius: 30, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous).fill(TamrinTheme.ink)
                    Image(systemName: team.symbol)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 96, height: 96)
            }
        }
        .shadow(color: .black.opacity(0.16), radius: 26, y: 12)
        .scaleEffect(appeared ? 1 : 0.6)
        .animation(.spring(response: 0.5, dampingFraction: 0.68), value: appeared)
    }

    /// The link itself, shown so the organizer can see what they're about to
    /// send, with the join code underneath for anyone typing it by hand.
    private var linkCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(.tint.opacity(0.14), in: .circle)
                Text(displayLink)
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // A latin URL reads left-to-right even on this RTL page.
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().opacity(0.5)

            HStack {
                Text("رمز الانضمام")
                    .font(TamrinFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(team.inviteCode)
                    .font(TamrinFont.font(size: 18, weight: .bold))
                    .kerning(3)
            }
        }
        .padding(16)
        .background(TamrinTheme.glass, in: .rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.05), radius: 18, y: 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("رابط الانضمام، رمز الدعوة \(team.inviteCode)")
    }

    private var displayLink: String {
        guard let url = team.inviteURL else { return team.inviteCode }
        return url.absoluteString.replacingOccurrences(of: "https://", with: "")
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = shareValue
            Haptics.success()
            withAnimation(.snappy) { didCopy = true }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.snappy) { didCopy = false }
            }
        } label: {
            Label(didCopy ? "نُسخ الرابط" : "انسخ الرابط",
                  systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity)
        }
        .tamrinPrimaryAction()
        .accessibilityLabel("انسخ رابط الانضمام")
    }

    private var channels: some View {
        VStack(spacing: 12) {
            Text("أو أرسله مباشرة عبر")
                .font(TamrinFont.footnote)
                .foregroundStyle(.tertiary)

            HStack(spacing: 10) {
                if isWhatsAppInstalled, let whatsAppURL {
                    Button {
                        Haptics.impact(.light)
                        openURL(whatsAppURL)
                    } label: {
                        ShareChannelLabel(title: "واتساب", symbol: "bubble.left.fill", tint: .whatsAppGreen)
                    }
                    .buttonStyle(SpringCardPressStyle())
                }

                if let messagesURL {
                    Button {
                        Haptics.impact(.light)
                        openURL(messagesURL)
                    } label: {
                        ShareChannelLabel(title: "الرسائل", symbol: "message.fill", tint: .blue)
                    }
                    .buttonStyle(SpringCardPressStyle())
                }

                ShareLink(
                    item: shareValue,
                    subject: Text("انضم إلى \(team.name)"),
                    message: Text(shareMessage)
                ) {
                    ShareChannelLabel(title: "غير ذلك", symbol: "square.and.arrow.up", tint: .secondary)
                }
                .buttonStyle(SpringCardPressStyle())
            }
        }
        .padding(.top, 4)
    }
}

/// One share destination — a tinted glyph over its name, sized so two or three
/// of them fill the row evenly.
private struct ShareChannelLabel: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(tint, in: .circle)
            Text(title)
                .font(TamrinFont.font(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(TamrinTheme.glass, in: .rect(cornerRadius: 24))
        .contentShape(.rect)
    }
}

private extension Color {
    static let whatsAppGreen = Color(red: 0.15, green: 0.83, blue: 0.40)
}

private extension String {
    /// Percent-encoding for a value going into a URL query, escaping `&`, `=`
    /// and `+` too — the share text carries a link and arabic punctuation.
    var urlQueryEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

/// Standalone session composer — reuses the wizard's TemplateComposerPage.
/// Create mode (no editingEventID) adds date(s) to the current exercise;
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
                    save: {
                        guard !saving else { return }
                        if editingEventID != nil, editingTemplateID != nil {
                            showSaveScope = true
                        } else {
                            save(scope: .occurrenceOnly)
                        }
                    }
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
        .sheetPresentationHaptic()
        .interactiveDismissDisabled(saving)
        .confirmationDialog(
            "أين تريد حفظ التعديل؟",
            isPresented: $showSaveScope,
            titleVisibility: .visible
        ) {
            Button("حفظ في القالب والمواعيد القادمة") {
                save(scope: .seriesTemplate)
            }
            Button("حفظ لهذا الموعد فقط") {
                save(scope: .occurrenceOnly)
            }
            Button("تراجع", role: .cancel) {}
        } message: {
            Text("يمكنك تعديل هذا الموعد وحده، أو اعتماد التغييرات في القالب الذي تُنشأ منه المواعيد القادمة.")
        }
        .alert("تعذر حفظ الموعد", isPresented: Binding(
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
                Haptics.success()
                isPresented = false
            } catch {
                saving = false
                failureMessage = error.localizedDescription
                Haptics.error()
            }
        }
    }
}
