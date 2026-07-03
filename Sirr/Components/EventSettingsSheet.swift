//
//  EventSettingsSheet.swift
//  Sirr
//
//  Owner-only "إعدادات إضافية" sheet opened from the gear button on the event
//  details screen. Guest-limit and guest-approval controls are UI-only for now
//  (local state, not persisted). The weekly-recurrence toggle and deletion are
//  wired to their RPCs via EventService.
//

import SwiftUI

struct EventSettingsSheet: View {
    let event: EventData
    /// Called after the event has been deleted server-side.
    var onDeleted: () -> Void
    /// Called when the weekly-recurrence state changes (nil = series ended).
    var onRecurrenceChanged: ((EventTemplateRecord?) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    // UI-only state (not persisted yet).
    @State private var guestLimit: GuestLimit = .locked
    @State private var guestApproval = false

    // Weekly recurrence (persisted via enable_recurrence / end_recurrence).
    @State private var recurrenceTemplate: EventTemplateRecord?
    @State private var recurrenceEnabled = false
    @State private var isUpdatingRecurrence = false
    @State private var showEndRecurrenceConfirm = false
    @State private var recurrenceError: String?

    // Delete flow.
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    enum GuestLimit: String, CaseIterable, Identifiable {
        case locked = "مقفل"
        case one = "1"
        case two = "2"
        case three = "3"
        case unlimited = "غير محدود"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color(white: 0.10).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        playersSection
                        managementSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .padding(.bottom, 32)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .task {
            guard let templateId = event.templateId else { return }
            if let template = try? await EventService.shared.getEventTemplate(templateId: templateId) {
                recurrenceTemplate = template
                recurrenceEnabled = template.endedAt == nil
            }
        }
        .confirmationDialog(
            "حذف المناسبة",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("حذف", role: .destructive) { handleDelete() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("سيتم حذف المناسبة وجميع المشاركين نهائيًا. لا يمكن التراجع عن هذا الإجراء.")
        }
        .confirmationDialog(
            "إنهاء التكرار",
            isPresented: $showEndRecurrenceConfirm,
            titleVisibility: .visible
        ) {
            Button("إنهاء", role: .destructive) { handleEndRecurrence() }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("لن تُنشأ تمارين جديدة من هذه السلسلة. التمارين الحالية تبقى كما هي.")
        }
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            Text("إعدادات إضافية")
                .font(.appSubheadline)
                .foregroundStyle(.white)

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 40, height: 40)
                        .background(Color.white)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - Sections

    private var playersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("اللاعبين")

            menuRow(title: "لاعبين ضيوف", value: guestLimit.rawValue) {
                ForEach(GuestLimit.allCases) { option in
                    Button(option.rawValue) { guestLimit = option }
                }
            }
            caption("حدد عدد الضيوف الذين يمكن للشخص إحضارهم.")

            toggleRow(title: "الموافقة على الضيوف", isOn: $guestApproval)
            caption("الموافقة على الضيوف الجدد أولًا، حتى يمكنهم الانضمام إلى المناسبة.")
        }
    }

    private var managementSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("إدارة التمرين")

            HStack {
                Text("يتكرر أسبوعيًا")
                    .font(.appBody)
                    .foregroundStyle(.white)
                Spacer()
                if isUpdatingRecurrence {
                    ProgressView().tint(.white)
                } else {
                    Toggle("", isOn: recurrenceToggleBinding)
                        .labelsHidden()
                        .tint(.blue)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white.opacity(0.08))
            )
            caption("يُنشأ تمرين الأسبوع القادم تلقائيًا قبل موعده بـ٣ أيام، ويصل إشعار لجميع الأعضاء.")

            if let recurrenceError {
                Text(recurrenceError)
                    .font(.appCaption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }

            deleteButton

            if let deleteError {
                Text(deleteError)
                    .font(.appCaption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var deleteButton: some View {
        Button {
            showDeleteConfirm = true
        } label: {
            HStack {
                Spacer()
                if isDeleting {
                    ProgressView().tint(.red)
                } else {
                    Text("حذف المناسبة")
                        .font(.appBody)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDeleting)
    }

    // MARK: - Reusable rows

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.appBody)
            .foregroundStyle(Color(white: 0.5))
            .padding(.horizontal, 4)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.appCaption)
            .foregroundStyle(Color(white: 0.5))
            .padding(.horizontal, 4)
    }

    private func menuRow<Content: View>(
        title: String,
        value: String,
        @ViewBuilder menu: () -> Content
    ) -> some View {
        Menu {
            menu()
        } label: {
            HStack {
                Text(title)
                    .font(.appBody)
                    .foregroundStyle(.white)
                Spacer()
                HStack(spacing: 8) {
                    Text(value)
                        .font(.appBody)
                        .foregroundStyle(Color(white: 0.55))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(white: 0.55))
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white.opacity(0.08))
            )
        }
    }

    private func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.appBody)
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.blue)
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white.opacity(0.08))
        )
    }

    // MARK: - Actions

    /// Routes toggle changes: enabling is immediate, disabling asks first.
    private var recurrenceToggleBinding: Binding<Bool> {
        Binding(
            get: { recurrenceEnabled },
            set: { newValue in
                if newValue {
                    handleEnableRecurrence()
                } else {
                    showEndRecurrenceConfirm = true
                }
            }
        )
    }

    private func handleEnableRecurrence() {
        guard !isUpdatingRecurrence else { return }
        isUpdatingRecurrence = true
        recurrenceError = nil
        Task {
            defer { isUpdatingRecurrence = false }
            do {
                let template = try await EventService.shared.enableRecurrence(eventId: event.id)
                recurrenceTemplate = template
                recurrenceEnabled = true
                onRecurrenceChanged?(template)
            } catch {
                recurrenceError = "تعذر تفعيل التكرار. حاول مرة أخرى."
            }
        }
    }

    private func handleEndRecurrence() {
        guard let template = recurrenceTemplate, !isUpdatingRecurrence else { return }
        isUpdatingRecurrence = true
        recurrenceError = nil
        Task {
            defer { isUpdatingRecurrence = false }
            do {
                try await EventService.shared.endRecurrence(templateId: template.id)
                recurrenceEnabled = false
                onRecurrenceChanged?(nil)
            } catch {
                recurrenceError = "تعذر إنهاء التكرار. حاول مرة أخرى."
            }
        }
    }

    private func handleDelete() {
        guard !isDeleting else { return }
        isDeleting = true
        deleteError = nil
        Task {
            defer { isDeleting = false }
            do {
                try await EventService.shared.deleteEvent(eventId: event.id)
                onDeleted()
                dismiss()
            } catch {
                deleteError = "تعذر حذف المناسبة. حاول مرة أخرى."
            }
        }
    }
}
