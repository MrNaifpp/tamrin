import SwiftUI

/// Poster-style event card — the designer's ExercisePosterCard bound to the
/// mock FeedOccurrence. Admin publish/edit/cancel affordances are intentionally
/// omitted this increment (member view only).
struct EventPosterCard: View {
    let occurrence: FeedOccurrence
    let registeredCount: Int
    let action: () -> Void

    private var artName: String { "ExerciseArt\((occurrence.artIndex % 3) + 1)" }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                Color.clear
                    .overlay {
                        Image(artName)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }

                VStack(spacing: 7) {
                    if occurrence.isCancelled {
                        Text("ملغي")
                            .font(TamrinFont.font(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 13).padding(.vertical, 6)
                            .background(.red.opacity(0.85), in: .capsule)
                    } else if occurrence.isRecurring {
                        Label("أسبوعيًا", systemImage: "repeat")
                            .font(TamrinFont.font(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.white.opacity(0.18), in: .capsule)
                    }

                    Text(occurrence.title)
                        .font(TamrinFont.font(size: 27, weight: .bold))
                        .lineLimit(1).minimumScaleFactor(0.7)

                    Text("\(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
                        .font(TamrinFont.font(size: 15, weight: .medium))
                        .opacity(0.82)

                    Text("\(occurrence.locationName) · \(registeredCount)/\(occurrence.capacity) · \(occurrence.price == 0 ? "مجاني" : "\(occurrence.price.cleanAmount) ﷼")")
                        .font(TamrinFont.font(size: 12, weight: .regular))
                        .opacity(0.68).lineLimit(1)
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24).padding(.top, 72).padding(.bottom, 56)
                .frame(maxWidth: .infinity)
                .background {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        LinearGradient(colors: [.black.opacity(0), .black.opacity(0.10)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.55), location: 0.5),
                            .init(color: .black, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                }
                .colorScheme(.dark)
            }
            .clipShape(.rect(cornerRadius: 36, style: .continuous))
            .contentShape(.rect(cornerRadius: 36, style: .continuous))
        }
        .buttonStyle(SpringCardPressStyle())
        .accessibilityLabel("\(occurrence.title)، \(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
        .accessibilityHint("يفتح تفاصيل الموعد")
    }
}

struct EmptyScheduleCard: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.7))
            Text("ما فيه مواعيد قادمة")
                .font(TamrinFont.headline)
                .foregroundStyle(.white)
            Text("المواعيد الجديدة بتظهر هنا أول ما تُنشر.")
                .font(TamrinFont.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 32, style: .continuous))
    }
}

#Preview {
    let occ = FeedOccurrence(id: UUID(), title: "كورة الثلاثاء", startAt: Date(),
                             locationName: "ملعب النخيل", capacity: 14,
                             price: 25, isCancelled: false, artIndex: 0)
    return EventPosterCard(occurrence: occ, registeredCount: 9, action: {})
        .frame(height: 420).padding()
        .environment(\.layoutDirection, .rightToLeft)
}
