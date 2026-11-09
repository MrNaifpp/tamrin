//
//  PickPlayersStep.swift
//  Sirr
//
//  The last step of "تمرين جديد": pick one of your groups, or start a new one,
//  then tick who plays. Built only from Apple's own SwiftUI components — a
//  NavigationStack of Lists, the system's multi-selection, search and toolbar.
//  Spec: docs/superpowers/specs/2026-11-09-new-event-pick-players-design.md
//

import SwiftUI

struct PickPlayersStep: View {
    let sources: PickSources
    let isSaving: Bool
    /// Back to the details step. This step owns the navigation bar, so the
    /// flow's own header is hidden here.
    let back: () -> Void
    let confirm: (PlayerPick) -> Void

    private enum Route: Hashable {
        case newGroup
        case group(PickGroup)
    }

    var body: some View {
        NavigationStack {
            List {
                // Always offered: a new, empty group is how the flow worked
                // before this step existed.
                Section {
                    NavigationLink(value: Route.newGroup) {
                        Label("مجموعة جديدة", systemImage: "plus")
                            .font(TamrinFont.headline)
                            .foregroundStyle(Color.accentColor)
                    }
                } footer: {
                    Text(sources.pastPlayers.isEmpty
                         ? "أنشئ مجموعة جديدة وادعُ لاعبيها برابط"
                         : "اختر من اللاعبين اللي لعبوا معك قبل")
                        .font(TamrinFont.font(size: 13))
                }

                if !sources.groups.isEmpty {
                    Section {
                        ForEach(sources.groups) { group in
                            NavigationLink(value: Route.group(group)) {
                                GroupRow(group: group)
                            }
                        }
                    } header: {
                        Text("مجموعاتك")
                            .font(TamrinFont.font(size: 13, weight: .medium))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("مين بيلعب معك؟")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("رجوع", action: back)
                        .disabled(isSaving)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .newGroup:
                    PickPeopleList(
                        title: String(localized: "مجموعة جديدة"),
                        people: sources.pastPlayers,
                        sourceGroup: nil,
                        isSaving: isSaving,
                        confirm: confirm
                    )
                case .group(let group):
                    PickPeopleList(
                        title: group.name,
                        people: group.members,
                        sourceGroup: group,
                        isSaving: isSaving,
                        confirm: confirm
                    )
                }
            }
        }
    }
}

// MARK: - Group row

private struct GroupRow: View {
    let group: PickGroup

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(TamrinFont.headline)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text("\(group.members.count) لاعب")
                    if let lastPlayedAt = group.lastPlayedAt {
                        Text("·")
                        Text(lastPlayedAt, format: .relative(presentation: .named))
                    }
                }
                .font(TamrinFont.font(size: 13))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            // A few faces, overlapping like Apple's own shared-group rows.
            HStack(spacing: -10) {
                ForEach(group.members.prefix(3)) { person in
                    MemberAvatar(name: person.name, size: 30, imageUrl: person.avatarUrl)
                        .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - People list

private struct PickPeopleList: View {
    let title: String
    let people: [PickPerson]
    let sourceGroup: PickGroup?
    let isSaving: Bool
    let confirm: (PlayerPick) -> Void

    @State private var selected: Set<UUID> = []
    @State private var query = ""

    init(
        title: String,
        people: [PickPerson],
        sourceGroup: PickGroup?,
        isSaving: Bool,
        confirm: @escaping (PlayerPick) -> Void
    ) {
        self.title = title
        self.people = people
        self.sourceGroup = sourceGroup
        self.isSaving = isSaving
        self.confirm = confirm
        // Picked people are invited, not seated, so there is no seat limit
        // here. A group starts fully ticked (the usual case is "the same
        // people again"); a new group starts empty.
        let start = sourceGroup == nil ? [] : people.map(\.id)
        _selected = State(initialValue: Set(start))
    }

    private var filtered: [PickPerson] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return people }
        return people.filter { $0.name.localizedStandardContains(q) }
    }

    private var allSelected: Bool {
        selected.count == people.count
    }

    /// An existing group needs at least one player; a new group may start
    /// with nobody and grow through the invite link.
    private var canConfirm: Bool {
        !isSaving && (sourceGroup == nil || !selected.isEmpty)
    }

    var body: some View {
        Group {
            if people.isEmpty {
                ContentUnavailableView(
                    "ما فيه لاعبين",
                    systemImage: "person.2",
                    description: Text("أنشئ التمرين وأرسل رابط الدعوة")
                )
            } else {
                List(selection: $selected) {
                    Section {
                        ForEach(filtered) { person in
                            HStack(spacing: 12) {
                                MemberAvatar(name: person.name, size: 34, imageUrl: person.avatarUrl)
                                    .accessibilityHidden(true)
                                Text(person.name)
                                    .font(TamrinFont.body)
                            }
                            .tag(person.id)
                        }
                    } header: {
                        Text("\(selected.count) من \(people.count)")
                            .font(TamrinFont.font(size: 13, weight: .medium))
                    } footer: {
                        Text("يوصلهم إشعار ويسجّلون بأنفسهم")
                            .font(TamrinFont.font(size: 13))
                    }
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, .constant(.active))
                .searchable(text: $query, prompt: Text("ابحث بالاسم"))
                .overlay {
                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("إضافة") {
                        confirm(PlayerPick(sourceGroup: sourceGroup, selected: selected))
                    }
                    .disabled(!canConfirm)
                }
            }
            if !people.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button(allSelected ? "إلغاء التحديد" : "تحديد الكل") {
                        if allSelected {
                            selected = []
                        } else {
                            selected = Set(people.map(\.id))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let people = ["فارس", "سعود", "خالد", "عبدالله", "محمد"].map {
        PickPerson(id: UUID(), name: $0, avatarUrl: nil)
    }
    let sources = PickSources(
        groups: [
            PickGroup(id: UUID(), name: "شباب الخميس",
                      lastPlayedAt: Date().addingTimeInterval(-3 * 86_400),
                      members: Array(people.prefix(4))),
            PickGroup(id: UUID(), name: "بادل الدوام", lastPlayedAt: nil,
                      members: Array(people.suffix(2)))
        ],
        pastPlayers: people
    )
    return PickPlayersStep(sources: sources, isSaving: false, back: {}) { _ in }
        .environment(\.layoutDirection, .rightToLeft)
}
