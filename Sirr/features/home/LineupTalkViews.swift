//
//  LineupTalkViews.swift
//  Sirr
//
//  «خواطر التشكيلة» on screen: the note over a player's name on the pitch, the
//  row of everyone's thoughts with yours first, the verdict on the split, and
//  the two sheets behind them.
//

import SwiftUI

// MARK: - The note

/// A thought drawn the way Instagram draws a note: a small white bubble with
/// a trailing tail, sitting above the person it belongs to.
struct LineupThoughtBubble: View {
    let text: String
    var topReaction: String?
    var compact = false
    var isPlaceholder = false

    var body: some View {
        VStack(alignment: .center, spacing: 1) {
            HStack(spacing: 3) {
                Text(text)
                    .lineLimit(compact ? 1 : 2)
                    .multilineTextAlignment(.center)
                if let topReaction {
                    Text(topReaction)
                        .font(.system(size: compact ? 8 : 10))
                }
            }
            .font(TamrinFont.font(size: compact ? 9 : 11, weight: .medium))
            .foregroundStyle(isPlaceholder ? Color.black.opacity(0.45) : .black)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 3 : 5)
            .background(.white.opacity(isPlaceholder ? 0.7 : 0.95),
                        in: .rect(cornerRadius: compact ? 9 : 12, style: .continuous))

            // The two-dot tail that says "thinking", not "speaking".
            HStack(spacing: 0) {
                Circle()
                    .fill(.white.opacity(isPlaceholder ? 0.7 : 0.95))
                    .frame(width: compact ? 4 : 5, height: compact ? 4 : 5)
                Spacer(minLength: 0)
            }
            .padding(.leading, compact ? 8 : 12)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: compact ? 78 : 100)
        .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
    }
}

extension View {
    /// Hangs a player's thought above him without moving him: the bubble sits
    /// on the node's top edge and takes no room in the pitch's layout.
    @ViewBuilder
    func lineupThought(_ thought: LineupThought?, compact: Bool, onTap: ((LineupThought) -> Void)?) -> some View {
        if let thought {
            overlay(alignment: .top) {
                let bubble = LineupThoughtBubble(
                    text: thought.body,
                    topReaction: thought.reactionSummary.first?.emoji,
                    compact: true
                )
                Group {
                    if let onTap {
                        Button { onTap(thought) } label: { bubble }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "خاطرة \(thought.name): \(thought.body)"))
                    } else {
                        bubble.accessibilityHidden(true)
                    }
                }
                .alignmentGuide(VerticalAlignment.top) { $0[.bottom] - (compact ? 2 : 4) }
            }
        } else {
            self
        }
    }
}

// MARK: - The section on the lineup page

/// Everyone's thoughts in one row, yours first, then the verdict on the split.
struct LineupTalkSection: View {
    let talk: LineupTalk
    let myUserID: UUID?
    let myName: String
    var myAvatarData: Data?
    var myAvatarUrl: String?
    let canWrite: Bool
    let isOwner: Bool
    let onCompose: () -> Void
    let onOpenThought: (LineupThought) -> Void
    let onVerdict: (LineupVerdict?) -> Void

    private var others: [LineupThought] { talk.thoughts.filter { $0.userID != myUserID } }
    private var mine: LineupThought? { talk.thought(by: myUserID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if talk.isOpen, canWrite || !talk.thoughts.isEmpty {
                Text("الخواطر")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 4)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 14) {
                        if canWrite {
                            note(
                                name: String(localized: "خاطرتك"),
                                avatarName: myName,
                                avatarData: myAvatarData,
                                avatarUrl: myAvatarUrl,
                                text: mine?.body ?? String(localized: "اكتب خاطرتك"),
                                reaction: mine?.reactionSummary.first?.emoji,
                                isPlaceholder: mine == nil,
                                showsPlus: mine == nil
                            ) {
                                if let mine { onOpenThought(mine) } else { onCompose() }
                            }
                        }
                        ForEach(others) { thought in
                            note(
                                name: thought.name.firstNameOnly,
                                avatarName: thought.name,
                                text: thought.body,
                                reaction: thought.reactionSummary.first?.emoji,
                                isPlaceholder: false,
                                showsPlus: false
                            ) { onOpenThought(thought) }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }
                .scrollClipDisabled()
            }

            LineupVerdictBar(talk: talk, isOwner: isOwner, isEnabled: canWrite && talk.isOpen, onSelect: onVerdict)
        }
    }

    private func note(
        name: String,
        avatarName: String,
        avatarData: Data? = nil,
        avatarUrl: String? = nil,
        text: String,
        reaction: String?,
        isPlaceholder: Bool,
        showsPlus: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                LineupThoughtBubble(text: text, topReaction: reaction, isPlaceholder: isPlaceholder)
                ZStack(alignment: .bottomTrailing) {
                    MemberAvatar(name: avatarName, size: 54, imageData: avatarData, imageUrl: avatarUrl)
                    if showsPlus {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, TamrinTheme.success)
                            .background(Circle().fill(.black).padding(2))
                    }
                }
                Text(name)
                    .font(TamrinFont.font(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .frame(width: 92)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPlaceholder ? text : String(localized: "خاطرة \(name): \(text)"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Verdict

/// What everyone makes of the split. The organizer also gets the reading of
/// the room in one line, the number he actually wants before kick-off.
struct LineupVerdictBar: View {
    let talk: LineupTalk
    let isOwner: Bool
    let isEnabled: Bool
    let onSelect: (LineupVerdict?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("رأيك في التشكيلة")
                .font(TamrinFont.font(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 4)

            HStack(spacing: 8) {
                ForEach(LineupVerdict.allCases) { verdict in
                    chip(verdict)
                }
            }

            if isOwner {
                Text(summary)
                    .font(TamrinFont.font(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 4)
                    .contentTransition(.numericText())
            }
        }
    }

    private var summary: String {
        guard talk.verdictTotal > 0 else { return String(localized: "ما أحد قال رأيه بعد") }
        guard let lead = talk.leadingVerdict else { return String(localized: "الآراء متقاربة") }
        let count = lead.count.formatted(.number.locale(.tamrin))
        let total = talk.verdictTotal.formatted(.number.locale(.tamrin))
        return String(localized: "\(count) من \(total) شافوها \(lead.verdict.title)")
    }

    private func chip(_ verdict: LineupVerdict) -> some View {
        let selected = talk.myVerdict == verdict
        let count = talk.verdicts[verdict] ?? 0
        return Button {
            Haptics.selection()
            onSelect(selected ? nil : verdict)
        } label: {
            VStack(spacing: 2) {
                Text(verdict.emoji).font(.system(size: 20))
                Text(verdict.title)
                    .font(TamrinFont.font(size: 13, weight: .bold))
                Text(count.formatted(.number.locale(.tamrin)))
                    .font(TamrinFont.font(size: 12, weight: .medium))
                    .opacity(0.6)
                    .contentTransition(.numericText())
            }
            .foregroundStyle(selected ? Color.black : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.1))
                }
            }
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .animation(.snappy(duration: 0.22), value: selected)
        .accessibilityLabel("\(verdict.title)، \(count.formatted(.number.locale(.tamrin)))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Writing a thought

struct LineupThoughtComposer: View {
    let existing: String?
    /// Nil on success, or what to tell the person.
    let onSave: @MainActor (String?) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private let suggestions = [
        String(localized: "فريقنا أقوى 😤"),
        String(localized: "جاهز 💪"),
        String(localized: "أبي أكون حارس 🧤"),
        String(localized: "الدفاع جدار 🧱"),
        String(localized: "الليلة لنا 🔥")
    ]

    init(existing: String?, onSave: @escaping @MainActor (String?) async -> String?) {
        self.existing = existing
        self.onSave = onSave
        _text = State(initialValue: existing ?? "")
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField("وش في بالك عن التشكيلة؟", text: $text)
                        .font(TamrinFont.headline)
                        .focused($focused)
                        .submitLabel(.done)
                        .disabled(isSaving)
                        .onSubmit { save(trimmed) }
                        .onChange(of: text) { _, newValue in
                            guard newValue.count > LineupTalk.maximumLength else { return }
                            text = String(newValue.prefix(LineupTalk.maximumLength))
                        }
                    Text("\(text.count.formatted(.number.locale(.tamrin)))/\(LineupTalk.maximumLength.formatted(.number.locale(.tamrin)))")
                        .font(TamrinFont.font(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 15)
                .background(TamrinTheme.card, in: .capsule)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                Haptics.selection()
                                text = suggestion
                            } label: {
                                Text(suggestion)
                                    .font(TamrinFont.font(size: 14, weight: .medium))
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 36)
                                    .background(TamrinTheme.card, in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollClipDisabled()

                if existing != nil {
                    Button(role: .destructive) {
                        save(nil)
                    } label: {
                        Label("حذف خاطرتي", systemImage: "trash")
                            .font(TamrinFont.font(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .disabled(isSaving)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(TamrinFont.footnote)
                        .foregroundStyle(.red)
                        .transition(.blurReplace)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheetContentHeight()
            .frame(maxHeight: .infinity, alignment: .top)
            .background(TamrinTheme.sheet)
            .sheetTitle(String(localized: "خاطرتك"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء", role: .cancel) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("نشر") { save(trimmed) }
                        .fontWeight(.semibold)
                        .disabled(isSaving || trimmed.isEmpty || trimmed == existing)
                }
            }
            .animation(.smooth(duration: 0.25), value: errorMessage)
        }
        .environment(\.layoutDirection, .tamrin)
        .fittedSheet(minHeight: 200, includesNavigationBar: true)
        .interactiveDismissDisabled(isSaving)
        .onAppear { focused = true }
    }

    private func save(_ value: String?) {
        guard !isSaving else { return }
        if let value, value.isEmpty { return }
        isSaving = true
        errorMessage = nil
        Task {
            let failure = await onSave(value)
            isSaving = false
            if let failure {
                Haptics.error()
                errorMessage = failure
            } else {
                Haptics.success()
                dismiss()
            }
        }
    }
}

// MARK: - One thought, opened

/// The WhatsApp long-press view for a thought: the emoji row above the
/// enlarged note, then who reacted, then the replies and a line to add one.
struct LineupThoughtSheet: View {
    let feed: HomeStore
    let occurrence: FeedOccurrence
    let authorID: UUID
    let onEdit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reply = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var replyFocused: Bool

    private var talk: LineupTalk? { feed.lineupTalk(for: occurrence) }
    private var thought: LineupThought? { talk?.thought(by: authorID) }
    private var me: UUID? { feed.currentUserID }
    private var isMine: Bool { authorID == me }
    private var canWrite: Bool { (talk?.isOpen ?? false) && feed.canJoinLineupTalk(for: occurrence) }

    var body: some View {
        NavigationStack {
            Group {
                if let thought {
                    content(thought)
                } else {
                    ContentUnavailableView("انحذفت الخاطرة", systemImage: "bubble.left")
                }
            }
            .background(TamrinTheme.sheet)
            .sheetTitle(thought.map { isMine ? String(localized: "خاطرتك") : $0.name } ?? "")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                }
                if isMine, canWrite {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("تعديل") {
                            dismiss()
                            onEdit()
                        }
                    }
                }
            }
        }
        .environment(\.layoutDirection, .tamrin)
        .presentationDetents([.medium, .large])
        .presentationBackground(TamrinTheme.sheet)
        .presentationDragIndicator(.visible)
    }

    private func content(_ thought: LineupThought) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if canWrite { reactionStrip(thought) }

                VStack(alignment: .leading, spacing: 6) {
                    Text(thought.body)
                        .font(TamrinFont.font(size: 20, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(thought.updatedAt, format: .relative(presentation: .named))
                        .font(TamrinFont.font(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .environment(\.locale, .tamrin)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TamrinTheme.card, in: .rect(cornerRadius: 22, style: .continuous))

                if !thought.reactions.isEmpty {
                    section(String(localized: "التفاعلات")) {
                        ForEach(thought.reactions, id: \.userID) { reaction in
                            row(name: reaction.userID == me ? String(localized: "أنت") : reaction.name) {
                                Text(reaction.emoji).font(.system(size: 20))
                            }
                        }
                    }
                }

                if !thought.replies.isEmpty {
                    section(String(localized: "الردود")) {
                        ForEach(thought.replies) { reply in
                            replyRow(reply)
                        }
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(TamrinFont.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .bottom) {
            if canWrite { replyField }
        }
        .animation(.snappy(duration: 0.22), value: thought)
    }

    private func reactionStrip(_ thought: LineupThought) -> some View {
        let mine = thought.reaction(by: me)
        return HStack(spacing: 4) {
            ForEach(LineupTalk.reactionEmoji, id: \.self) { emoji in
                Button {
                    Haptics.selection()
                    react(mine == emoji ? nil : emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 26))
                        .frame(width: 46, height: 46)
                        .background {
                            if mine == emoji {
                                Circle().fill(Color.primary.opacity(0.12))
                            }
                        }
                        .scaleEffect(mine == emoji ? 1.12 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(emoji)
                .accessibilityAddTraits(mine == emoji ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(TamrinTheme.card, in: .capsule)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TamrinFont.font(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) { content() }
                .background(TamrinTheme.card, in: .rect(cornerRadius: 20, style: .continuous))
        }
    }

    private func row<Trailing: View>(name: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            MemberAvatar(name: name, size: 32, tint: Color.primary.opacity(0.12), foreground: .primary)
            Text(name)
                .font(TamrinFont.font(size: 15, weight: .medium))
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func replyRow(_ reply: LineupThoughtReply) -> some View {
        let canDelete = reply.userID == me || isMine
        return HStack(alignment: .top, spacing: 10) {
            MemberAvatar(name: reply.name, size: 32, tint: Color.primary.opacity(0.12), foreground: .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(reply.userID == me ? String(localized: "أنت") : reply.name)
                    .font(TamrinFont.font(size: 13, weight: .bold))
                Text(reply.body)
                    .font(TamrinFont.font(size: 15, weight: .regular))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .contextMenu {
            if canDelete {
                Button("حذف الرد", systemImage: "trash", role: .destructive) {
                    Task {
                        errorMessage = await feed.deleteLineupReply(reply.id, for: occurrence)
                    }
                }
            }
        }
    }

    private var replyField: some View {
        HStack(spacing: 10) {
            TextField("رد…", text: $reply)
                .font(TamrinFont.body)
                .focused($replyFocused)
                .submitLabel(.send)
                .onSubmit(sendReply)
                .onChange(of: reply) { _, newValue in
                    guard newValue.count > LineupTalk.maximumLength else { return }
                    reply = String(newValue.prefix(LineupTalk.maximumLength))
                }
            Button(action: sendReply) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isSending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("إرسال الرد")
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(TamrinTheme.card, in: .capsule)
        .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        // The rows scroll under the field, never through it.
        .background(TamrinTheme.sheet)
    }

    private func react(_ emoji: String?) {
        Task {
            errorMessage = await feed.reactToLineupThought(emoji, authorID: authorID, for: occurrence)
            if errorMessage != nil { Haptics.error() }
        }
    }

    private func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        Task {
            let failure = await feed.replyToLineupThought(text, authorID: authorID, for: occurrence)
            isSending = false
            if let failure {
                Haptics.error()
                errorMessage = failure
            } else {
                Haptics.success()
                errorMessage = nil
                reply = ""
            }
        }
    }
}
