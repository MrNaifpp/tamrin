import UIKit
import Vision

/// The saved portrait uses the card's complete 8:11 canvas, never an implicit crop.
enum PlayerPortraitLayout {
    static let size = CGSize(width: 1600, height: 2200)

    struct Placement: Equatable {
        var rect: CGRect
        var zoom: CGFloat = 1
        var horizontal: CGFloat = 0
        var vertical: CGFloat = 0

        var adjustedRect: CGRect {
            let center = CGPoint(x: rect.midX + horizontal, y: rect.midY + vertical)
            let size = CGSize(width: rect.width * zoom, height: rect.height * zoom)
            return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
        }
    }

    /// Vision coordinates are bottom-up; the rendering canvas is top-down.
    static func alignedRect(imageSize: CGSize, face: CGRect) -> CGRect {
        let faceHeight = face.height * imageSize.height
        let scale = size.height * 0.22 / faceHeight
        let width = imageSize.width * scale / size.width
        let height = imageSize.height * scale / size.height
        return CGRect(x: 0.5 - face.midX * width,
                      y: 0.50 - (1 - face.minY) * height,
                      width: width, height: height)
    }

    static func detect(in image: UIImage) throws -> Placement? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNDetectFaceRectanglesRequest()
        #if targetEnvironment(simulator)
        request.usesCPUOnly = true
        #endif
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        // Ambiguous group photos require manual placement instead of choosing a player.
        guard let faces = request.results, faces.count == 1, let face = faces.first,
              face.confidence >= 0.7, face.boundingBox.height > 0 else { return nil }
        return Placement(rect: alignedRect(imageSize: image.size, face: face.boundingBox))
    }

    static func centered(_ image: UIImage) -> Placement {
        let scale = max(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale / size.width
        let height = image.size.height * scale / size.height
        return Placement(rect: CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height))
    }

    static func render(_ image: UIImage, placement: Placement, width: CGFloat = size.width) -> UIImage {
        let canvas = CGSize(width: width, height: width * size.height / size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            let rect = placement.adjustedRect
            image.draw(in: CGRect(x: rect.minX * canvas.width, y: rect.minY * canvas.height,
                                  width: rect.width * canvas.width, height: rect.height * canvas.height))
        }
    }

    /// Preserve the position of portraits saved before full-canvas framing existed.
    static func migrateLegacy(_ image: UIImage) -> UIImage {
        let card = PlayerCardView.designSize
        let scale = max(278 / image.size.width, 372 / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let ctx = renderer.cgContext
            ctx.scaleBy(x: size.width / card.width, y: size.height / card.height)
            ctx.clip(to: CGRect(x: 42, y: 48, width: 278, height: 372))
            image.draw(in: CGRect(x: 42 + (278 - drawn.width) / 2,
                                  y: 48 + (372 - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
    }
}
