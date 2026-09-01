import SwiftUI

/// The small, stable value Home needs in order to paint the archive backdrop.
///
/// `representativeOccurrenceID` is the newest exercise in the month. Its art is
/// resolved once when the archive value is created, so changing the backdrop
/// never has to decode or look up a poster while the person's finger is moving.
struct PastEventsArchiveMonth: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let year: Int
        let month: Int
    }

    let id: ID
    let representativeOccurrenceID: FeedOccurrence.ID
    let artName: String
}

private struct ArchiveMonthFramesKey: PreferenceKey {
    static let defaultValue: [PastEventsArchiveMonth.ID: CGRect] = [:]

    static func reduce(
        value: inout [PastEventsArchiveMonth.ID: CGRect],
        nextValue: () -> [PastEventsArchiveMonth.ID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

/// A compact, chronological archive of exercises.
///
/// The caller owns the page chrome and backdrop. `activeMonth` reports which
/// month's representative artwork should drive that backdrop. A stable line
/// through the viewport decides the active section, so the result is symmetric
/// when scrolling down or back up and does not flicker at a section boundary.
struct PastEventsArchiveView: View {
    typealias ArtResolver = (FeedOccurrence) -> String
    typealias OpenAction = (FeedOccurrence) -> Void
    typealias LoadMoreAction = () async -> Void

    @Binding private var activeMonth: PastEventsArchiveMonth?

    private let months: [ArchiveMonth]
    private let artworkNames: [String]
    private let transitionNamespace: Namespace.ID
    private let canLoadMore: Bool
    private let isLoadingMore: Bool
    private let archiveError: String?
    private let loadMoreError: String?
    private let onRetryArchive: LoadMoreAction
    private let onLoadMore: LoadMoreAction
    private let onOpen: OpenAction

    private static let horizontalMargin: CGFloat = 20
    private static let columnSpacing: CGFloat = 16
    private static let rowSpacing: CGFloat = 16
    private static let sectionSpacing: CGFloat = 44
    private static let cardAspectRatio: CGFloat = 173 / 300
    private static let scrollCoordinateSpace = "past-events-archive-scroll"

    init(
        occurrences: [FeedOccurrence],
        activeMonth: Binding<PastEventsArchiveMonth?>,
        calendar: Calendar = Calendar(identifier: .gregorian),
        now: Date = .now,
        artResolver: @escaping ArtResolver,
        transitionNamespace: Namespace.ID,
        canLoadMore: Bool = false,
        isLoadingMore: Bool = false,
        archiveError: String? = nil,
        loadMoreError: String? = nil,
        onRetryArchive: @escaping LoadMoreAction = {},
        onLoadMore: @escaping LoadMoreAction = {},
        onOpen: @escaping OpenAction
    ) {
        let grouped = Self.makeMonths(
            from: occurrences,
            calendar: calendar,
            now: now,
            artResolver: artResolver
        )

        _activeMonth = activeMonth
        months = grouped
        var seenArtwork: Set<String> = []
        artworkNames = grouped
            .flatMap { $0.items.map(\.artName) }
            .filter { seenArtwork.insert($0).inserted }
        self.transitionNamespace = transitionNamespace
        self.canLoadMore = canLoadMore
        self.isLoadingMore = isLoadingMore
        self.archiveError = archiveError
        self.loadMoreError = loadMoreError
        self.onRetryArchive = onRetryArchive
        self.onLoadMore = onLoadMore
        self.onOpen = onOpen
    }

    var body: some View {
        Group {
            if months.isEmpty {
                emptyScroll
            } else {
                archiveScroll
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .onChange(of: months.map(\.selection), initial: true) { _, selections in
            guard let first = selections.first else {
                activeMonth = nil
                return
            }

            if let activeID = activeMonth?.id,
               let refreshed = selections.first(where: { $0.id == activeID }) {
                if refreshed != activeMonth { activeMonth = refreshed }
            } else {
                activeMonth = first
            }
        }
        // Palette sampling uses a 64px thumbnail, then display-sized sport
        // photos are decoded away from the main actor. LazyVGrid can therefore
        // reveal a new row without doing either job in the scroll frame.
        .task(id: artworkNames) {
            ArtworkPalette.warm(artworkNames)
            let worker = Task.detached(priority: .userInitiated) {
                SportArtLibrary.warmDisplayImages(artworkNames)
                SportArtLibrary.warmBackdropImages(artworkNames)
            }
            await withTaskCancellationHandler(
                operation: { await worker.value },
                onCancel: { worker.cancel() }
            )
        }
    }

    private var archiveScroll: some View {
        GeometryReader { viewport in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: Self.sectionSpacing) {
                    ForEach(months) { month in
                        monthSection(month)
                            .background {
                                GeometryReader { section in
                                    Color.clear.preference(
                                        key: ArchiveMonthFramesKey.self,
                                        value: [
                                            month.id: section.frame(
                                                in: .named(Self.scrollCoordinateSpace)
                                            )
                                        ]
                                    )
                                }
                            }
                    }

                    if archiveError != nil {
                        archiveErrorFooter
                    }

                    if canLoadMore || isLoadingMore || loadMoreError != nil {
                        loadMoreFooter
                    }
                }
                .padding(.horizontal, Self.horizontalMargin)
                .padding(.top, 16)
                .padding(.bottom, 96)
            }
            .coordinateSpace(name: Self.scrollCoordinateSpace)
            .onPreferenceChange(ArchiveMonthFramesKey.self) { frames in
                updateActiveMonth(
                    from: frames,
                    activationY: viewport.size.height * 0.42
                )
            }
        }
    }

    private var archiveErrorFooter: some View {
        VStack(spacing: 10) {
            Text(archiveError ?? "")
                .font(TamrinFont.font(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)

            Button("إعادة المحاولة") {
                Task { await onRetryArchive() }
            }
            .font(TamrinFont.font(size: 13, weight: .bold))
            .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
    }

    /// Keep the successful empty result scrollable so the native pull-to-
    /// refresh gesture still works before the first historical exercise exists.
    private var emptyScroll: some View {
        ScrollView(.vertical) {
            emptyState
                .containerRelativeFrame(.vertical, alignment: .center)
        }
        .scrollIndicators(.hidden)
    }

    private var loadMoreFooter: some View {
        VStack(spacing: 10) {
            if isLoadingMore {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel("نحمّل تمارين أقدم")
            } else if let loadMoreError {
                Text(loadMoreError)
                    .font(TamrinFont.font(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)

                Button("إعادة المحاولة") {
                    Task { await onLoadMore() }
                }
                .font(TamrinFont.font(size: 13, weight: .bold))
                .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        // The item count is the page cursor from the view's perspective. When
        // an appended page moves this footer down, it may naturally ask for
        // another page if the person is already at the new end of the archive.
        .task(id: "\(months.reduce(0) { $0 + $1.items.count })-\(archiveError == nil)") {
            guard canLoadMore,
                  !isLoadingMore,
                  archiveError == nil,
                  loadMoreError == nil else { return }
            await onLoadMore()
        }
    }

    private func monthSection(_ month: ArchiveMonth) -> some View {
        // In the surrounding RTL environment, `leading` is the physical right.
        // Using `trailing` put the month heading on the opposite side even
        // though the grid itself was correctly ordered right-to-left.
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(month.title)
                    .font(TamrinFont.font(size: 27, weight: .bold))
                    .foregroundStyle(.white)

                Text(month.countText)
                    .font(TamrinFont.font(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.56))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 0), spacing: Self.columnSpacing),
                    GridItem(.flexible(minimum: 0), spacing: Self.columnSpacing)
                ],
                alignment: .center,
                spacing: Self.rowSpacing
            ) {
                ForEach(month.items) { item in
                    archiveCard(item)
                }
            }
        }
    }

    private func archiveCard(_ item: ArchiveItem) -> some View {
        PastEventCompactCard(
            occurrence: item.occurrence,
            artName: item.artName,
            compactDate: item.compactDate,
            aspectRatio: Self.cardAspectRatio
        ) {
            onOpen(item.occurrence)
        }
        .matchedTransitionSource(id: item.id, in: transitionNamespace)
    }

    /// The month crossing a stable line in the upper-middle of the viewport
    /// owns the backdrop. Section frames, rather than the first card's
    /// visibility, make this work in both directions and for months containing
    /// more rows than fit on screen.
    private func updateActiveMonth(
        from frames: [PastEventsArchiveMonth.ID: CGRect],
        activationY: CGFloat
    ) {
        guard !frames.isEmpty else { return }

        let selectedID = frames.first(where: { _, frame in
            frame.minY <= activationY && frame.maxY > activationY
        })?.key ?? frames.min(by: { lhs, rhs in
            abs(lhs.value.midY - activationY) < abs(rhs.value.midY - activationY)
        })?.key

        guard let selectedID,
              activeMonth?.id != selectedID,
              let month = months.first(where: { $0.id == selectedID }) else { return }
        activeMonth = month.selection
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))

            Text("ما فيه تمارين ماضية")
                .font(TamrinFont.font(size: 18, weight: .bold))
                .foregroundStyle(.white)

            Text("بعد أول تمرين، بتلقى سجلك هنا")
                .font(TamrinFont.font(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.56))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .combine)
    }
}

private extension PastEventsArchiveView {
    struct ArchiveItem: Identifiable {
        let occurrence: FeedOccurrence
        let artName: String
        let compactDate: String

        var id: FeedOccurrence.ID { occurrence.id }
    }

    struct ArchiveMonth: Identifiable {
        let id: PastEventsArchiveMonth.ID
        let title: String
        let countText: String
        let items: [ArchiveItem]

        var selection: PastEventsArchiveMonth {
            let representative = items[0]
            return PastEventsArchiveMonth(
                id: id,
                representativeOccurrenceID: representative.id,
                artName: representative.artName
            )
        }
    }

    static func makeMonths(
        from occurrences: [FeedOccurrence],
        calendar inputCalendar: Calendar,
        now: Date,
        artResolver: ArtResolver
    ) -> [ArchiveMonth] {
        // Arabic Saudi Arabia otherwise defaults to Umm al-Qura. The archive
        // is explicitly Gregorian, both for grouping and for every label the
        // person sees, while retaining the caller's timezone for month edges.
        let gregorianArabic = Locale(
            identifier: "ar_SA@calendar=gregorian;numbers=latn"
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = gregorianArabic
        calendar.timeZone = inputCalendar.timeZone

        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.locale = gregorianArabic
        monthFormatter.timeZone = calendar.timeZone
        monthFormatter.dateFormat = "LLLL"

        let cardDateFormatter = DateFormatter()
        cardDateFormatter.calendar = calendar
        cardDateFormatter.locale = gregorianArabic
        cardDateFormatter.timeZone = calendar.timeZone
        cardDateFormatter.dateFormat = "EEEE، d MMMM yyyy"

        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.locale = gregorianArabic
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.dateFormat = "h:mm a"

        let currentYear = calendar.component(.year, from: now)
        let sorted = occurrences.sorted {
            if $0.startAt != $1.startAt { return $0.startAt > $1.startAt }
            return $0.id.uuidString < $1.id.uuidString
        }

        var orderedIDs: [PastEventsArchiveMonth.ID] = []
        var itemsByMonth: [PastEventsArchiveMonth.ID: [ArchiveItem]] = [:]

        for occurrence in sorted {
            let components = calendar.dateComponents([.year, .month], from: occurrence.startAt)
            guard let year = components.year, let month = components.month else { continue }

            let id = PastEventsArchiveMonth.ID(year: year, month: month)
            if itemsByMonth[id] == nil { orderedIDs.append(id) }
            itemsByMonth[id, default: []].append(
                ArchiveItem(
                    occurrence: occurrence,
                    artName: artResolver(occurrence),
                    compactDate: "\(cardDateFormatter.string(from: occurrence.startAt))، "
                        + timeFormatter.string(from: occurrence.startAt)
                )
            )
        }

        return orderedIDs.compactMap { id in
            guard let items = itemsByMonth[id], !items.isEmpty else { return nil }
            let monthName = localizedMonthName(
                id.month,
                year: id.year,
                calendar: calendar,
                formatter: monthFormatter
            )
            let title = id.year == currentYear ? monthName : "\(monthName) \(id.year)"
            return ArchiveMonth(
                id: id,
                title: title,
                countText: arabicExerciseCount(items.count),
                items: items
            )
        }
    }

    static func localizedMonthName(
        _ month: Int,
        year: Int,
        calendar: Calendar,
        formatter: DateFormatter
    ) -> String {
        let fallback = calendar.monthSymbols.indices.contains(month - 1)
            ? calendar.monthSymbols[month - 1]
            : ""
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
            return fallback
        }
        return formatter.string(from: date)
    }

    static func arabicExerciseCount(_ count: Int) -> String {
        switch count {
        case 1:
            return "تمرين واحد"
        case 2:
            return "تمرينان"
        case 3...10:
            return "\(count) تمارين"
        default:
            return "\(count) تمرينًا"
        }
    }
}

private struct PastEventCompactCard: View {
    let occurrence: FeedOccurrence
    let artName: String
    let compactDate: String
    let aspectRatio: CGFloat
    let onOpen: () -> Void

    private var tint: Color { ArtworkPalette.averageColor(for: artName) }

    var body: some View {
        Button(action: onOpen) {
            // The clear base owns the grid cell's exact size. Keeping the
            // photograph inside an overlay prevents its intrinsic width from
            // widening a flexible grid column and drawing past the 20pt page
            // margin on compact iPhones.
            Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    ZStack(alignment: .bottom) {
                        Image(exerciseArt: artName)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()

                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.44),
                                .init(color: tint.opacity(0.16), location: 0.58),
                                .init(color: tint.opacity(0.58), location: 0.78),
                                .init(color: tint.opacity(0.90), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )

                        cardDetails
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .clipShape(.rect(cornerRadius: 19, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(tint.opacity(0.66), lineWidth: 0.7)
            }
            .contentShape(.rect(cornerRadius: 19, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(occurrence.title)، \(occurrence.startAt.arabicDay)، "
                + "\(occurrence.startAt.arabicDate)، الساعة \(occurrence.startAt.arabicTime)"
        )
        .accessibilityValue(occurrence.locationName)
        .accessibilityHint("يفتح تفاصيل التمرين")
    }

    private var cardDetails: some View {
        VStack(spacing: 4) {
            if occurrence.isCancelled {
                Text("متخطّى")
                    .font(TamrinFont.font(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(.red.opacity(0.82), in: .capsule)
            }

            Text(occurrence.title)
                .font(TamrinFont.font(size: 21, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.76)

            Text(compactDate)
                .font(TamrinFont.font(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)
                .minimumScaleFactor(0.76)

            if !occurrence.locationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(occurrence.locationName)
                    .font(TamrinFont.font(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.bottom, 15)
        .frame(maxWidth: .infinity)
    }

}
