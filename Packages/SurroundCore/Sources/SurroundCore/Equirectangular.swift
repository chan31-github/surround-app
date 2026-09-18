import Foundation

/// Pixel layout of an equirectangular image.
///
/// Column x maps to yaw (x / width) * 360 - 180, so the image centre is yaw 0
/// (the sphere's front). Row y maps to pitch 90 - (y / height) * 180, so the
/// top row is the zenith.
public struct EquirectangularLayout: Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int) {
        self.width = max(2, width)
        self.height = max(1, width / 2)
    }

    public func yawDegrees(forColumn x: Float) -> Float {
        (x / Float(width)) * 360 - 180
    }

    public func pitchDegrees(forRow y: Float) -> Float {
        90 - (y / Float(height)) * 180
    }

    /// Direction through the centre of a pixel.
    public func direction(column: Int, row: Int) -> Vec3 {
        CapturePlan.direction(yawDegrees: yawDegrees(forColumn: Float(column) + 0.5),
                              pitchDegrees: pitchDegrees(forRow: Float(row) + 0.5))
    }

    /// Continuous pixel coordinates for a direction.
    public func pixel(for d: Vec3) -> (x: Float, y: Float) {
        let n = d.normalized
        let yaw = Angle.degrees(atan2(n.x, -n.z))
        let pitch = Angle.degrees(asin(max(-1, min(1, n.y))))
        return ((yaw + 180) / 360 * Float(width), (90 - pitch) / 180 * Float(height))
    }
}

/// 8-bit RGBA image, row-major, 4 bytes per pixel, no padding.
public struct RGBAImage: Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public var bytesPerRow: Int { width * 4 }

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "pixel buffer size mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public static func filled(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> RGBAImage {
        var img = RGBAImage(width: width, height: height)
        for i in stride(from: 0, to: img.pixels.count, by: 4) {
            img.pixels[i] = r
            img.pixels[i + 1] = g
            img.pixels[i + 2] = b
            img.pixels[i + 3] = a
        }
        return img
    }

    public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    public mutating func setPixel(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        let i = (y * width + x) * 4
        pixels[i] = r
        pixels[i + 1] = g
        pixels[i + 2] = b
        pixels[i + 3] = a
    }

    /// Replaces every fully transparent pixel with the colour `rowColor` gives
    /// for its row, and makes it opaque.
    public mutating func fillTransparentPixels(with rowColor: (Int) -> (r: UInt8, g: UInt8, b: UInt8)) {
        let width = self.width
        let height = self.height
        pixels.withUnsafeMutableBufferPointer { buf in
            for y in 0..<height {
                let (r, g, b) = rowColor(y)
                var i = y * width * 4
                for _ in 0..<width {
                    if buf[i + 3] == 0 {
                        buf[i] = r
                        buf[i + 1] = g
                        buf[i + 2] = b
                        buf[i + 3] = 255
                    }
                    i += 4
                }
            }
        }
    }

    /// A neutral dark gradient for the sky and ground a cylindrical capture
    /// does not cover: slightly lighter at the zenith, near black at the nadir.
    public static func skyGroundGradient(height: Int) -> (Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let top: (Float, Float, Float) = (46, 50, 60)
        let bottom: (Float, Float, Float) = (14, 14, 16)
        return { y in
            let t = height > 1 ? Float(y) / Float(height - 1) : 0
            return (UInt8(top.0 + (bottom.0 - top.0) * t),
                    UInt8(top.1 + (bottom.1 - top.1) * t),
                    UInt8(top.2 + (bottom.2 - top.2) * t))
        }
    }
}
