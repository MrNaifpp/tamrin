//
//  FeatureFeedback.swift
//  Sirr
//
//  Asking what someone thought of a feature, right after they finished using
//  it — while it is still fresh, and without leaving the screen they were on.
//
//  The answer stays on the device for now. Collecting it centrally wants a
//  table and an RPC of its own; nothing here assumes local storage is the only
//  backing, since every caller goes through `FeatureFeedbackStore`.
//

import SwiftUI

// MARK: - Features

/// A feature that can be asked about. One case per thing worth a verdict, so a
/// rating is always attached to something nameable rather than to "the app".
enum TamrinFeature: String, CaseIterable, Identifiable {
    case lineup

    var id: String { rawValue }

    /// The name the sheet puts the question to.
    var title: String {
        switch self {
        case .lineup: return "التشكيلة"
        }
    }

    /// What the person just did, so the question names the thing they finished
    /// rather than asking about a menu item in the abstract.
    var prompt: String {
        switch self {
        case .lineup: return "قسّمت الفريقين. كيف كانت التجربة؟"
        }
    }
}

// MARK: - Storage

struct FeatureFeedback: Codable, Equatable {
    /// One to five.
    var stars: Int
    var note: String
    var submittedAt: Date
}

enum FeatureFeedbackStore {
    /// How long to leave someone alone after showing them the question and
    /// getting nothing back. Long enough not to nag, short enough that a
    /// dismissal by accident does not cost the answer forever.
    private static let quietPeriod: TimeInterval = 3 * 24 * 60 * 60

    private static func answerKey(_ feature: TamrinFeature) -> String {
        "feature.feedback.\(feature.rawValue)"
    }

    private static func askedKey(_ feature: TamrinFeature) -> String {
        "feature.feedback.asked.\(feature.rawValue)"
    }

    static func feedback(for feature: TamrinFeature) -> FeatureFeedback? {
        guard let data = UserDefaults.standard.data(forKey: answerKey(feature)) else { return nil }
        return try? JSONDecoder().decode(FeatureFeedback.self, from: data)
    }

    static func save(_ feedback: FeatureFeedback, for feature: TamrinFeature) {
        guard let data = try? JSONEncoder().encode(feedback) else { return }
        UserDefaults.standard.set(data, forKey: answerKey(feature))
    }

    /// Called when the sheet goes up, answered or not.
    static func markAsked(_ feature: TamrinFeature, at date: Date = .now) {
        UserDefaults.standard.set(date, forKey: askedKey(feature))
    }

    /// Whether to put the question now: never twice for an answered feature,
    /// and not again straight after an unanswered one.
    static func shouldAsk(about feature: TamrinFeature, now: Date = .now) -> Bool {
        guard feedback(for: feature) == nil else { return false }
        guard let asked = UserDefaults.standard.object(forKey: askedKey(feature)) as? Date else {
            return true
        }
        return now.timeIntervalSince(asked) > quietPeriod
    }
}

// MARK: - Sheet

/// Five stars and a line of notes. Deliberately the smallest thing that can
/// carry an opinion: anything longer and it stops being answered at all.
struct FeatureFeedbackSheet: View {
    let feature: TamrinFeature

    @Environment(\.dismiss) private var dismiss
    @State private var stars = 0
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    private let maximumNoteLength = 300

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                starRow

                VStack(alignment: .leading, spacing: 10) {
                    Text("ملاحظاتك")
                        .font(TamrinFont.font(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    // The field is the white surface; the sheet under it stays
                    // off-white. Rounded rather than a capsule because it grows
                    // to a few lines, and a capsule's ends bow out as it does.
                    TextField("وش اللي عجبك، ووش اللي ينفع يتحسّن؟", text: $note, axis: .vertical)
                        .font(TamrinFont.body)
                        .lineLimit(2...5)
                        .focused($noteFocused)
                        .onChange(of: note) { _, newValue in
                            guard newValue.count > maximumNoteLength else { return }
                            note = String(newValue.prefix(maximumNoteLength))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(TamrinTheme.card, in: .rect(cornerRadius: 24, style: .continuous))
                }

                Text("ملاحظاتك تبقى على جهازك، وتساعدنا نطوّر الميزة.")
                    .font(TamrinFont.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheetContentHeight()
            .frame(maxHeight: .infinity, alignment: .top)
            .background(TamrinTheme.sheet)
            .sheetTitle("قيّم \(feature.title)", subtitle: feature.prompt)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("لاحقًا", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("أرسل", action: submit)
                        .fontWeight(.semibold)
                        .disabled(stars == 0)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .fittedSheet(minHeight: 260, includesNavigationBar: true)
        .onAppear { FeatureFeedbackStore.markAsked(feature) }
    }

    private var starRow: some View {
        HStack(spacing: 10) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    Haptics.selection()
                    withAnimation(.snappy(duration: 0.22)) {
                        // Tapping the star you already chose clears it, so a
                        // misfire is undoable without leaving the sheet.
                        stars = stars == value ? 0 : value
                    }
                } label: {
                    Image(systemName: value <= stars ? "star.fill" : "star")
                        .font(.system(size: 30))
                        .foregroundStyle(value <= stars ? TamrinTheme.lime : Color.secondary.opacity(0.4))
                        .frame(maxWidth: .infinity, minHeight: TamrinControlMetrics.touchTarget)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value.formatted(.number.locale(.tamrin)))")
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("تقييم \(feature.title)")
        .accessibilityValue(stars == 0 ? "بلا تقييم" : "\(stars) من 5")
    }

    private func submit() {
        guard stars > 0 else { return }
        FeatureFeedbackStore.save(
            FeatureFeedback(stars: stars, note: trimmedNote, submittedAt: .now),
            for: feature
        )
        Haptics.success()
        dismiss()
    }
}

#Preview("تقييم ميزة") {
    Color.black
        .sheet(isPresented: .constant(true)) {
            FeatureFeedbackSheet(feature: .lineup)
        }
}
