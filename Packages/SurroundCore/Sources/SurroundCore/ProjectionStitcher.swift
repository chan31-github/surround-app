import Foundation
import Dispatch

/// One captured photo with the camera orientation it was taken at.
public struct StitchShot {
    public var image: RGBAImage
    /// Intrinsics for `image`'s pixel size.
    public var intrinsics: CameraIntrinsics
    /// World-from-camera rotation, in the sphere's own frame (front = yaw 0).
    public var rotation: Mat3

    public init(image: RGBAImage, intrinsics: CameraIntrinsics, rotation: Mat3) {
        self.image = image
        self.intrinsics = intrinsics
        self.rotation = rotation
    }
}

public struct StitchOptions: Equatable {
    public var outputWidth: Int = 4096
    /// Width of the blend ramp at each image edge, as a fraction of the image size.
    public var featherFraction: Float = 0.2
    /// A row counts as covered when at least this fraction of its pixels are painted.
    public var coverageThreshold: Float = 0.98

    public init() {}
}

public struct StitchResult {
    public var image: RGBAImage
    public var layout: EquirectangularLayout
    /// Fraction of painted pixels per output row.
    public var rowCoverage: [Float]
    /// Pitch range (bottom...top) of the longest run of fully covered rows, or
    /// nil when no row is fully covered.
    public var coveredPitchRangeDegrees: ClosedRange<Float>?
}

/// Baseline stitcher: projects each shot onto the sphere using only its known
/// orientation and intrinsics, and feather-blends the overlaps. No feature
/// matching and no exposure compensation. Quality depends entirely on the
/// accuracy of the poses, which makes it the reference for checking captures
/// as well as the dependency-free fallback.
public enum ProjectionStitcher {
    public static let name = "projection"
    public static let version = "0.1"

    private struct Prepared {
        let cameraFromWorld: Mat3
        let forward: Vec3
        let cosRadius: Float
        let fx: Float, fy: Float, cx: Float, cy: Float
        let width: Int, height: Int
        let maxU: Float, maxV: Float
        let featherU: Float, featherV: Float

        init(shot: StitchShot, featherFraction: Float) {
            cameraFromWorld = shot.rotation.transposed
            forward = (-shot.rotation.c2).normalized
            cosRadius = cos(shot.intrinsics.cornerHalfAngleRadians + Angle.radians(1))
            fx = shot.intrinsics.fx
            fy = shot.intrinsics.fy
            cx = shot.intrinsics.cx
            cy = shot.intrinsics.cy
            width = shot.image.width
            height = shot.image.height
            maxU = Float(width - 1) - 0.001
            maxV = Float(height - 1) - 0.001
            featherU = max(1, Float(width) * featherFraction)
            featherV = max(1, Float(height) * featherFraction)
        }
    }

    /// `progress` may be called from any thread.
    public static func stitch(shots: [StitchShot],
                              options: StitchOptions = StitchOptions(),
                              progress: ((Float) -> Void)? = nil) -> StitchResult {
        let layout = EquirectangularLayout(width: options.outputWidth)
        let outW = layout.width
        let outH = layout.height
        let prepared = shots.map { Prepared(shot: $0, featherFraction: options.featherFraction) }

        var sinYaw = [Float](repeating: 0, count: outW)
        var cosYaw = [Float](repeating: 0, count: outW)
        for x in 0..<outW {
            let yaw = Angle.radians(layout.yawDegrees(forColumn: Float(x) + 0.5))
            sinYaw[x] = sin(yaw)
            cosYaw[x] = cos(yaw)
        }
        var sinPitch = [Float](repeating: 0, count: outH)
        var cosPitch = [Float](repeating: 0, count: outH)
        for y in 0..<outH {
            let pitch = Angle.radians(layout.pitchDegrees(forRow: Float(y) + 0.5))
            sinPitch[y] = sin(pitch)
            cosPitch[y] = cos(pitch)
        }

        var output = [UInt8](repeating: 0, count: outW * outH * 4)
        var coverageCounts = [Int32](repeating: 0, count: outH)
        let bandRows = 16
        let bands = (outH + bandRows - 1) / bandRows
        let progressLock = NSLock()
        var bandsDone = 0

        withPixelPointers(prepared.isEmpty ? [] : shots.map { $0.image }) { sources in
            output.withUnsafeMutableBufferPointer { out in
                coverageCounts.withUnsafeMutableBufferPointer { cov in
                    guard let outBase = out.baseAddress, let covBase = cov.baseAddress else { return }
                    DispatchQueue.concurrentPerform(iterations: bands) { band in
                        let y0 = band * bandRows
                        let y1 = min(outH, y0 + bandRows)
                        for y in y0..<y1 {
                            let sp = sinPitch[y]
                            let cp = cosPitch[y]
                            var painted: Int32 = 0
                            var o = y * outW * 4
                            for x in 0..<outW {
                                let d = Vec3(sinYaw[x] * cp, sp, -cosYaw[x] * cp)
                                var r: Float = 0, g: Float = 0, b: Float = 0, wsum: Float = 0
                                for i in 0..<prepared.count {
                                    let p = prepared[i]
                                    if d.dot(p.forward) < p.cosRadius { continue }
                                    let c = p.cameraFromWorld * d
                                    if c.z >= 0 { continue }
                                    let inv = 1 / -c.z
                                    let u = p.fx * c.x * inv + p.cx
                                    let v = -p.fy * c.y * inv + p.cy
                                    if u < 0 || v < 0 || u > p.maxU || v > p.maxV { continue }
                                    let w = min(1, min(min(u, p.maxU - u) / p.featherU, min(v, p.maxV - v) / p.featherV))
                                    if w <= 0 { continue }
                                    let s = sampleBilinear(sources[i], width: p.width, height: p.height, u: u, v: v)
                                    r += s.r * w
                                    g += s.g * w
                                    b += s.b * w
                                    wsum += w
                                }
                                if wsum > 0 {
                                    let inv = 1 / wsum
                                    outBase[o] = UInt8(max(0, min(255, (r * inv).rounded())))
                                    outBase[o + 1] = UInt8(max(0, min(255, (g * inv).rounded())))
                                    outBase[o + 2] = UInt8(max(0, min(255, (b * inv).rounded())))
                                    outBase[o + 3] = 255
                                    painted += 1
                                }
                                o += 4
                            }
                            covBase[y] = painted
                        }
                        if let progress {
                            progressLock.lock()
                            bandsDone += 1
                            let fraction = Float(bandsDone) / Float(bands)
                            progressLock.unlock()
                            progress(fraction)
                        }
                    }
                }
            }
        }

        let rowCoverage = coverageCounts.map { Float($0) / Float(outW) }
        let range = coveredRows(rowCoverage, threshold: options.coverageThreshold).map { rows in
            let top = layout.pitchDegrees(forRow: Float(rows.lowerBound))
            let bottom = layout.pitchDegrees(forRow: Float(rows.upperBound + 1))
            return bottom...top
        }
        return StitchResult(image: RGBAImage(width: outW, height: outH, pixels: output),
                            layout: layout,
                            rowCoverage: rowCoverage,
                            coveredPitchRangeDegrees: range)
    }

    /// Longest run of consecutive rows at or above `threshold`.
    static func coveredRows(_ coverage: [Float], threshold: Float) -> ClosedRange<Int>? {
        var best: ClosedRange<Int>?
        var start: Int?
        for (i, c) in coverage.enumerated() {
            if c >= threshold {
                if start == nil { start = i }
            } else if let s = start {
                if best == nil || (i - 1 - s) > (best!.upperBound - best!.lowerBound) { best = s...(i - 1) }
                start = nil
            }
        }
        if let s = start {
            let end = coverage.count - 1
            if best == nil || (end - s) > (best!.upperBound - best!.lowerBound) { best = s...end }
        }
        return best
    }

    @inline(__always)
    private static func sampleBilinear(_ px: UnsafePointer<UInt8>, width: Int, height: Int, u: Float, v: Float) -> (r: Float, g: Float, b: Float) {
        let x0 = Int(u)
        let y0 = Int(v)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let tx = u - Float(x0)
        let ty = v - Float(y0)
        let stride = width * 4
        let i00 = y0 * stride + x0 * 4
        let i10 = y0 * stride + x1 * 4
        let i01 = y1 * stride + x0 * 4
        let i11 = y1 * stride + x1 * 4
        let w00 = (1 - tx) * (1 - ty)
        let w10 = tx * (1 - ty)
        let w01 = (1 - tx) * ty
        let w11 = tx * ty
        let r = Float(px[i00]) * w00 + Float(px[i10]) * w10 + Float(px[i01]) * w01 + Float(px[i11]) * w11
        let g = Float(px[i00 + 1]) * w00 + Float(px[i10 + 1]) * w10 + Float(px[i01 + 1]) * w01 + Float(px[i11 + 1]) * w11
        let b = Float(px[i00 + 2]) * w00 + Float(px[i10 + 2]) * w10 + Float(px[i01 + 2]) * w01 + Float(px[i11 + 2]) * w11
        return (r, g, b)
    }

    /// Runs `body` with a stable base pointer for every image's pixel array.
    private static func withPixelPointers<T>(_ images: [RGBAImage],
                                             _ collected: [UnsafePointer<UInt8>] = [],
                                             _ body: ([UnsafePointer<UInt8>]) -> T) -> T {
        if collected.count == images.count { return body(collected) }
        return images[collected.count].pixels.withUnsafeBufferPointer { buf in
            withPixelPointers(images, collected + [buf.baseAddress!], body)
        }
    }
}
