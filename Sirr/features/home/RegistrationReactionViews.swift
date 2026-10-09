//
//  RegistrationReactionViews.swift
//  Sirr
//
//  The WhatsApp reaction on a registration: hold a name in the list and a row
//  of emoji rises above it, with the fitting one first; the reactions then sit
//  in a small pill on the card's lower edge.
//

import SwiftUI

/// Rises above the held card. When the registration stood out, the reason is
/// named above the emoji and its emoji leads the row.
struct RegistrationReactionBar: View {
    let entry: SeatReactions?
    let mine: String?
    let onPick: (String?) -> Void

    private var offered: [String] { entry?.offeredEmoji ?? SeatReactions.baseEmoji }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let context = entry?.context {
                Text("\(context.emoji) \(context.label)")
                    .font(TamrinFont.font(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 6)
            }

            HStack(spacing: 2) {
                ForEach(Array(offered.enumerated()), id: \.element) { index, emoji in
                    Button {
                        Haptics.selection()
                        onPick(mine == emoji ? nil : emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 28))
                            .frame(width: 46, height: 46)
                            .background {
                                if mine == emoji {
                                    Circle().fill(.white.opacity(0.2))
                                }
                            }
                            .scaleEffect(mine == emoji ? 1.12 : 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(emoji)
                    .accessibilityAddTraits(mine == emoji ? .isSelected : [])
                    .accessibilityHint(index == 0 && entry?.context != nil ? entry?.context?.label ?? "" : "")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            // The page's own Liquid Glass, not a white slab laid over it.
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}

/// The reactions a card has collected, hung on its lower edge.
struct RegistrationReactionPill: View {
    let entry: SeatReactions
    let mine: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                ForEach(entry.topEmoji.prefix(3), id: \.self) { emoji in
                    Text(emoji).font(.system(size: 13))
                }
                if entry.reactions.count > 1 {
                    Text(entry.reactions.count.formatted(.number.locale(.tamrin)))
                        .font(TamrinFont.font(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.leading, 2)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            // Glass like the card it hangs from; your own reaction shows as
            // a faint white wash inside it.
            .background(.white.opacity(mine != nil ? 0.16 : 0), in: .capsule)
            .glassEffect(.regular, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "التفاعلات: \(entry.reactions.count.formatted(.number.locale(.tamrin)))"))
        .accessibilityHint(String(localized: "يعرض من تفاعل"))
    }
}

/// Who answered this registration, and with what.
struct RegistrationReactionsSheet: View {
    let name: String
    let entry: SeatReactions
    let myUserID: UUID?
    let onRemoveMine: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let context = entry.context {
                        Label {
                            Text(context.label)
                        } icon: {
                            Text(context.emoji)
                        }
                        .font(TamrinFont.font(size: 15, weight: .medium))
                        .padding(.horizontal, 4)
                    }

                    VStack(spacing: 0) {
                        ForEach(entry.reactions, id: \.userID) { reaction in
                            let isMine = reaction.userID == myUserID
                            HStack(spacing: 10) {
                                MemberAvatar(
                                    name: reaction.name,
                                    size: 34,
                                    tint: Color.primary.opacity(0.12),
                                    foreground: .primary
                                )
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(isMine ? String(localized: "أنت") : reaction.name)
                                        .font(TamrinFont.font(size: 15, weight: .medium))
                                    if isMine, onRemoveMine != nil {
                                        Text("اضغط للإزالة")
                                            .font(TamrinFont.font(size: 12, weight: .regular))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                Text(reaction.emoji).font(.system(size: 22))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                            .onTapGesture {
                                guard isMine, let onRemoveMine else { return }
                                Haptics.selection()
                                onRemoveMine()
                                dismiss()
                            }
                        }
                    }
                    .background(TamrinTheme.card, in: .rect(cornerRadius: 20, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .background(TamrinTheme.sheet)
            .sheetTitle(String(localized: "تسجيل \(name.firstNameOnly)"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                }
            }
        }
        .environment(\.layoutDirection, .tamrin)
        .presentationDetents([.medium, .large])
        .presentationBackground(TamrinTheme.sheet)
        .presentationDragIndicator(.visible)
    }
}
