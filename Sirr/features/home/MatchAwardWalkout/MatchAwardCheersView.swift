import SwiftUI

/// Under the landed card, two quiet rows: who has cheered (tap for the list),
/// and your own emoji and note. One cheer per person, WhatsApp-style: tapping
/// your emoji again takes it back.
struct MatchAwardCheersView: View {
    let award: MatchAward
    let model: MatchAwardModel
    @State private var composing = false
    @State private var showsList = false

    private var cheers: [MatchAwardCheer] { award.cheers ?? [] }
    private var latestNote: MatchAwardCheer? { cheers.first { $0.note != nil } }
    private var topEmoji: [String] {
        Dictionary(grouping: cheers.compactMap(\.emoji), by: { $0 })
            .sorted { $0.value.count > $1.value.count }
            .prefix(3).map(\.key)
    }

    var body: some View {
        VStack(spacing: 12) {
            if !cheers.isEmpty { summary }
            if award.canCheer == true { reactionBar }
        }
        .foregroundStyle(.white)
        .environment(\.layoutDirection, .tamrin)
        .sheet(isPresented: $showsList) {
            MatchAwardCheersList(cheers: cheers)
        }
        .sheet(isPresented: $composing) {
            LineupThoughtComposer(
                existing: award.myCheer?.note,
                title: String(localized: "تهنئتك"),
                placeholder: String(localized: "قل له كلمة"),
                deleteTitle: String(localized: "حذف تهنئتي"),
                suggestions: [
                    String(localized: "استاهلها 🐐"),
                    String(localized: "ليلتك والله 🔥"),
                    String(localized: "كفو يا بطل 👏"),
                    String(localized: "المرة الجاية دوري 😤"),
                ]
            ) { note in
                await model.cheer(emoji: award.myCheer?.emoji, note: note)
                return model.error
            }
        }
    }

    private var summary: some View {
        Button { showsList = true } label: {
            HStack(spacing: 10) {
                HStack(spacing: -8) {
                    ForEach(cheers.prefix(3)) { cheer in
                        MemberAvatar(name: cheer.name, size: 26, imageUrl: cheer.avatarURL)
                            .overlay(Circle().stroke(Color(white: 0.035), lineWidth: 2))
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    if let latestNote, let note = latestNote.note {
                        Text("\(latestNote.name.split(separator: " ").first.map(String.init) ?? latestNote.name): \(note)")
                            .font(TamrinFont.font(size: 13, weight: .medium))
                            .lineLimit(1)
                    }
                    Text("\(topEmoji.joined())  التهاني · \(cheers.count.tamrinNumber)")
                        .font(TamrinFont.font(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .accessibilityLabel("\(cheers.count.tamrinNumber) تهنئة")
        .accessibilityHint("يعرض كل التهاني")
    }

    private var reactionBar: some View {
        HStack(spacing: 4) {
            ForEach(MatchAwardCheer.emoji, id: \.self) { emoji in
                let mine = award.myCheer?.emoji == emoji
                Button {
                    Task { await model.cheer(emoji: mine ? nil : emoji, note: award.myCheer?.note) }
                } label: {
                    Text(emoji)
                        .font(.system(size: 24))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(mine ? Color.white.opacity(0.18) : .clear, in: .circle)
                        .scaleEffect(mine ? 1.1 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(emoji)
                .accessibilityAddTraits(mine ? .isSelected : [])
            }
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 24)
            Button { composing = true } label: {
                Image(systemName: award.myCheer?.note == nil ? "square.and.pencil" : "pencil.line")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(award.myCheer?.note == nil ? "اكتب تهنئة" : "عدّل تهنئتك")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .animation(.snappy(duration: 0.2), value: award.myCheer?.emoji)
        .disabled(model.isSaving)
    }
}

/// Every cheer: who, their emoji, their note.
private struct MatchAwardCheersList: View {
    let cheers: [MatchAwardCheer]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(cheers) { cheer in
                        HStack(spacing: 12) {
                            MemberAvatar(name: cheer.name, size: 40, imageUrl: cheer.avatarURL)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cheer.name).font(TamrinFont.font(size: 15, weight: .bold))
                                if let note = cheer.note {
                                    Text(note).font(TamrinFont.font(size: 14, weight: .regular))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if let emoji = cheer.emoji { Text(emoji).font(.system(size: 24)) }
                        }
                        .padding(14)
                        .background(TamrinTheme.card, in: .rect(cornerRadius: 20, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(TamrinTheme.sheet)
            .sheetTitle(String(localized: "التهاني"), subtitle: String(localized: "\(cheers.count.tamrinNumber) من الفريق"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .environment(\.layoutDirection, .tamrin)
        .presentationDetents([.medium, .large])
    }
}
