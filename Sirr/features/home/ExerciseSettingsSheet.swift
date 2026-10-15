import SwiftUI

/// «الإعدادات» on an exercise: when registration opens, who grants the seat,
/// and whether members may bring guests. Saved on this exercise and on every
/// one after it until the organizer changes it again.
struct ExerciseSettingsSheet: View {
    @Bindable var feed: HomeStore
    let occurrence: FeedOccurrence

    @Environment(\.dismiss) private var dismiss
    @State private var settings: RegistrationSettings
    @State private var opensOnSchedule: Bool
    @State private var daysBefore: Int
    @State private var openingTime: Date
    @State private var isSaving = false
    @State private var isOpening = false
    @State private var errorMessage: String?

    private let original: RegistrationSettings
    private static let dayOptions = Array(0...7)
    private static let defaultOpening = RegistrationOpeningRule(daysBefore: 2, minuteOfDay: 12 * 60)

    init(feed: HomeStore, occurrence: FeedOccurrence) {
        self.feed = feed
        self.occurrence = occurrence
        let current = occurrence.registrationSettings
        original = current
        let rule = current.opening ?? Self.defaultOpening
        _settings = State(initialValue: current)
        _opensOnSchedule = State(initialValue: current.opening != nil)
        _daysBefore = State(initialValue: rule.daysBefore)
        _openingTime = State(initialValue: rule.timeOfDay)
    }

    /// The live exercise, so «افتح التسجيل الآن» redraws the moment it lands.
    private var liveOccurrence: FeedOccurrence {
        feed.allOccurrences.first { $0.id == occurrence.id } ?? occurrence
    }

    private var draft: RegistrationSettings {
        var draft = settings
        draft.opening = opensOnSchedule
            ? RegistrationOpeningRule(
                daysBefore: daysBefore,
                minuteOfDay: RegistrationOpeningRule.minuteOfDay(from: openingTime)
            )
            : nil
        return draft
    }

    /// When this exercise would open under the rule on screen.
    private var draftOpensAt: Date? {
        draft.opening?.opensAt(for: occurrence.startAt)
    }

    private var opensAfterStart: Bool {
        guard let draftOpensAt else { return false }
        return draftOpensAt >= occurrence.startAt
    }

    private var hasChanges: Bool { draft != original }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    openingSection
                    approvalSection
                    guestsSection

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(TamrinFont.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.blurReplace)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 24)
                .sheetContentHeight()
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(TamrinTheme.sheet)
            .animation(.smooth(duration: 0.26), value: opensOnSchedule)
            .animation(.smooth(duration: 0.26), value: errorMessage)
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء", role: .cancel) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("حفظ") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(!hasChanges || opensAfterStart)
                    }
                }
            }
        }
        .environment(\.layoutDirection, .tamrin)
        .fittedSheet(minHeight: 360, includesNavigationBar: true)
        .interactiveDismissDisabled(isSaving || hasChanges)
        .sheetPresentationHaptic()
    }

    // MARK: Sections

    private var openingSection: some View {
        section("فتح التسجيل") {
            Toggle(isOn: $opensOnSchedule.animation(.smooth(duration: 0.26))) {
                rowTitle("في موعد محدد")
            }
            .rowPadding()

            if opensOnSchedule {
                Divider().padding(.leading, 16)

                HStack {
                    rowTitle("يوم الفتح")
                    Spacer(minLength: 8)
                    Picker("يوم الفتح", selection: $daysBefore) {
                        ForEach(Self.dayOptions, id: \.self) { days in
                            Text(Self.dayTitle(days)).tag(days)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(.secondary)
                }
                .rowPadding(vertical: 6)

                Divider().padding(.leading, 16)

                DatePicker(selection: $openingTime, displayedComponents: .hourAndMinute) {
                    rowTitle("وقت الفتح")
                }
                .environment(\.locale, .tamrin)
                .rowPadding(vertical: 6)
            }

            if let opensAt = liveOccurrence.registrationOpensAt,
               opensAt > .now,
               !liveOccurrence.isPast() {
                Divider().padding(.leading, 16)
                openNowRow(opensAt: opensAt)
            }
        } footer: {
            if opensAfterStart {
                Text("وقت الفتح بعد بداية التمرين")
                    .foregroundStyle(.red)
            } else if opensOnSchedule, let draftOpensAt {
                Text("يفتح يوم \(draftOpensAt.arabicDay)، الساعة \(draftOpensAt.arabicTime)")
            }
        }
    }

    private func openNowRow(opensAt: Date) -> some View {
        Button {
            Task { await openNow() }
        } label: {
            HStack {
                Text("افتح التسجيل الآن")
                    .font(TamrinFont.font(size: 16, weight: .bold))
                    .foregroundStyle(TamrinTheme.ink)
                Spacer(minLength: 8)
                if isOpening {
                    ProgressView()
                } else {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TamrinTheme.ink)
                }
            }
            .rowPadding()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isOpening || isSaving)
    }

    private var approvalSection: some View {
        section("قبول التسجيل") {
            Picker("قبول التسجيل", selection: $settings.approvalMode) {
                Text("تلقائي").tag(RegistrationApprovalMode.auto)
                Text("يدوي").tag(RegistrationApprovalMode.manual)
            }
            .pickerStyle(.segmented)
            .padding(12)
        } footer: {
            EmptyView()
        }
    }

    private var guestsSection: some View {
        section("الضيوف") {
            Toggle(isOn: $settings.guestsAllowed) {
                rowTitle("يسجّل العضو ضيوف معه")
            }
            .rowPadding()
        } footer: {
            EmptyView()
        }
    }

    // MARK: Building blocks

    private func section<Content: View, Footer: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TamrinFont.font(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)

            VStack(spacing: 0) {
                content()
            }
            .background(TamrinTheme.card, in: .rect(cornerRadius: 22, style: .continuous))

            footer()
                .font(TamrinFont.font(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
        }
    }

    private func rowTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(TamrinFont.font(size: 16, weight: .medium))
            .foregroundStyle(.primary)
    }

    static func dayTitle(_ days: Int) -> String {
        switch days {
        case 0: String(localized: "يوم التمرين")
        case 1: String(localized: "قبله بيوم")
        case 2: String(localized: "قبله بيومين")
        default: String(localized: "قبله بـ\(days.formatted(.number.locale(.tamrin))) أيام")
        }
    }

    // MARK: Actions

    @MainActor
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        let message = await feed.updateRegistrationSettings(draft, for: liveOccurrence)
        isSaving = false
        if let message {
            Haptics.error()
            errorMessage = message
        } else {
            Haptics.success()
            dismiss()
        }
    }

    @MainActor
    private func openNow() async {
        guard !isOpening else { return }
        isOpening = true
        errorMessage = nil
        let message = await feed.openRegistrationNow(for: liveOccurrence)
        isOpening = false
        if let message {
            Haptics.error()
            errorMessage = message
        } else {
            Haptics.success()
        }
    }
}

private extension View {
    func rowPadding(vertical: CGFloat = 13) -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, vertical)
            .frame(minHeight: 52)
    }
}
