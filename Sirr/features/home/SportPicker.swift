//
//  SportPicker.swift
//  Sirr
//
//  Choosing the sport by name — the one way it is chosen.
//
//  The identity step used to offer a wall of sixty figures at 17pt, most of
//  them things nobody books a pitch for, and the sport got picked by whichever
//  glyph looked close enough. What sport this is decides how the exercise reads
//  everywhere else, so it earns a deliberate tap: the group sports people
//  actually play, two big cards to a row, each an icon over the sport's name,
//  with the system's own search above them.
//

import SwiftUI

// MARK: - The sports

/// One sport: what it is called, and the figure SF Symbols draws for it.
///
/// The symbol is the identity — picking a sport is picking the exercise's
/// symbol — so nothing new has to be stored for this to work.
struct Sport: Identifiable, Hashable {
    let symbol: String
    let name: String

    var id: String { symbol }
}

extension Sport {
    /// Sports people organize a shared exercise around, whether that happens on
    /// a court, a pitch, or a route. The list stays deliberately short so the
    /// organizer can recognize the right activity faster than searching through
    /// every figure symbol the system ships.
    ///
    /// Ordered by how likely it is to be the answer, not alphabetically.
    ///
    /// Filtered at runtime against what this OS actually ships: `Image(systemName:)`
    /// draws nothing for a name the system does not know, and a card with a
    /// hole where its icon should be is worse than a missing card.
    static let all: [Sport] = [
        Sport(symbol: "figure.soccer", name: "كرة القدم"),
        Sport(symbol: "figure.basketball", name: "كرة السلة"),
        Sport(symbol: "figure.volleyball", name: "الكرة الطائرة"),
        // SF Symbols has no padel figure. Pickleball's is the same shape of
        // game — a solid paddle, mid-swing — so it stands in, rather than
        // dropping the sport half the courts in the country are booked for.
        Sport(symbol: "figure.pickleball", name: "البادل"),
        Sport(symbol: "figure.tennis", name: "التنس"),
        Sport(symbol: "figure.cricket", name: "الكريكيت"),
        Sport(symbol: "figure.run", name: "الجري"),
        Sport(symbol: "figure.outdoor.cycle", name: "الدراجات")
    ].filter { UIImage(systemName: $0.symbol) != nil }

    /// The sport a symbol stands for, when it stands for one. An exercise
    /// created before this list existed may carry a symbol that is not in it,
    /// so the row leaves its value blank rather than inventing a name.
    static func named(_ symbol: String) -> Sport? {
        all.first { $0.symbol == symbol }
    }
}

// MARK: - The row that opens it

/// The control on the identity step: says which sport is chosen, and opens the
/// sheet that changes it.
struct SportPickerRow: View {
    let symbol: String
    let tint: Color
    let symbolColor: Color
    let action: () -> Void

    private var sport: Sport? { Sport.named(symbol) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(symbolColor)
                    .frame(width: 40, height: 40)
                    .background(tint, in: .circle)

                Text("نوع الرياضة")
                    .font(TamrinFont.font(size: 17, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                if let sport {
                    Text(sport.name)
                        .font(TamrinFont.font(size: 15, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Mirrors itself in RTL, so it always points the way the row
                // is about to take you.
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(TamrinTheme.card, in: .rect(cornerRadius: 26, style: .continuous))
            .contentShape(.rect(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("نوع الرياضة")
        .accessibilityValue(sport?.name ?? "غير محدد")
        .accessibilityHint("يفتح قائمة الرياضات")
    }
}

// MARK: - The sheet

struct SportPickerSheet: View {
    /// The symbol the exercise carries now, so the matching card opens marked.
    let selectedSymbol: String
    let tint: Color
    let symbolColor: Color
    let onPick: (Sport) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var results: [Sport] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Sport.all }
        return Sport.all.filter { $0.name.localizedStandardContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(results) { sport in
                            card(for: sport)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .background(TamrinTheme.sheet)
            // Pinned, because the sheet is raised from a screen whose name
            // field may still be giving up the keyboard: without an anchor the
            // list settled part-way down as the layout shifted under it.
            .defaultScrollAnchor(.top)
            .scrollDismissesKeyboard(.immediately)
            .sheetTitle("نوع الرياضة")
            // Native search: results narrow as the letters land, with no button
            // to press and nothing hand-built to keep in step.
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "ابحث عن رياضة"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء", role: .cancel) { dismiss() }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func card(for sport: Sport) -> some View {
        let isSelected = sport.symbol == selectedSymbol
        return Button {
            Haptics.selection()
            onPick(sport)
            dismiss()
        } label: {
            VStack(spacing: 12) {
                Image(systemName: sport.symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(isSelected ? symbolColor : Color.primary)
                    .frame(height: 40)

                Text(sport.name)
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? symbolColor : Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 132)
            .background(
                isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(TamrinTheme.card),
                in: .rect(cornerRadius: 26, style: .continuous)
            )
            .contentShape(.rect(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sport.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("نوع الرياضة") {
    Color.black
        .sheet(isPresented: .constant(true)) {
            SportPickerSheet(
                selectedSymbol: "figure.soccer",
                tint: TamrinTheme.lime,
                symbolColor: TamrinTheme.ink
            ) { _ in }
        }
}
