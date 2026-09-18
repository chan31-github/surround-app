import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Decoded, downsampled thumbnails shared by the grid, the map pins and the
/// picker sheets, so scrolling never decodes the same JPEG twice and memory
/// stays bounded however large the library grows. NSCache is thread-safe,
/// evicts by cost and under memory pressure, which is what @unchecked
/// Sendable relies on here.
nonisolated final class ThumbnailCache: @unchecked Sendable {
    enum Variant: String {
        /// The whole 2:1 thumbnail for grid cards and list rows.
        case card
        /// The centre square (the sphere's front) for the map pin.
        case pin
        /// A small 2:1 image for the map callout.
        case callout

        var maxPixelSize: Int {
            switch self {
            case .card: return 512
            case .pin: return 168
            case .callout: return 216
            }
        }
    }

    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    init(costLimitBytes: Int = 48 << 20) {
        cache.totalCostLimit = costLimitBytes
    }

    func cached(_ id: UUID, _ variant: Variant) -> UIImage? {
        cache.object(forKey: Self.key(id, variant))
    }

    /// Returns the cached image or decodes it on the calling thread. Pins and
    /// callouts are small and are built inside MapKit's synchronous callbacks.
    func image(for id: UUID, variant: Variant) -> UIImage? {
        if let hit = cached(id, variant) { return hit }
        guard let image = Self.decode(id, variant) else { return nil }
        store(image, id, variant)
        return image
    }

    /// Decodes off the caller's actor; for the grid, which scrolls.
    @concurrent
    func load(_ id: UUID, _ variant: Variant) async -> UIImage? {
        image(for: id, variant: variant)
    }

    func remove(_ id: UUID) {
        for variant in [Variant.card, .pin, .callout] {
            cache.removeObject(forKey: Self.key(id, variant))
        }
    }

    private func store(_ image: UIImage, _ id: UUID, _ variant: Variant) {
        let cost = Int(image.size.width * image.scale) * Int(image.size.height * image.scale) * 4
        cache.setObject(image, forKey: Self.key(id, variant), cost: cost)
    }

    private static func key(_ id: UUID, _ variant: Variant) -> NSString {
        "\(id.uuidString)/\(variant.rawValue)" as NSString
    }

    private static func decode(_ id: UUID, _ variant: Variant) -> UIImage? {
        let url = SphereStore.files(for: id).thumbnail
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: variant == .pin ? 512 : variant.maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard variant == .pin else { return UIImage(cgImage: cg) }
        // Redraw the centre square at pin size so the full bitmap is not retained.
        let side = min(cg.width, cg.height)
        let square = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
        guard let cropped = cg.cropping(to: square) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: variant.maxPixelSize, height: variant.maxPixelSize)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
