import CoreGraphics
import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit

/// Shrinks picked photos down to what an avatar actually needs before they are
/// uploaded.
///
/// PhotosPicker hands back the camera original — 1.5 MB on average and up to
/// 5.8 MB in the bucket today — and those bytes then leave Storage again on
/// every fetch, by every device, for every roster row. Sending the original was
/// worth 7.75 GB of egress against a 23 MB bucket in the first week of
/// September. Nothing downstream ever draws more than a small circle, so the
/// original is pure waste in both directions.
enum AvatarImage {
    /// Avatars render at roughly 40–80 pt, so 512 px covers the largest of them
    /// at 3x with room left for a design that decides to show one bigger.
    static let maxPixelSize = 512
    static let compressionQuality: CGFloat = 0.8

    /// Re-encodes `data` as a JPEG no larger than `maxPixelSize` on its long
    /// edge. Returns nil if ImageIO cannot read the source at all.
    static func downsampled(from data: Data) -> Data? {
        // ImageIO decodes straight to the target size, so a 5.8 MB photo never
        // becomes a full-size bitmap in memory the way UIImage(data:) would.
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Bakes the EXIF orientation into the pixels. Without it a photo
            // taken sideways uploads sideways, because the tag that would have
            // corrected it does not survive the re-encode.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }

        return UIImage(cgImage: thumbnail).jpegData(compressionQuality: compressionQuality)
    }
}

extension PhotosPickerItem {
    /// The picked photo, shrunk to avatar size.
    ///
    /// Every call site wants the same thing, and the one that forgets to shrink
    /// is the one that puts a 5 MB file back in the bucket — so the shrinking
    /// lives here rather than at the four pickers.
    func loadAvatarData() async -> Data? {
        guard let data = try? await loadTransferable(type: Data.self) else { return nil }
        // A format ImageIO cannot read is not one PhotosPicker produces, but if
        // it ever happens, losing the user's photo is a worse outcome than
        // uploading it whole.
        return AvatarImage.downsampled(from: data) ?? data
    }
}
