import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import SurroundCore
import UIKit

/// Bridges between platform image types and the core package's RGBAImage.
/// Called from background encoding and stitching as well as the UI.
nonisolated enum ImageConversion {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Encodes a camera pixel buffer (any format CoreImage understands) as JPEG.
    /// The image keeps the sensor's landscape orientation; no orientation tag is written.
    static func jpegData(from pixelBuffer: CVPixelBuffer, quality: CGFloat = 0.92) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        return ciContext.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: options)
    }

    /// Decodes an image file into RGBA, downscaled so its longer side is at most `maxPixelSize`.
    static func loadRGBA(from url: URL, maxPixelSize: Int) -> RGBAImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return rgba(from: cg)
    }

    static func rgba(from cg: CGImage) -> RGBAImage? {
        let width = cg.width
        let height = cg.height
        var image = RGBAImage(width: width, height: height)
        let ok: Bool = image.pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? image : nil
    }

    static func cgImage(from image: RGBAImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(image.pixels) as CFData) else { return nil }
        return CGImage(width: image.width,
                       height: image.height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: image.bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// Yaw span of the thumbnail window; the pitch span is half of it so the
    /// window has the card's 2:1 shape and stays within a ring's covered band.
    static let thumbnailYawSpanDegrees: CGFloat = 90

    /// A thumbnail of the sphere's front: a window `thumbnailYawSpanDegrees`
    /// wide centred on yaw 0, pitch 0 of the equirectangular image (the
    /// direction the user faced at Start), rather than the whole sphere
    /// flattened, which is unreadable at card size.
    static func thumbnailJPEG(from image: UIImage, width: Int, height: Int) -> Data? {
        guard let cg = image.cgImage else { return nil }
        let fullW = CGFloat(cg.width)
        let fullH = CGFloat(cg.height)
        let cropW = (fullW * thumbnailYawSpanDegrees / 360).rounded()
        let cropH = (fullH * (thumbnailYawSpanDegrees / 2) / 180).rounded()
        let crop = CGRect(x: ((fullW - cropW) / 2).rounded(), y: ((fullH - cropH) / 2).rounded(), width: cropW, height: cropH)
        let source = cg.cropping(to: crop).map { UIImage(cgImage: $0) } ?? image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let thumb = renderer.image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        return thumb.jpegData(compressionQuality: 0.8)
    }
}
