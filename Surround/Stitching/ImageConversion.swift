import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import ImageIO
import SurroundCore
import UIKit
import UniformTypeIdentifiers

/// Bridges between platform image types and the core package's RGBAImage.
/// Called from background encoding and stitching as well as the UI.
nonisolated enum ImageConversion {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Longest side of a stored still. The stitcher reads stills at about 1.5
    /// times the output's needs, 1144 px across for a 4096-wide sphere and
    /// 2288 for 8192, so 12-megapixel originals were never used at full size
    /// and cost 4.7 MB each; at this size in HEIC a still is about 0.6 MB.
    static let stillMaxPixelSize = 2400
    static let stillQuality: CGFloat = 0.85

    struct EncodedStill {
        let data: Data
        let width: Int
        let height: Int
        /// False when HEIC encoding was refused and the still is a JPEG.
        let isHEIC: Bool
    }

    /// Encodes a camera pixel buffer as a still no larger than
    /// `stillMaxPixelSize` on its long side: HEIC through ImageIO, the same
    /// writer the migration uses, or JPEG if the HEIC encoder refuses, so a
    /// capture never fails for want of an encoder. The image keeps the
    /// sensor's landscape orientation; no orientation tag is written.
    static func encodeStill(from pixelBuffer: CVPixelBuffer) -> EncodedStill? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let longest = max(image.extent.width, image.extent.height)
        if longest > CGFloat(stillMaxPixelSize) {
            let scale = CGFloat(stillMaxPixelSize) / longest
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = image
            filter.scale = Float(scale)
            filter.aspectRatio = 1
            image = filter.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = CGRect(x: 0, y: 0, width: image.extent.width.rounded(.down), height: image.extent.height.rounded(.down))
        guard let cg = ciContext.createCGImage(image, from: extent) else { return nil }
        let quality = [kCGImageDestinationLossyCompressionQuality: stillQuality] as CFDictionary
        for (type, isHEIC) in [(UTType.heic, true), (UTType.jpeg, false)] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, cg, quality)
            if CGImageDestinationFinalize(destination), data.length > 0 {
                return EncodedStill(data: data as Data, width: cg.width, height: cg.height, isHEIC: isHEIC)
            }
        }
        return nil
    }

    /// Re-encodes a stored full-size JPEG still as a HEIC at the stored size,
    /// for captures made before stills were stored small. Returns the new
    /// file's size in bytes.
    static func reencodeStill(jpeg: URL, to heic: URL) throws -> Int {
        guard let source = CGImageSourceCreateWithURL(jpeg as CFURL, nil) else { throw SphereStoreError.imageEncoding }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: stillMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw SphereStoreError.imageEncoding
        }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: stillQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SphereStoreError.imageEncoding }
        return (try? heic.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
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
