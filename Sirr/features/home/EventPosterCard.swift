import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit


/// Poster-style event card. The poster is the whole control: it opens the
/// exercise, and every action on that exercise lives on the page it opens.
/// The shelf stays as quiet as the reference, and nothing is drawn here that
/// a finger could reach for and miss.
struct EventPosterCard: View {
    let occurrence: FeedOccurrence
    let registeredCount: Int
    let showsSupervisorTag: Bool
    let profileName: String
    let profileImageData: Data?
    let profileImageUrl: String?
    /// Everyone holding a seat, in the order they took one. The poster shows
    /// the first nine.
    let attendees: [FeedMember]
    /// So the signed-in person's own photo can come from memory, ahead of the
    /// upload that gives it a URL.
    let currentUserID: UUID?
    /// The photo Home picked from the sport's folder. Nil keeps the card on the
    /// artwork the app ships with.
    let art: String?
    let action: () -> Void

    init(
        occurrence: FeedOccurrence,
        registeredCount: Int,
        showsSupervisorTag: Bool = false,
        profileName: String = "",
        profileImageData: Data? = nil,
        profileImageUrl: String? = nil,
        attendees: [FeedMember] = [],
        currentUserID: UUID? = nil,
        art: String? = nil,
        action: @escaping () -> Void
    ) {
        self.occurrence = occurrence
        self.registeredCount = registeredCount
        self.showsSupervisorTag = showsSupervisorTag
        self.profileName = profileName
        self.profileImageData = profileImageData
        self.profileImageUrl = profileImageUrl
        self.attendees = attendees
        self.currentUserID = currentUserID
        self.art = art
        self.action = action
    }

    /// Set by Home, which knows the exercise's sport. The fallback keeps every
    /// other caller (previews, and any card shown before a sport is known) on
    /// the artwork the app ships with.
    private var artName: String {
        art ?? "ExerciseArt\((occurrence.artIndex % 3) + 1)"
    }
    private var posterTint: Color { ArtworkPalette.averageColor(for: artName) }

    var body: some View {
        Button(action: action) {
            posterContent
        }
        // A spring press style starts shrinking as soon as a finger touches the
        // poster, then springs back when the gesture becomes a scroll. Keeping
        // the card plain lets ScrollView own the pan without a competing scale.
        .buttonStyle(.plain)
        .accessibilityLabel("\(occurrence.title)، \(occurrence.startAt.arabicDay)، الساعة \(occurrence.startAt.arabicTime)")
        .accessibilityValue("\(registeredCount) من \(occurrence.capacity) مسجلين")
        .accessibilityHint("يفتح تفاصيل الموعد")
        .clipShape(.rect(cornerRadius: 36, style: .continuous))
        // The reference uses a wide, barely-there elevation shadow. Cast it
        // from one simple shape behind the opaque poster instead of shadowing
        // the card's image, progressive blur, avatars and text separately.
        .background {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(.black)
                .shadow(
                    color: .black.opacity(0.06),
                    radius: 20,
                    x: 0,
                    y: 8
                )
        }
        // In the surrounding RTL environment, trailing is the physical left.
        // This restores the original Tamrin tag position and proportions.
        .overlay(alignment: .topTrailing) {
            if showsSupervisorTag {
                EventSupervisorTagView(artName: artName)
                    .padding(.top, 20)
                    .padding(.trailing, 20)
            }
        }
        .contentShape(.rect(cornerRadius: 36, style: .continuous))
    }

    private var posterContent: some View {
        ZStack(alignment: .bottom) {
            posterArtwork

            // SwiftUI has no public variable-blur API. Blending a 6pt-blurred
            // copy through a progressive alpha mask gives the same 0...6pt
            // visual ramp while remaining App Store-safe.
            posterArtwork
                .blur(radius: 6, opaque: true)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.46),
                        .init(color: .black.opacity(0.12), location: 0.58),
                        .init(color: .black.opacity(0.52), location: 0.76),
                        .init(color: .black, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }

            // The tint is the actual average of the artwork, not a palette
            // guessed from its index. It grows from 0% to 85% at the bottom.
            LinearGradient(stops: [
                .init(color: .clear, location: 0.45),
                .init(color: posterTint.opacity(0.18), location: 0.62),
                .init(color: posterTint.opacity(0.50), location: 0.80),
                .init(color: posterTint.opacity(0.85), location: 1)
            ], startPoint: .top, endPoint: .bottom)

            VStack(spacing: 8) {
                if occurrence.isCancelled {
                    Text("متخطّى")
                        .font(TamrinFont.font(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13).padding(.vertical, 6)
                        .background(.red.opacity(0.85), in: .capsule)
                }

                RosterAvatarCluster(
                    members: attendees,
                    eventID: occurrence.id,
                    selfImageData: profileImageData,
                    selfUserID: currentUserID,
                    fallbackName: profileName,
                    fallbackImageUrl: profileImageUrl
                )

                Text(occurrence.title)
                    .font(TamrinFont.font(size: 31, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)

                // One `Text`, not three. Each view resolves its own bidi
                // paragraph, and the date and the time both begin with a digit
                // — so a piece ending in «،» had its comma reordered to the
                // far edge, which is the stray one that showed up before the
                // day in every card. Written whole, the algorithm runs over
                // the whole sentence and the commas stay where they were put.
                Text("\(occurrence.startAt.arabicDay)، \(occurrence.startAt.arabicDate)، \(occurrence.startAt.arabicTime)")
                    .font(TamrinFont.font(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .environment(\.layoutDirection, .rightToLeft)

                if !occurrence.locationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(occurrence.locationName)
                        .font(TamrinFont.font(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.top, 76)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var posterArtwork: some View {
        Color.clear
            .overlay {
                Image(exerciseArt: artName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
    }

}

private struct EventSupervisorTagView: View {
    /// The artwork under the tag. Nil where there is none — the empty card —
    /// which reads as dark, the same as it always did.
    var artName: String?

    private var isOnLightArt: Bool {
        guard let artName else { return false }
        return ArtworkPalette.isTopLight(for: artName)
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "crown.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("مشرف")
                .font(TamrinFont.font(size: 14, weight: .bold))
        }
        // One colour for both. The crown used to be lime against white text,
        // which read as two things pushed together rather than one badge — and
        // a fixed accent cannot follow the artwork the way the rest of this does.
        .foregroundStyle(isOnLightArt ? TamrinTheme.ink : Color.white)
        .padding(.horizontal, 18)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        // The glass takes its light or dark form from the scheme it is drawn
        // in, so handing it the side the artwork is *not* on is what makes it
        // adapt: pale artwork gets the light glass with dark type, and the tag
        // stops dissolving into a bright sky.
        .environment(\.colorScheme, isOnLightArt ? .light : .dark)
        .accessibilityLabel("أنت مشرف هذا التمرين")
    }
}

struct EmptyScheduleCard: View {
    var profileName: String = ""
    var profileImageData: Data?
    var profileImageUrl: String?
    var showsSupervisorTag = false

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 1.0, green: 0.22, blue: 0.05), location: 0),
                    .init(color: Color(red: 0.85, green: 0.0, blue: 0.49), location: 0.28),
                    .init(color: Color(red: 0.44, green: 0.0, blue: 0.78), location: 0.62),
                    .init(color: Color(red: 0.02, green: 0.10, blue: 0.34), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 10) {
                MemberAvatar(
                    name: profileName,
                    size: 42,
                    imageData: profileImageData,
                    imageUrl: profileImageUrl,
                    tint: .white.opacity(0.22)
                )
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.7)
                }

                Text("لا توجد مواعيد قادمة")
                    .font(TamrinFont.font(size: 31, weight: .bold))
                    .foregroundStyle(.white)

                Text("أضف موعدًا جديدًا من زر +")
                    .font(TamrinFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: 36, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if showsSupervisorTag {
                EventSupervisorTagView()
                    .padding(.top, 20)
                    .padding(.trailing, 20)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .strokeBorder(Color(red: 0.05, green: 0.38, blue: 0.94), lineWidth: 0.8)
        }
        .contentShape(.rect(cornerRadius: 36, style: .continuous))
    }
}

#Preview {
    let occ = FeedOccurrence(id: UUID(), title: "كورة الثلاثاء", startAt: Date(),
                             locationName: "ملعب النخيل", capacity: 14,
                             price: 25, isCancelled: false, artIndex: 0)
    return EventPosterCard(
        occurrence: occ,
        registeredCount: 9,
        showsSupervisorTag: true,
        profileName: "فارس",
        action: {}
    )
        .frame(height: 420).padding()
        .environment(\.layoutDirection, .rightToLeft)
}

@MainActor
enum ArtworkPalette {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static var cache: [String: Color] = [:]
    private static var topLightCache: [String: Bool] = [:]

    /// How much of the image counts as "the top" for the badge that sits there.
    private static let topBandFraction: CGFloat = 0.3
    /// Above this the artwork is bright enough that white type on it stops
    /// holding, and the badge has to switch sides.
    private static let lightThreshold: CGFloat = 0.58

    /// Whether the top of this artwork is light.
    ///
    /// The top band, not the whole image: the average `averageColor` returns is
    /// taken across the frame and normalized for readability, so a photo that
    /// is bright sky over dark sand comes back as neither — which is the one
    /// answer a badge sitting in the sky cannot use.
    static func isTopLight(for imageName: String) -> Bool {
        if let cached = topLightCache[imageName] { return cached }
        guard let cgImage = source(named: imageName) else { return false }

        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        // CoreImage counts up from the bottom, so the image's top is the far
        // end of its y range, not the near one.
        let band = CGRect(
            x: extent.minX,
            y: extent.maxY - extent.height * topBandFraction,
            width: extent.width,
            height: extent.height * topBandFraction
        )
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = band
        guard let output = filter.outputImage else { return false }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        // Rec. 709 weights: the eye reads green as far brighter than blue, and
        // a plain mean would call a saturated blue court light.
        let luminance = (0.2126 * CGFloat(pixel[0])
            + 0.7152 * CGFloat(pixel[1])
            + 0.0722 * CGFloat(pixel[2])) / 255
        let isLight = luminance > lightThreshold
        topLightCache[imageName] = isLight
        return isLight
    }

    /// The name is either an asset or a bundle-relative path into a sport's
    /// photo folder — the same two kinds `Image(exerciseArt:)` accepts.
    ///
    /// A thumbnail, not the picture. Both readings below are averages, and an
    /// average does not care about resolution — but decoding a multi-megapixel
    /// sport photograph does, and it was happening on the main thread at the
    /// exact moment a card scrolled into view. That is the hitch between one
    /// card and the next, and the beat before the tint lands on the artwork.
    /// ImageIO decodes straight to this size instead of decoding in full and
    /// throwing the rest away.
    private static let sampleSize = 64

    private static func source(named imageName: String) -> CGImage? {
        if imageName.contains("/") {
            let url = Bundle.main.bundleURL.appendingPathComponent(imageName)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: sampleSize,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }
        // Asset-catalog artwork: UIKit already holds these decoded, so there is
        // nothing to save by going around it.
        return UIImage(named: imageName)?.cgImage
    }

    /// Reads both values for every artwork on the shelf up front, so no card
    /// pays for its own on the frame it appears.
    static func warm(_ imageNames: [String]) {
        for name in Set(imageNames) {
            _ = averageColor(for: name)
            _ = isTopLight(for: name)
        }
    }

    static func averageColor(for imageName: String) -> Color {
        if let cached = cache[imageName] { return cached }
        guard let cgImage = source(named: imageName) else {
            return Color(white: 0.34)
        }

        let input = CIImage(cgImage: cgImage)
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let output = filter.outputImage else { return Color(white: 0.34) }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        let average = UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: CGFloat(pixel[3]) / 255
        )

        // Keep the sampled hue and saturation, but cap luminance for pale
        // artwork so white event details remain readable. This is a tonal
        // normalization of the image average, not an unrelated palette tint.
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        let normalized: UIColor
        if average.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) {
            normalized = UIColor(
                hue: hue,
                saturation: saturation,
                brightness: min(brightness, 0.44),
                alpha: alpha
            )
        } else {
            normalized = average
        }

        let color = Color(uiColor: normalized)
        cache[imageName] = color
        return color
    }
}

/// The people who have taken a seat, drawn over the poster: the first nine to
/// sign up, sized by how early they were — the first three largest, the next
/// three a step down, the next three smaller again.
///
/// The sizes are not laid out in that order, though. Ranked left to right the
/// row would read as a podium and the three big discs would clump at one end;
/// interleaving the tiers spreads them, and which interleaving a given exercise
/// gets is fixed by its own id, so the arrangement varies between cards but
/// never re-shuffles under the reader.
struct RosterAvatarCluster: View {
    let members: [FeedMember]
    let eventID: UUID
    var selfImageData: Data?
    var selfUserID: UUID?
    /// Drawn when nobody has registered yet, so the poster keeps its shape.
    var fallbackName: String = ""
    var fallbackImageUrl: String?

    /// Slightly larger than the single avatar this replaced, so the earliest
    /// three read as the anchor of the group rather than as one more disc.
    private static let sizes: [CGFloat] = [50, 38, 29]
    private static let limit = 9

    /// Clearance between two discs, as a fraction of their combined radii —
    /// so the required centre distance is `(rᵢ + rⱼ) * (1 + spacingRatio)`.
    /// Proportional, not fixed: a fixed gap reads as a wide moat around a small
    /// disc and a tight seam around a large one, because the eye measures the
    /// gap against what it separates.
    private static let spacingRatio: CGFloat = 0.09

    /// Discs are packed by relaxation rather than read off a table of seats.
    /// A table can only hold one set of radii, and which disc is which size is
    /// shuffled per exercise, so a table either has to assume the largest
    /// radius everywhere — which is the fixed spacing this replaces — or break
    /// the moment a large disc lands in a seat cut for a small one.
    ///
    /// Cheap enough to run on each draw: nine discs is 36 pairs, and the
    /// passes below are a few thousand float operations.
    private static let relaxationPasses = 90
    /// Gravity pulls everything back to the middle between separations. Much
    /// stronger vertically, so the cluster settles wider than tall: it has the
    /// card's width to spread into and only the gap above the title to grow
    /// down through. It also steadies the height — at even gravity the packing
    /// ran anywhere from 121 to 185pt tall depending on the exercise, and that
    /// swing moves the title under it from card to card.
    private static let gravity = CGSize(width: 0.025, height: 0.12)
    /// Separation-only passes at the end. The last gravity step can pull discs
    /// back into contact, so the settled state has to be the clean one.
    private static let settlePasses = 24

    /// The largest discs should sit near the middle — but *near* it, not piled
    /// into it. Two things aim them there, and neither one alone is enough.
    ///
    /// `centrePullExponent` weights gravity by size: a disc is pulled towards
    /// the middle as `(r / rMax)ᵉ`, so the big ones hold the centre and the
    /// small ones are free to drift out. On its own it barely moves anything —
    /// the settled shape is decided by what can physically fit where, not by
    /// how hard each disc was pulled while it got there.
    ///
    /// `sizeBias` is what actually does the work: it spreads the ring the
    /// discs *start* on by size, big ones inside and small ones out. Relaxation
    /// is local, so where a disc starts is largely where it stays.
    ///
    /// Separation keeps this from collapsing back into the old arrangement —
    /// three 50pt discs cannot occupy the middle together, so they settle into
    /// a triangle around it rather than a row across it.
    private static let centrePullExponent: CGFloat = 2
    private static let sizeBias: CGFloat = 52

    /// The RPC already returns `joined_at ASC`, but the card owns the visible
    /// "first nine" promise and should not silently depend on every caller
    /// preserving that order.  Keep undated legacy/preview rows at the end and
    /// use the participant id only to make equal timestamps deterministic.
    private var seated: [FeedMember] {
        let ordered = members.enumerated().sorted { left, right in
            switch (left.element.joinedAt, right.element.joinedAt) {
            case let (leftDate?, rightDate?):
                if leftDate != rightDate { return leftDate < rightDate }
                return left.element.id.uuidString < right.element.id.uuidString
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return left.offset < right.offset
            }
        }
        return Array(ordered.prefix(Self.limit).map(\.element))
    }

    private func tier(forJoinOrder index: Int) -> Int { min(index / 3, 2) }

    /// Join order, shuffled. Sizes follow their member, so shuffling this is
    /// what keeps the largest discs from settling in the middle every time.
    ///
    /// Seeded from the exercise, not from the system generator: the cluster
    /// has to be the same arrangement every time this card is drawn, and
    /// `hashValue` is salted per process, so it would deal a different one on
    /// every launch.
    private var seating: [Int] { Self.seating(count: seated.count, eventID: eventID) }

    private static var seatingCache: [String: [Int]] = [:]

    private static func seating(count: Int, eventID: UUID) -> [Int] {
        let key = "\(eventID.uuidString)-\(count)"
        if let cached = seatingCache[key] { return cached }
        var rng = generator(for: eventID)
        var order = Array(0..<count)
        guard order.count > 1 else { return order }
        for position in stride(from: order.count - 1, to: 0, by: -1) {
            order.swapAt(position, Int(rng() % UInt64(position + 1)))
        }
        seatingCache[key] = order
        return order
    }

    private var radii: [CGFloat] {
        seating.map { Self.sizes[tier(forJoinOrder: $0)] / 2 }
    }

    /// Solved layouts, held by exercise and roster size.
    ///
    /// The relaxation below is deterministic — same exercise, same roster, same
    /// answer — so running it more than once is pure waste. And it was running
    /// far more than once: it sits in `body`, and `body` is re-evaluated on
    /// every scroll frame, for every visible card. A hundred passes over thirty
    /// six pairs, three cards deep, sixty times a second, to redraw discs that
    /// had not moved. That is the weight felt between one card and the next.
    private static var layoutCache: [String: [CGPoint]] = [:]

    private static func layout(radii: [CGFloat], eventID: UUID) -> [CGPoint] {
        let key = "\(eventID.uuidString)-\(radii.count)"
        if let cached = layoutCache[key] { return cached }
        let solved = packed(radii: radii, eventID: eventID)
        layoutCache[key] = solved
        return solved
    }

    /// Settles `radii` into a cluster around the origin: nothing touching,
    /// every clearance in proportion to the discs it separates, and everything
    /// as close to the middle as that allows.
    private static func packed(radii: [CGFloat], eventID: UUID) -> [CGPoint] {
        let count = radii.count
        guard count > 1 else { return [.zero] }

        var rng = generator(for: eventID)
        func unit() -> CGFloat { CGFloat(rng() % 10_000) / 10_000 }

        let largest = radii.max() ?? 1
        let smallest = radii.min() ?? 1
        /// 0 for the largest disc, 1 for the smallest.
        func sizeRank(_ radius: CGFloat) -> CGFloat {
            largest == smallest ? 0 : (largest - radius) / (largest - smallest)
        }

        // Started on a ring, not at the origin: the push below runs along the
        // axis between two discs, and discs at the same point have no axis.
        // The ring's radius is set by size, which is what puts the large discs
        // near the middle.
        var points: [CGPoint] = (0..<count).map { index in
            let angle = 2 * .pi * CGFloat(index) / CGFloat(count) + unit() * 0.7
            let distance = (46 - sizeBias / 2)
                + sizeBias * sizeRank(radii[index])
                + unit() * 16
            return CGPoint(x: cos(angle) * distance, y: sin(angle) * distance)
        }

        let pull = radii.map { pow($0 / largest, centrePullExponent) }

        func separate() {
            for i in 0..<count {
                for j in (i + 1)..<count {
                    let needed = (radii[i] + radii[j]) * (1 + spacingRatio)
                    var dx = points[j].x - points[i].x
                    var dy = points[j].y - points[i].y
                    var distance = sqrt(dx * dx + dy * dy)
                    if distance < 0.001 { dx = 1; dy = 0; distance = 0.001 }
                    guard distance < needed else { continue }
                    let push = (needed - distance) / 2
                    let ux = dx / distance, uy = dy / distance
                    points[i].x -= ux * push
                    points[i].y -= uy * push
                    points[j].x += ux * push
                    points[j].y += uy * push
                }
            }
        }

        for _ in 0..<relaxationPasses {
            for index in 0..<count {
                points[index].x -= points[index].x * gravity.width * pull[index]
                points[index].y -= points[index].y * gravity.height * pull[index]
            }
            separate()
        }
        for _ in 0..<settlePasses { separate() }

        // Centre on the bounding box, so the cluster is centred on what it
        // draws rather than on where the discs happened to average out.
        let minX = points.indices.map { points[$0].x - radii[$0] }.min() ?? 0
        let maxX = points.indices.map { points[$0].x + radii[$0] }.max() ?? 0
        let minY = points.indices.map { points[$0].y - radii[$0] }.min() ?? 0
        let maxY = points.indices.map { points[$0].y + radii[$0] }.max() ?? 0
        let offsetX = (minX + maxX) / 2, offsetY = (minY + maxY) / 2
        return points.map { CGPoint(x: $0.x - offsetX, y: $0.y - offsetY) }
    }

    /// The cluster has to claim the room it spreads into, or its outer discs
    /// overlap the title under it and the tag over it.
    private func clusterSize(for points: [CGPoint], radii: [CGFloat]) -> CGSize {
        let width = points.indices.map { abs(points[$0].x) + radii[$0] }.max() ?? Self.sizes[0] / 2
        let height = points.indices.map { abs(points[$0].y) + radii[$0] }.max() ?? Self.sizes[0] / 2
        return CGSize(width: 2 * width, height: 2 * height)
    }

    var body: some View {
        if seated.isEmpty {
            MemberAvatar(
                name: fallbackName,
                size: Self.sizes[1],
                imageData: selfImageData,
                imageUrl: fallbackImageUrl,
                tint: .white.opacity(0.22)
            )
        } else {
            let order = seating
            let discs = radii
            let points = Self.layout(radii: discs, eventID: eventID)
            let box = clusterSize(for: points, radii: discs)

            ZStack {
                ForEach(Array(order.enumerated()), id: \.offset) { slot, member in
                    avatar(for: seated[member], size: discs[slot] * 2)
                        .offset(x: points[slot].x, y: points[slot].y)
                }
            }
            .frame(width: box.width, height: box.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("المسجلون: \(members.count.counted(.player))")
        }
    }

    private func avatar(for member: FeedMember, size: CGFloat) -> some View {
        MemberAvatar(
            name: member.name,
            size: size,
            // My own photo can still be only in memory — the upload lags the
            // pick — so my disc reads it straight from the profile.
            imageData: member.userId == selfUserID ? selfImageData : nil,
            imageUrl: member.avatarUrl,
            tint: .white.opacity(0.22)
        )
    }

    /// A per-exercise xorshift, stable across launches. Both the shuffle and
    /// the packing draw from their own copy, so each is reproducible on its
    /// own and neither can be shifted by a change in the other.
    private static func generator(for id: UUID) -> () -> UInt64 {
        var state = withUnsafeBytes(of: id.uuid) { bytes in
            bytes.reduce(UInt64(0x9E37_79B9_7F4A_7C15)) { ($0 &* 31) &+ UInt64($1) } | 1
        }
        return {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }
}
