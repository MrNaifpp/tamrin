import SwiftUI

/// Event detail page — the designer's OccurrenceDetailView (member view) bound
/// to HomeStore. Register/withdraw are local in-memory mutations; payment is
/// a deferred placeholder; the admin section and edit/cancel menu are omitted.
struct EventDetailView: View {
    @Bindable var feed: HomeStore
    let occurrence: FeedOccurrence
    var artName: String = "ExerciseArt1"
    @Environment(\.dismiss) private var dismiss
    @State private var showWithdrawConfirm = false
    @State private var showRegisterFlow = false
    @State private var template: EventTemplateRecord?
    @State private var showSkipConfirm = false
    @State private var showSkipAlreadyOpen = false
    @State private var showEndConfirm = false

    /// The live weekly-series template (nil once the series is ended).
    private var liveTemplate: EventTemplateRecord? {
        guard let template, template.endedAt == nil else { return nil }
        return template
    }

    private var roster: [FeedMember] { feed.roster(for: occurrence) }
    private var myRegistration: FeedMember? { feed.myRegistration(for: occurrence) }
    private var confirmedCount: Int { feed.registeredCount(for: occurrence) }
    private var waitingCount: Int { feed.waitlistCount(for: occurrence) }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                ZStack {
                    Image(artName)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    Image(artName)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                        .blur(radius: 26, opaque: true)
                        .mask {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.33),
                                .init(color: .black, location: 0.46),
                                .init(color: .black, location: 1)
                            ], startPoint: .top, endPoint: .bottom)
                        }
                }
            }
            .ignoresSafeArea()

            LinearGradient(stops: [
                .init(color: .black.opacity(0.32), location: 0),
                .init(color: .black.opacity(0.06), location: 0.26),
                .init(color: .black.opacity(0.30), location: 0.55),
                .init(color: .black.opacity(0.58), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    heroTitle
                        .padding(.top, 264)
                        .padding(.bottom, 6)

                    if !occurrence.isCancelled { participationCTA }

                    progressPanel

                    if liveTemplate != nil { seriesPanel }

                    Text("القائمة")
                        .font(TamrinFont.font(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.top, 8)
                        .padding(.horizontal, 4)

                    rosterRows
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .accessibilityLabel("إغلاق")
        }
        .environment(\.layoutDirection, .rightToLeft)
        .colorScheme(.dark)
        .sheet(isPresented: $showWithdrawConfirm) {
            RegistrationCancellationSheet(feed: feed, occurrence: occurrence)
        }
        .sheet(isPresented: $showRegisterFlow) {
            RegistrationFlowSheet(feed: feed, occurrence: occurrence, artName: artName)
        }
        .task {
            if occurrence.isRecurring, let tid = occurrence.templateId {
                template = await feed.loadTemplate(tid)
            }
        }
        .alert("تخطَّ الأسبوع القادم؟", isPresented: $showSkipConfirm) {
            Button("تخطَّ", role: .destructive) { skipNextWeek() }
            Button("تراجع", role: .cancel) {}
        } message: {
            Text("لن يُنشأ تمرين الأسبوع القادم، وتستمر السلسلة بعده كالمعتاد.")
        }
        .alert("التمرين القادم منشور بالفعل", isPresented: $showSkipAlreadyOpen) {
            Button("حسنًا", role: .cancel) {}
        } message: {
            Text("تمرين الأسبوع القادم منشور. إذا أردت إلغاءه، افتح صفحته واحذفه.")
        }
        .alert("إنهاء التكرار؟", isPresented: $showEndConfirm) {
            Button("إنهاء", role: .destructive) { endSeries() }
            Button("تراجع", role: .cancel) {}
        } message: {
            Text("بيوقف إنشاء التمارين القادمة تلقائيًا، والتمارين المنشورة تبقى كما هي.")
        }
    }

    private func skipNextWeek() {
        guard let tid = occurrence.templateId else { return }
        Task {
            let result = await feed.skipNextWeek(templateId: tid, eventId: occurrence.id)
            if case .alreadyOpen = result { showSkipAlreadyOpen = true }
            template = await feed.loadTemplate(tid)
        }
    }

    private func endSeries() {
        guard let tid = occurrence.templateId else { return }
        Task {
            await feed.endSeries(templateId: tid)
            template = await feed.loadTemplate(tid)   // endedAt set → panel hides
        }
    }

    private var heroTitle: some View {
        VStack(spacing: 7) {
            if occurrence.isCancelled {
                Text("تم إلغاء الموعد")
                    .font(TamrinFont.font(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 6)
                    .background(.red.opacity(0.85), in: .capsule)
            }
            Text(occurrence.title)
                .font(TamrinFont.font(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2).minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
            Text("يوم \(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
                .font(TamrinFont.font(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var participationCTA: some View {
        if let mine = myRegistration {
            Button { showWithdrawConfirm = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: mine.status == .registered ? "checkmark.circle.fill" : "clock.fill")
                        .foregroundStyle(mine.status == .registered ? TamrinTheme.lime : .orange)
                    Text(mine.status == .registered ? "مكانك محفوظ" : "أنت في قائمة الانتظار")
                        .font(TamrinFont.font(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(mine.status == .registered ? "اعتذر" : "انسحب")
                        .font(TamrinFont.font(size: 13, weight: .medium))
                        .foregroundStyle(.red.opacity(0.95))
                }
                .padding(.horizontal, 18).frame(maxWidth: .infinity).frame(height: 52)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .accessibilityHint("يفتح تأكيد الاعتذار عن التمرين")

            if mine.status == .registered, occurrence.price > 0 {
                Label("الدفع — قريبًا", systemImage: "creditcard")
                    .font(TamrinFont.headline)
                    .foregroundStyle(TamrinTheme.ink.opacity(0.55))
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(.white.opacity(0.5), in: .capsule)
                    .accessibilityLabel("الدفع قريبًا")
            }
        } else {
            let full = confirmedCount >= occurrence.capacity
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showRegisterFlow = true
            } label: {
                Label(full ? "انضم لقائمة الانتظار" : "سجل في التمرين", systemImage: "plus")
                    .font(TamrinFont.font(size: 16, weight: .bold))
                    .foregroundStyle(TamrinTheme.ink)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .contentShape(.capsule)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(.white.opacity(0.94))
        }
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("المسجلون في التمرين")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                // "٩ من ١٤" — the word «من» disambiguates registered-vs-capacity
                // and pins the bidi order (the designer's "9\14" could flip in RTL).
                Text("\(confirmedCount.formatted()) من \(occurrence.capacity.formatted())")
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            ProgressView(value: Double(confirmedCount), total: Double(max(occurrence.capacity, 1)))
                .tint(TamrinTheme.lime)
            if waitingCount > 0 {
                Text("\(waitingCount.formatted()) في قائمة الانتظار")
                    .font(TamrinFont.font(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.white.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
    }

    /// Weekly-series card: next auto-generated occurrence + owner controls
    /// (skip next week / end recurrence). Mirrors the old EventHeroDetailView
    /// series section, restyled for the designer detail page.
    @ViewBuilder
    private var seriesPanel: some View {
        if let tpl = liveTemplate {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "repeat")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TamrinTheme.lime)
                    Text("سلسلة متكررة")
                        .font(TamrinFont.font(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("أسبوعيًا")
                        .font(TamrinFont.font(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.white.opacity(0.14), in: .capsule)
                }

                if tpl.skipNext {
                    Label("سيتم تخطّي الأسبوع القادم", systemImage: "forward.end.fill")
                        .font(TamrinFont.font(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                } else {
                    Text("التمرين القادم: يوم \(tpl.nextOccurrenceAt.arabicDay)، الساعة \(tpl.nextOccurrenceAt.arabicTime)")
                        .font(TamrinFont.font(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }

                Text("يُنشأ تمرين الأسبوع القادم تلقائيًا قبل موعده بـ٣ أيام.")
                    .font(TamrinFont.font(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))

                if feed.isCurrentTeamOwner {
                    HStack(spacing: 10) {
                        if !tpl.skipNext {
                            Button("تخطَّ الأسبوع القادم") { showSkipConfirm = true }
                                .font(TamrinFont.font(size: 13, weight: .bold))
                                .buttonStyle(.glass)
                                .buttonBorderShape(.capsule)
                        }
                        Button("إنهاء التكرار", role: .destructive) { showEndConfirm = true }
                            .font(TamrinFont.font(size: 13, weight: .bold))
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                            .tint(.red)
                    }
                }
            }
            .padding(16)
            .background(.white.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var rosterRows: some View {
        if roster.isEmpty {
            Text("كن أول المسجلين.")
                .font(TamrinFont.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(.white.opacity(0.1), in: .rect(cornerRadius: 16, style: .continuous))
        } else {
            VStack(spacing: 8) {
                ForEach(roster) { person in
                    HStack(spacing: 12) {
                        MemberAvatar(name: person.name)
                        Text(person.name)
                            .font(TamrinFont.font(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                        if person.status == .waitlisted {
                            Image(systemName: "clock")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.orange)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(TamrinTheme.lime)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(.white.opacity(0.1), in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    }
                }
            }
        }
    }
}

private struct MemberAvatar: View {
    let name: String
    var size: CGFloat = 34
    var body: some View {
        Circle()
            .fill(.white.opacity(0.28))
            .frame(width: size, height: size)
            .overlay {
                Text(String(name.prefix(1)))
                    .font(TamrinFont.font(size: size * 0.44, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// Registration flow (designer's RegistrationFlowSheet) bound to the mock feed.
/// Payment steps are intentionally omitted: this project configures no payment
/// methods, so the designer's own flow goes selection → success (paid events
/// keep using the "الدفع — قريبًا" placeholder in the detail view).
private struct RegistrationFlowSheet: View {
    @Bindable var feed: HomeStore
    let occurrence: FeedOccurrence
    var artName: String = "ExerciseArt1"

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .selection
    @State private var registerMe = false
    @State private var guestNames: [String] = []
    @State private var showGuestSection = false
    @State private var submitting = false
    @State private var failureMessage: String?
    @FocusState private var focusedGuest: Int?

    private enum Step { case selection, success }

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
        .alert("ما تم التسجيل", isPresented: Binding(
            get: { failureMessage != nil },
            set: { if !$0 { failureMessage = nil } }
        )) {
            Button("حسنًا", role: .cancel) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

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
                        Text(occurrence.title)
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
                            MemberAvatar(name: feed.profileName)
                            Text(feed.profileName.isEmpty ? "أنا" : feed.profileName)
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
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(registerMe ? .white.opacity(0.92) : .white.opacity(0.14))

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
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
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
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                    }

                    let others = feed.roster(for: occurrence).prefix(3)
                    if !others.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(Array(others)) { person in
                                HStack(spacing: 12) {
                                    MemberAvatar(name: person.name, size: 30)
                                    Text(person.name)
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
                Group {
                    if submitting {
                        ProgressView().tint(.white)
                    } else {
                        Text("سجـل")
                            .font(TamrinFont.font(size: 17, weight: .bold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 42)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(Color(red: 0.20, green: 0.47, blue: 0.96))
            .disabled(!canSubmit || submitting)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func submitRegistration() {
        guard !submitting else { return }
        submitting = true
        Task {
            let outcome = await feed.submitRegistration(registerSelf: registerMe, guests: validGuests, for: occurrence)
            submitting = false
            switch outcome {
            case .success:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                step = .success
            case .failure(let message):
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                failureMessage = message
            }
        }
    }

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
}

/// Withdraw confirmation (designer's RegistrationCancellationSheet) bound to the
/// mock feed. Slide-to-confirm frees the seat via `feed.withdraw(from:)`.
private struct RegistrationCancellationSheet: View {
    @Bindable var feed: HomeStore
    let occurrence: FeedOccurrence
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("متأكد إنك بتعتذر؟")
                .font(TamrinFont.font(size: 26, weight: .bold))
            Text("بنحرر مكانك لواحد من الربع. ما راح يتغير شيء إلا بعد ما تسحب للتأكيد.")
                .font(TamrinFont.font(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            SlideToConfirmButton(title: "اسحب لتأكيد الاعتذار") {
                feed.withdraw(from: occurrence)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            }

            Button("خلاص، بكمل") { dismiss() }
                .font(TamrinFont.font(size: 15, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 44)
        }
        .padding(22)
        .presentationDetents([.height(310)])
        .presentationDragIndicator(.visible)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

private struct SlideToConfirmButton: View {
    let title: String
    let confirm: () -> Void
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let knob: CGFloat = 54
            let travel = max(proxy.size.width - knob - 8, 1)

            // `leading` is the physical right edge in the app's RTL environment.
            ZStack(alignment: .leading) {
                Capsule().fill(Color.red.opacity(0.16))
                Text(title)
                    .font(TamrinFont.font(size: 14, weight: .bold))
                    .foregroundStyle(.red.opacity(0.92 - Double(progress) * 0.65))
                    .frame(maxWidth: .infinity)

                Circle()
                    .fill(.red)
                    .frame(width: knob, height: knob)
                    .overlay(Image(systemName: progress > 0.78 ? "checkmark" : "chevron.left.2").font(.system(size: 16, weight: .bold)).foregroundStyle(.white))
                    .padding(4)
                    .offset(x: travel * progress)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in progress = min(max(-value.translation.width / travel, 0), 1) }
                            .onEnded { _ in
                                if progress > 0.82 { confirm() }
                                else { withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { progress = 0 } }
                            }
                    )
            }
            .contentShape(.capsule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityHint("اسحب من اليمين إلى اليسار")
            .accessibilityAction { confirm() }
        }
        .frame(height: 62)
    }
}

#Preview {
    let feed = HomeStore.preview
    return EventDetailView(feed: feed, occurrence: feed.occurrences[0], artName: "ExerciseArt1")
}
