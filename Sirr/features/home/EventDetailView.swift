import SwiftUI

/// Event detail page — the designer's OccurrenceDetailView (member view) bound
/// to MockHomeFeed. Register/withdraw are local in-memory mutations; payment is
/// a deferred placeholder; the admin section and edit/cancel menu are omitted.
struct EventDetailView: View {
    @Bindable var feed: MockHomeFeed
    let occurrence: FeedOccurrence
    var artName: String = "ExerciseArt1"
    var onClose: () -> Void = {}

    private var roster: [FeedMember] { feed.roster(for: occurrence) }
    private var myRegistration: FeedMember? { feed.myRegistration(for: occurrence) }
    private var confirmedCount: Int { feed.registeredCount(for: occurrence) }
    private var waitingCount: Int { feed.waitlistCount(for: occurrence) }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                ZStack {
                    Image(artName)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    Image(artName)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                        .blur(radius: 26, opaque: true)
                        .mask {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.33),
                                .init(color: .black, location: 0.46),
                                .init(color: .black, location: 1)
                            ], startPoint: .top, endPoint: .bottom)
                        }
                }
            }
            .ignoresSafeArea()

            LinearGradient(stops: [
                .init(color: .black.opacity(0.32), location: 0),
                .init(color: .black.opacity(0.06), location: 0.26),
                .init(color: .black.opacity(0.30), location: 0.55),
                .init(color: .black.opacity(0.58), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    heroTitle
                        .padding(.top, 264)
                        .padding(.bottom, 6)

                    if !occurrence.isCancelled { participationCTA }

                    progressPanel

                    Text("القائمة")
                        .font(TamrinFont.font(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.top, 8)
                        .padding(.horizontal, 4)

                    rosterRows
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .overlay(alignment: .topLeading) {
            Button { onClose() } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .accessibilityLabel("إغلاق")
        }
        .environment(\.layoutDirection, .rightToLeft)
        .colorScheme(.dark)
    }

    private var heroTitle: some View {
        VStack(spacing: 7) {
            if occurrence.isCancelled {
                Text("تم إلغاء الموعد")
                    .font(TamrinFont.font(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 6)
                    .background(.red.opacity(0.85), in: .capsule)
            }
            Text(occurrence.title)
                .font(TamrinFont.font(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2).minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
            Text("يوم \(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
                .font(TamrinFont.font(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var participationCTA: some View {
        if let mine = myRegistration {
            Button { feed.withdraw(from: occurrence) } label: {
                HStack(spacing: 10) {
                    Image(systemName: mine.status == .registered ? "checkmark.circle.fill" : "clock.fill")
                        .foregroundStyle(mine.status == .registered ? TamrinTheme.lime : .orange)
                    Text(mine.status == .registered ? "مكانك محفوظ" : "أنت في قائمة الانتظار")
                        .font(TamrinFont.font(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(mine.status == .registered ? "اعتذر" : "انسحب")
                        .font(TamrinFont.font(size: 13, weight: .medium))
                        .foregroundStyle(.red.opacity(0.95))
                }
                .padding(.horizontal, 18).frame(maxWidth: .infinity).frame(height: 52)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityHint("يفتح تأكيد الاعتذار عن التمرين")

            if mine.status == .registered, occurrence.price > 0 {
                Label("الدفع — قريبًا", systemImage: "creditcard")
                    .font(TamrinFont.headline)
                    .foregroundStyle(TamrinTheme.ink.opacity(0.55))
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(.white.opacity(0.5), in: .capsule)
                    .accessibilityLabel("الدفع قريبًا")
            }
        } else {
            let full = confirmedCount >= occurrence.capacity
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                feed.register(for: occurrence)
            } label: {
                Label(full ? "انضم لقائمة الانتظار" : "سجل في التمرين", systemImage: "plus")
                    .font(TamrinFont.font(size: 16, weight: .bold))
                    .foregroundStyle(TamrinTheme.ink)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.white.opacity(0.94)).interactive(), in: .capsule)
        }
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("نسبة إكتمال التمرين")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(confirmedCount.formatted())\\\(occurrence.capacity.formatted())")
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            ProgressView(value: Double(confirmedCount), total: Double(max(occurrence.capacity, 1)))
                .tint(TamrinTheme.lime)
            if waitingCount > 0 {
                Text("\(waitingCount.formatted()) في قائمة الانتظار")
                    .font(TamrinFont.font(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.white.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var rosterRows: some View {
        if roster.isEmpty {
            Text("كن أول المسجلين.")
                .font(TamrinFont.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(.white.opacity(0.1), in: .rect(cornerRadius: 16, style: .continuous))
        } else {
            VStack(spacing: 8) {
                ForEach(roster) { person in
                    HStack(spacing: 12) {
                        MemberAvatar(name: person.name)
                        Text(person.name)
                            .font(TamrinFont.font(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                        if person.status == .waitlisted {
                            Image(systemName: "clock")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.orange)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(TamrinTheme.lime)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(.white.opacity(0.1), in: .rect(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    }
                }
            }
        }
    }
}

private struct MemberAvatar: View {
    let name: String
    var body: some View {
        Circle()
            .fill(.white.opacity(0.28))
            .frame(width: 34, height: 34)
            .overlay {
                Text(String(name.prefix(1)))
                    .font(TamrinFont.font(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    let feed = MockHomeFeed()
    return EventDetailView(feed: feed, occurrence: feed.occurrences[0], artName: "ExerciseArt1")
}
