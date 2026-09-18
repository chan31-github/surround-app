import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import SurroundCore
import UIKit

/// Bridges between platform image types and the core package's RGBAImage.
enum ImageConversion {
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

    static func thumbnailJPEG(from image: UIImage, width: Int, height: Int) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let thumb = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return thumb.jpegData(compressionQuality: 0.8)
    }
}
