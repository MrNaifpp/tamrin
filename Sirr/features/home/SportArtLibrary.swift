//
//  SportArtLibrary.swift
//  Sirr
//
//  The photo on an exercise card comes from its sport.
//
//  `Sirr/SportArt/` holds one real folder per sport, copied into the app as a
//  folder reference — the directory survives the build, so the app can simply
//  read what is in a sport's folder rather than being told in advance. Drop
//  photos into `SportArt/volleyball/`, build, and a volleyball exercise starts
//  wearing them. No naming rule, no list to keep in step, no Xcode step.
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit

extension Sport {
    /// The folder this sport's photos live in. ASCII and lower-case, because it
    /// is a directory name on disk before it is anything else.
    var key: String {
        switch symbol {
        case "figure.soccer": return "soccer"
        case "figure.basketball": return "basketball"
        case "figure.volleyball": return "volleyball"
        case "figure.pickleball": return "padel"
        case "figure.tennis": return "tennis"
        case "figure.cricket": return "cricket"
        case "figure.run": return "running"
        case "figure.outdoor.cycle": return "cycling"
        default: return "soccer"
        }
    }
}

enum SportArtLibrary {
    /// Where the folders live inside the bundle.
    private static let root = "SportArt"

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]

    /// `UIImage(contentsOfFile:)` does not participate in the asset-catalog
    /// cache. Building it in a SwiftUI body decoded the same sport photo once
    /// for the poster, again for its bottom blur, and again for the backdrop.
    /// Keep display-ready images in a bounded, thread-safe cache instead.
    nonisolated(unsafe) private static let displayImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 20
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()

    /// The page backdrop is the same photograph as the card, already blurred
    /// at a deliberately small resolution. Upscaling that soft bitmap is far
    /// cheaper than asking SwiftUI to blur two full-screen textures throughout
    /// every cross-fade, which is what made the old image backdrop feel heavy.
    nonisolated(unsafe) private static let backdropImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 16
        cache.totalCostLimit = 24 * 1_024 * 1_024
        return cache
    }()
    nonisolated private static let backdropCreationLock = NSLock()
    nonisolated private static let backdropContext = CIContext(
        options: [.cacheIntermediates: false]
    )

    /// Large enough for a full-width @3x poster, while preventing an oversized
    /// source photo from being decoded at a resolution the screen cannot show.
    nonisolated private static let maximumDisplayPixelSize = 1_800
    /// Blur survives enlargement, so 512px is ample for a deliberately soft
    /// full-screen layer and keeps each cached bitmap around one megabyte.
    nonisolated private static let maximumBackdropPixelSize: CGFloat = 512
    // Soft enough to separate it from the card, but not so soft that the same
    // photograph collapses back into what looks like an average-colour wash.
    nonisolated private static let backdropBlurRadius: Float = 32

    /// Read once per sport and kept: a card redraws often, and the answer only
    /// changes when the app is rebuilt.
    private static var cache: [String: [String]] = [:]

    /// Every photo in one sport's folder, as bundle-relative paths, in a stable
    /// order. Empty when the folder has no photos yet — which is the normal
    /// state for a sport nobody has shot for.
    static func photos(forSport key: String) -> [String] {
        if let cached = cache[key] { return cached }

        let directory = Bundle.main.bundleURL
            .appendingPathComponent(root)
            .appendingPathComponent(key)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { "\(root)/\(key)/\($0)" }

        cache[key] = names
        return names
    }

    /// The photo this exercise wears. Random-looking across exercises, and
    /// fixed for any one of them *until it is edited*: the same card must not
    /// change picture every time the shelf redraws, so the choice cannot be
    /// drawn fresh at draw time.
    ///
    /// It is drawn fresh at *edit* time instead. The id alone gave one answer
    /// per exercise and sport for ever, so moving an exercise to another sport
    /// and back handed it the same photograph again — the choice looked like a
    /// fixed order because, for a given exercise, it was one. `ExerciseArtSeed`
    /// is what makes it a choice: re-rolled when the sport changes, and read
    /// back unchanged on every draw in between.
    ///
    /// Nil when the sport has no photos yet, which is the caller's cue to fall
    /// back to the artwork the app ships with.
    static func photo(for eventID: UUID, sportKey: String?) -> String? {
        guard let sportKey else { return nil }
        let all = photos(forSport: sportKey)
        guard !all.isEmpty else { return nil }
        let offset = ExerciseArtSeed.value(for: eventID)
        return all[(stableIndex(for: eventID, count: all.count) + offset) % all.count]
    }

    /// A decoded, display-sized image for a bundle-relative sport photo.
    /// `NSCache` is safe to read from the main actor while a detached prewarm
    /// task is filling it.
    nonisolated static func displayImage(named name: String) -> UIImage? {
        guard name.contains("/") else { return nil }
        let key = name as NSString
        if let cached = displayImageCache.object(forKey: key) { return cached }

        let url = Bundle.main.bundleURL.appendingPathComponent(name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumDisplayPixelSize,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }

        let decoded = UIImage(cgImage: image)
        displayImageCache.setObject(
            decoded,
            forKey: key,
            cost: image.bytesPerRow * image.height
        )
        return decoded
    }

    nonisolated static func warmDisplayImages(_ names: [String]) {
        var seen: Set<String> = []
        for name in names where seen.insert(name).inserted && name.contains("/") {
            guard !Task.isCancelled else { return }
            autoreleasepool { _ = displayImage(named: name) }
        }
    }

    /// A pre-blurred copy of the exact artwork `Image(exerciseArt:)` displays.
    /// This handles both asset-catalog names and bundle-relative sport photos.
    nonisolated static func backdropImage(named name: String) -> UIImage? {
        let key = name as NSString
        if let cached = backdropImageCache.object(forKey: key) { return cached }
        guard !Task.isCancelled else { return nil }

        // NSCache protects reads/writes, not duplicate construction. Home and
        // its edge scrim can ask for the same new picture together, so serialize
        // cache misses and check once more after taking the lock.
        backdropCreationLock.lock()
        defer { backdropCreationLock.unlock() }
        if let cached = backdropImageCache.object(forKey: key) { return cached }
        // A rapid scroll can cancel this request while it waits for a previous
        // cache miss. Do not spend the next render slot on a card that is no
        // longer current.
        guard !Task.isCancelled else { return nil }

        guard let cgImage = backdropSource(named: name) else { return nil }
        let input = CIImage(cgImage: cgImage)
        let largestSide = max(input.extent.width, input.extent.height)
        let scale = min(1, maximumBackdropPixelSize / max(largestSide, 1))
        let scaled = input.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = scaled.clampedToExtent()
        blur.radius = backdropBlurRadius
        guard let blurred = blur.outputImage?.cropped(to: scaled.extent),
              let output = backdropContext.createCGImage(
                  blurred,
                  from: scaled.extent,
                  format: .RGBA8,
                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
              ) else { return nil }

        let image = UIImage(cgImage: output)
        backdropImageCache.setObject(
            image,
            forKey: key,
            cost: output.bytesPerRow * output.height
        )
        return image
    }

    nonisolated static func warmBackdropImages(_ names: [String]) {
        var seen: Set<String> = []
        for name in names where seen.insert(name).inserted {
            guard !Task.isCancelled else { return }
            autoreleasepool { _ = backdropImage(named: name) }
        }
    }

    nonisolated private static func backdropSource(named name: String) -> CGImage? {
        if name.contains("/") {
            let url = Bundle.main.bundleURL.appendingPathComponent(name)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maximumBackdropPixelSize),
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }
        return UIImage(named: name)?.cgImage
    }

    /// Swift's `hashValue` is seeded per process, so it would hand the same
    /// exercise a different photo on every launch. This walks the uuid's own
    /// bytes instead.
    private static func stableIndex(for id: UUID, count: Int) -> Int {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let mixed = bytes.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x00FF_FFFF }
        return mixed % count
    }
}

/// What turns one exercise's photograph from a fixed answer into a choice.
///
/// Held per exercise and only ever changed by an edit, never by a draw — a
/// picture that moved while the shelf scrolled would be worse than one that
/// never moved at all.
enum ExerciseArtSeed {
    private static func key(for eventID: UUID) -> String {
        "exercise.art.seed.\(eventID.uuidString)"
    }

    /// Kept in memory as well: the shelf asks for this on every redraw of every
    /// card, which is no place for a defaults read.
    private static var cache: [UUID: Int] = [:]

    static func value(for eventID: UUID) -> Int {
        if let cached = cache[eventID] { return cached }
        let stored = UserDefaults.standard.integer(forKey: key(for: eventID))
        cache[eventID] = stored
        return stored
    }

    /// A new photograph for this exercise. Random rather than the next one
    /// along, so switching sports back and forth does not walk a folder in
    /// order — which is the pattern that gave the whole thing away.
    static func reroll(for eventID: UUID) {
        let next = Int.random(in: 1...997)
        cache[eventID] = next
        UserDefaults.standard.set(next, forKey: key(for: eventID))
    }
}

extension Image {
    /// An exercise's artwork, whichever kind it is: a photo from a sport folder
    /// (a bundle-relative path) or one of the three pictures the app ships in
    /// its asset catalog. One initializer so every surface — card, backdrop,
    /// lineup page — takes the same string and neither knows nor cares.
    init(exerciseArt name: String) {
        if let image = SportArtLibrary.displayImage(named: name) {
            self.init(uiImage: image)
            return
        }
        self.init(name)
    }
}
