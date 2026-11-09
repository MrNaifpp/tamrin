//
//  PickPlayersStep.swift
//  Sirr
//
//  The last step of "تمرين جديد": pick one of your groups, or start a new one,
//  then tick who to invite. Drawn like the flow's earlier steps — a scroll of
//  separate cards on the flow's own background, with the action button pinned
//  at the bottom — from Apple's Button, NavigationStack and SF Symbols.
//  Spec: docs/superpowers/specs/2026-11-09-new-event-pick-players-design.md
//

import SwiftUI

struct PickPlayersStep: View {
    let sources: PickSources
    let isSaving: Bool
    /// Owned by the flow, so its header's back button can step out of a
    /// group's list before leaving this step.
    @Binding var path: NavigationPath
    let confirm: (PlayerPick) -> Void

    private enum Route: Hashable {
        case newGroup
        case group(PickGroup)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink(value: Route.newGroup) {
                        NewGroupCard(hasPastPlayers: !sources.pastPlayers.isEmpty)
                    }
                    .buttonStyle(SpringCardPressStyle())

                    if !sources.groups.isEmpty {
                        Text("مجموعاتك")
                            .font(TamrinFont.font(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                            .padding(.horizontal, 6)

                        ForEach(sources.groups) { group in
                            NavigationLink(value: Route.group(group)) {
                                GroupCard(group: group)
                            }
                            .buttonStyle(SpringCardPressStyle())
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            // The flow's header carries the title, counter and back button,
            // and the flow's background shows through, as on every other step.
            .toolbar(.hidden, for: .navigationBar)
            .containerBackground(.clear, for: .navigation)
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

// MARK: - Cards

/// Same card as the add sheet's options: a tinted icon tile, title, subtitle.
private struct NewGroupCard: View {
    let hasPastPlayers: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 50, height: 50)
                .background(Color.accentColor.opacity(0.14), in: .rect(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("مجموعة جديدة")
                    .font(TamrinFont.font(size: 17, weight: .bold))
                    .foregroundStyle(.primary)
                Text(hasPastPlayers
                     ? "اختر من اللاعبين اللي لعبوا معك قبل"
                     : "أنشئ مجموعة جديدة وادعُ لاعبيها برابط")
                    .font(TamrinFont.font(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.forward")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TamrinTheme.card, in: .rect(cornerRadius: 24, style: .continuous))
        .contentShape(.rect(cornerRadius: 24, style: .continuous))
    }
}

private struct GroupCard: View {
    let group: PickGroup

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(TamrinFont.font(size: 17, weight: .bold))
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text("\(group.members.count) لاعب")
                    if let lastPlayedAt = group.lastPlayedAt {
                        Text("·")
                        Text(lastPlayedAt, format: .relative(presentation: .named))
                    }
                }
                .font(TamrinFont.font(size: 12))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            HStack(spacing: -10) {
                ForEach(group.members.prefix(3)) { person in
                    MemberAvatar(name: person.name, size: 32, imageUrl: person.avatarUrl)
                        .overlay(Circle().stroke(TamrinTheme.card, lineWidth: 2))
                }
            }
            .accessibilityHidden(true)

            Image(systemName: "chevron.forward")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TamrinTheme.card, in: .rect(cornerRadius: 24, style: .continuous))
        .contentShape(.rect(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - People

private struct PickPeopleList: View {
    let title: String
    let people: [PickPerson]
    let sourceGroup: PickGroup?
    let isSaving: Bool
    let confirm: (PlayerPick) -> Void

    @State private var selected: Set<UUID>
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
        // Picked people are invited, not seated, so there is no seat limit.
        // A group starts fully ticked (the usual case is "the same people
        // again"); a new group starts empty.
        _selected = State(initialValue: sourceGroup == nil ? [] : Set(people.map(\.id)))
    }

    private var filtered: [PickPerson] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return people }
        return people.filter { $0.name.localizedStandardContains(q) }
    }

    private var allSelected: Bool { selected.count == people.count }

    /// An existing group needs at least one player; a new group may start
    /// with nobody and grow through the invite link.
    private var canConfirm: Bool {
        !isSaving && (sourceGroup == nil || !selected.isEmpty)
    }

    private var actionTitle: String {
        selected.isEmpty
            ? String(localized: "أنشئ بدون لاعبين")
            : String(localized: "ادعُ \(selected.count) لاعب")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(TamrinFont.font(size: 22, weight: .bold))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if !people.isEmpty {
                        Button(allSelected ? "إلغاء التحديد" : "تحديد الكل") {
                            selected = allSelected ? [] : Set(people.map(\.id))
                            Haptics.selection()
                        }
                        .font(TamrinFont.font(size: 15, weight: .medium))
                    }
                }
                .padding(.horizontal, 6)

                if people.isEmpty {
                    ContentUnavailableView(
                        "ما فيه لاعبين",
                        systemImage: "person.2",
                        description: Text("أنشئ التمرين وأرسل رابط الدعوة")
                    )
                    .padding(.top, 40)
                } else {
                    if people.count > 6 {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("ابحث بالاسم", text: $query)
                                .font(TamrinFont.body)
                                .autocorrectionDisabled()
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(TamrinTheme.card, in: .rect(cornerRadius: 18, style: .continuous))
                    }

                    Text("\(selected.count) من \(people.count) · يوصلهم إشعار ويسجّلون بأنفسهم")
                        .font(TamrinFont.font(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)

                    ForEach(filtered) { person in
                        PersonCard(person: person, isSelected: selected.contains(person.id)) {
                            if selected.contains(person.id) {
                                selected.remove(person.id)
                            } else {
                                selected.insert(person.id)
                            }
                            Haptics.selection()
                        }
                    }

                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .bottom) {
            TamrinActionButton(title: actionTitle, isLoading: isSaving) {
                confirm(PlayerPick(sourceGroup: sourceGroup, selected: selected))
            }
            .disabled(!canConfirm)
            .padding(.horizontal, 22)
            .padding(.bottom, 10)
        }
        .toolbar(.hidden, for: .navigationBar)
        .containerBackground(.clear, for: .navigation)
    }
}

/// One person: tap to tick, the same card the earlier steps use.
private struct PersonCard: View {
    let person: PickPerson
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                MemberAvatar(name: person.name, size: 40, imageUrl: person.avatarUrl)
                    .accessibilityHidden(true)
                Text(person.name)
                    .font(TamrinFont.font(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TamrinTheme.card, in: .rect(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
            }
            .contentShape(.rect(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(SpringCardPressStyle())
        .accessibilityLabel(person.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    return PickPlayersStep(sources: sources, isSaving: false, path: .constant(NavigationPath())) { _ in }
        .environment(\.layoutDirection, .rightToLeft)
}
