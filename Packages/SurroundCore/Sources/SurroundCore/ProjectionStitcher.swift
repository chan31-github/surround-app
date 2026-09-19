import Foundation
import Dispatch

/// One captured photo with the camera orientation it was taken at.
public struct StitchShot: Sendable {
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

public struct StitchOptions: Equatable, Sendable {
    public var outputWidth: Int = 4096
    /// Width of the fade at each image border, as a fraction of the image
    /// size. Seams do the blending between neighbours, so this only needs to
    /// soften the top and bottom edges of the ring; 0.2 with refinement off
    /// reproduces the original wide crossfade.
    public var featherFraction: Float = 0.05
    /// A row counts as covered when at least this fraction of its pixels are painted.
    public var coverageThreshold: Float = 0.98
    /// Narrowest crossfade across a seam, in degrees, used where the images
    /// have texture that would ghost. Smooth areas such as sky widen it up to
    /// `refinement.smoothSeamFeatherDegrees` so brightness differences fade
    /// instead of stepping.
    public var seamFeatherDegrees: Float = 1.0
    /// Multi-ring captures have no seam paths; each pixel goes to the shot
    /// whose optical axis is nearest, crossfaded over this many degrees.
    public var sphereFeatherDegrees: Float = 2.0
    public var refinement = RingRefinementOptions()

    public init() {}

    /// Pose-only projection with a wide crossfade and no analysis.
    public static var plain: StitchOptions {
        var o = StitchOptions()
        o.featherFraction = 0.2
        o.refinement.refineAlignment = false
        o.refinement.compensateExposure = false
        o.refinement.computeSeams = false
        return o
    }
}

public struct StitchResult: Sendable {
    public var image: RGBAImage
    public var layout: EquirectangularLayout
    /// Fraction of painted pixels per output row.
    public var rowCoverage: [Float]
    /// Pitch range (bottom...top) of the longest run of fully covered rows, or
    /// nil when no row is fully covered.
    public var coveredPitchRangeDegrees: ClosedRange<Float>?
    /// What the ring analysis measured and applied, when it ran.
    public var refinement: RingRefinementReport?
    /// What the sphere analysis measured and applied, for multi-ring captures.
    public var sphereRefinement: SphereRefinementReport?
}

/// Baseline stitcher: projects each shot onto the sphere from its orientation
/// and intrinsics. Before compositing, `RingRefinement` nudges each shot's
/// yaw and pitch to match its neighbours, equalises brightness and finds a
/// seam through every overlap; the composite then takes each pixel from the
/// shot that owns it with a narrow crossfade at the seams. With refinement
/// off it degrades to the pure pose projection with a wide crossfade, which
/// is the reference for judging captures and the dependency-free fallback.
public enum ProjectionStitcher {
    public static let name = "projection"
    public static let version = "0.2"

    private struct Prepared {
        let projector: ShotProjector
        let featherU: Float, featherV: Float
        let gain: Float

        init(shot: StitchShot, rotation: Mat3, gain: Float, featherFraction: Float) {
            projector = ShotProjector(shot: shot, rotation: rotation)
            featherU = max(1, Float(shot.image.width) * featherFraction)
            featherV = max(1, Float(shot.image.height) * featherFraction)
            self.gain = gain
        }
    }

    /// Per-shot ownership limits: for every output column the pixel's yaw
    /// relative to the shot's centre, and for every output row the yaw of the
    /// seam on each side, also relative to the centre.
    private struct SeamTables {
        var relYaw: [Float]        // shots x outW
        var left: [Float]          // shots x outH, negative
        var right: [Float]         // shots x outH, positive
        var leftFeather: [Float]   // shots x outH, degrees
        var rightFeather: [Float]
    }

    private struct Composite {
        var pixels: [UInt8]
        var coverage: [Int32]
    }

    /// How overlapping shots share a pixel.
    private enum Ownership {
        /// Border feather only: every shot that sees the pixel contributes.
        case blend
        /// Ring seams: each shot owns the pixels between its two seams.
        case seams(SeamTables)
        /// The shot whose optical axis is angularly nearest owns the pixel,
        /// with a crossfade this many degrees wide at the boundary.
        case nearest(featherDegrees: Float)
    }

    /// Projects every shot into `layout` and blends by weight according to
    /// `ownership`. Rows are split into bands rendered in parallel; each band
    /// writes only its own rows.
    private static func composite(layout: EquirectangularLayout,
                                  prepared: [Prepared],
                                  ownership: Ownership,
                                  seamFeatherDegrees: Float,
                                  sources: [UnsafePointer<UInt8>],
                                  progress: (@Sendable (Float) -> Void)?) -> Composite {
        var tables: SeamTables?
        var nearestFeather: Float?
        switch ownership {
        case .blend: break
        case .seams(let t): tables = t
        case .nearest(let degrees): nearestFeather = max(0.05, degrees)
        }
        let outW = layout.width
        let outH = layout.height
        let sinYaw = (0..<outW).map { sin(Angle.radians(layout.yawDegrees(forColumn: Float($0) + 0.5))) }
        let cosYaw = (0..<outW).map { cos(Angle.radians(layout.yawDegrees(forColumn: Float($0) + 0.5))) }
        let sinPitch = (0..<outH).map { sin(Angle.radians(layout.pitchDegrees(forRow: Float($0) + 0.5))) }
        let cosPitch = (0..<outH).map { cos(Angle.radians(layout.pitchDegrees(forRow: Float($0) + 0.5))) }

        var output = [UInt8](repeating: 0, count: outW * outH * 4)
        var coverageCounts = [Int32](repeating: 0, count: outH)
        let bandRows = 16
        let bands = (outH + bandRows - 1) / bandRows
        let relYaw = tables?.relYaw ?? []
        let seamLeft = tables?.left ?? []
        let seamRight = tables?.right ?? []
        let leftFeather = tables?.leftFeather ?? []
        let rightFeather = tables?.rightFeather ?? []

        output.withUnsafeMutableBufferPointer { out in
            coverageCounts.withUnsafeMutableBufferPointer { cov in
                relYaw.withUnsafeBufferPointer { relYawPtr in
                    seamLeft.withUnsafeBufferPointer { leftPtr in
                        seamRight.withUnsafeBufferPointer { rightPtr in
                        leftFeather.withUnsafeBufferPointer { leftFPtr in
                        rightFeather.withUnsafeBufferPointer { rightFPtr in
                            guard let outBase = out.baseAddress, let covBase = cov.baseAddress else { return }
                            let work = BandWork(outW: outW, outH: outH, bandRows: bandRows,
                                                sinYaw: sinYaw, cosYaw: cosYaw, sinPitch: sinPitch, cosPitch: cosPitch,
                                                prepared: prepared, sources: sources,
                                                out: outBase, coverage: covBase,
                                                nearestFeatherRadians: nearestFeather.map { Angle.radians($0) },
                                                seams: tables == nil ? nil : BandWork.Seams(
                                                    relYaw: relYawPtr.baseAddress!, left: leftPtr.baseAddress!,
                                                    right: rightPtr.baseAddress!, leftFeather: leftFPtr.baseAddress!,
                                                    rightFeather: rightFPtr.baseAddress!,
                                                    feather: max(0.01, seamFeatherDegrees)))
                            let counter = ProgressCounter()
                            DispatchQueue.concurrentPerform(iterations: bands) { band in
                                work.render(band: band)
                                if let progress {
                                    progress(Float(counter.increment()) / Float(bands))
                                }
                            }
                        }
                        }
                        }
                    }
                }
            }
        }
        return Composite(pixels: output, coverage: coverageCounts)
    }

    /// Everything one band of rows needs. It is handed to concurrent closures,
    /// which the compiler cannot verify: the pointers stay valid for the
    /// enclosing `withUnsafe...` scopes, the read-only ones are shared, and
    /// the two output pointers are written only at each band's own rows.
    private struct BandWork: @unchecked Sendable {
        struct Seams {
            let relYaw: UnsafePointer<Float>
            let left: UnsafePointer<Float>
            let right: UnsafePointer<Float>
            let leftFeather: UnsafePointer<Float>
            let rightFeather: UnsafePointer<Float>
            let feather: Float
        }

        let outW: Int
        let outH: Int
        let bandRows: Int
        let sinYaw: [Float]
        let cosYaw: [Float]
        let sinPitch: [Float]
        let cosPitch: [Float]
        let prepared: [Prepared]
        let sources: [UnsafePointer<UInt8>]
        let out: UnsafeMutablePointer<UInt8>
        let coverage: UnsafeMutablePointer<Int32>
        let nearestFeatherRadians: Float?
        let seams: Seams?

        private struct Candidate {
            var index = 0
            var u: Float = 0
            var v: Float = 0
            var weight: Float = 0
            /// Angle between the pixel and the shot's optical axis, radians.
            var angle: Float = 0
        }

        func render(band: Int) {
            let y0 = band * bandRows
            let y1 = min(outH, y0 + bandRows)
            var candidates = [Candidate](repeating: Candidate(), count: max(1, prepared.count))
            for y in y0..<y1 {
                let sp = sinPitch[y]
                let cp = cosPitch[y]
                var painted: Int32 = 0
                var o = y * outW * 4
                for x in 0..<outW {
                    let d = Vec3(sinYaw[x] * cp, sp, -cosYaw[x] * cp)
                    var r: Float = 0, g: Float = 0, b: Float = 0, wsum: Float = 0
                    var found = 0
                    for i in 0..<prepared.count {
                        let p = prepared[i]
                        guard let uv = p.projector.project(d) else { continue }
                        let u = uv.u
                        let v = uv.v
                        var w = min(1, min(min(u, p.projector.maxU - u) / p.featherU,
                                           min(v, p.projector.maxV - v) / p.featherV))
                        if w <= 0 { continue }
                        if let seams {
                            let rel = seams.relYaw[i * outW + x]
                            let t = i * outH + y
                            let dist = min((rel - seams.left[t]) / max(seams.feather, seams.leftFeather[t]),
                                           (seams.right[t] - rel) / max(seams.feather, seams.rightFeather[t]))
                            // Never drop to zero: when the owning shot has no pixel
                            // here, the neighbour still fills it after normalisation.
                            w *= max(0.02, min(1, 0.5 + dist))
                        }
                        if nearestFeatherRadians != nil {
                            // Chord length approximates the angle for small angles.
                            let cosine = max(-1, min(1, d.dot(p.projector.forward)))
                            candidates[found] = Candidate(index: i, u: u, v: v, weight: w, angle: (2 * (1 - cosine)).squareRoot())
                            found += 1
                            continue
                        }
                        let s = PixelSampling.bilinearRGB(sources[i], width: p.projector.width, height: p.projector.height, u: u, v: v)
                        r += s.r * p.gain * w
                        g += s.g * p.gain * w
                        b += s.b * p.gain * w
                        wsum += w
                    }
                    if let featherRadians = nearestFeatherRadians, found > 0 {
                        // The nearest optical axis owns the pixel; the runner-up
                        // sets where the crossfade sits.
                        var best = 0
                        var bestAngle = Float.greatestFiniteMagnitude
                        var secondAngle = Float.greatestFiniteMagnitude
                        for k in 0..<found {
                            let a = candidates[k].angle
                            if a < bestAngle {
                                secondAngle = bestAngle
                                bestAngle = a
                                best = k
                            } else if a < secondAngle {
                                secondAngle = a
                            }
                        }
                        for k in 0..<found {
                            let c = candidates[k]
                            let gap = k == best ? secondAngle - bestAngle : bestAngle - c.angle
                            let w = c.weight * max(0.02, min(1, 0.5 + gap / featherRadians))
                            let p = prepared[c.index]
                            let s = PixelSampling.bilinearRGB(sources[c.index], width: p.projector.width, height: p.projector.height, u: c.u, v: c.v)
                            r += s.r * p.gain * w
                            g += s.g * p.gain * w
                            b += s.b * p.gain * w
                            wsum += w
                        }
                    }
                    if wsum > 0 {
                        let inv = 1 / wsum
                        out[o] = UInt8(max(0, min(255, (r * inv).rounded())))
                        out[o + 1] = UInt8(max(0, min(255, (g * inv).rounded())))
                        out[o + 2] = UInt8(max(0, min(255, (b * inv).rounded())))
                        out[o + 3] = 255
                        painted += 1
                    }
                    o += 4
                }
                coverage[y] = painted
            }
        }
    }

    private final class ProgressCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var done = 0

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            done += 1
            return done
        }
    }

    /// `progress` may be called from any thread.
    public static func stitch(shots: [StitchShot],
                              options: StitchOptions = StitchOptions(),
                              progress: (@Sendable (Float) -> Void)? = nil) -> StitchResult {
        let layout = EquirectangularLayout(width: options.outputWidth)
        let outW = layout.width
        let n = shots.count

        var rotations = shots.map { $0.rotation }
        var gains = [Float](repeating: 1, count: n)
        var report: RingRefinementReport?
        var sphereReport: SphereRefinementReport?
        var ownership = Ownership.blend
        let r = options.refinement
        if n >= 2, r.refineAlignment || r.compensateExposure || r.computeSeams {
            if RingRefinement.isSingleRing(shots) {
                let refined = RingRefinement.refine(shots: shots, options: r)
                rotations = refined.rotations
                gains = refined.gains
                report = refined.report
                if !refined.seams.isEmpty {
                    ownership = .seams(seamTables(refined: refined, layout: layout))
                }
            } else {
                let refined = SphereRefinement.refine(shots: shots, options: r)
                rotations = refined.rotations
                gains = refined.gains
                sphereReport = refined.report
                ownership = .nearest(featherDegrees: options.sphereFeatherDegrees)
            }
        }
        progress?(0.1)

        // With nothing deciding ownership, the border feather is the only
        // blend, so widen it.
        var feather = options.featherFraction
        if case .blend = ownership { feather = max(feather, 0.2) }
        let prepared = (0..<n).map {
            Prepared(shot: shots[$0], rotation: rotations[$0], gain: gains[$0], featherFraction: feather)
        }
        let images = shots.map { $0.image }
        let composite = withPixelPointers(images) { sources in
            self.composite(layout: layout, prepared: prepared, ownership: ownership, seamFeatherDegrees: options.seamFeatherDegrees,
                           sources: sources) { progress?(0.1 + 0.9 * $0) }
        }

        let rowCoverage = composite.coverage.map { Float($0) / Float(outW) }
        let range = coveredRows(rowCoverage, threshold: options.coverageThreshold).map { rows in
            let top = layout.pitchDegrees(forRow: Float(rows.lowerBound))
            let bottom = layout.pitchDegrees(forRow: Float(rows.upperBound + 1))
            return bottom...top
        }
        return StitchResult(image: RGBAImage(width: outW, height: layout.height, pixels: composite.pixels),
                            layout: layout,
                            rowCoverage: rowCoverage,
                            coveredPitchRangeDegrees: range,
                            refinement: report,
                            sphereRefinement: sphereReport)
    }

    private static func seamTables(refined: RefinedRing, layout: EquirectangularLayout) -> SeamTables {
        let n = refined.rotations.count
        let outW = layout.width
        let outH = layout.height
        var tables = SeamTables(relYaw: [Float](repeating: 0, count: n * outW),
                                left: [Float](repeating: -180, count: n * outH),
                                right: [Float](repeating: 180, count: n * outH),
                                leftFeather: [Float](repeating: 0, count: n * outH),
                                rightFeather: [Float](repeating: 0, count: n * outH))
        let order = refined.report.order
        for (position, index) in order.enumerated() {
            let forward = (-refined.rotations[index].c2).normalized
            let centreYaw = Angle.degrees(atan2(forward.x, -forward.z))
            for x in 0..<outW {
                tables.relYaw[index * outW + x] = Angle.wrapDegrees180(layout.yawDegrees(forColumn: Float(x) + 0.5) - centreYaw)
            }
            guard refined.seams.count == n else { continue }
            let leftSeam = refined.seams[(position + n - 1) % n]
            let rightSeam = refined.seams[position]
            for y in 0..<outH {
                let pitch = layout.pitchDegrees(forRow: Float(y) + 0.5)
                var left = Angle.wrapDegrees180(leftSeam.midYawDegrees + leftSeam.relYaw(atPitch: pitch) - centreYaw)
                var right = Angle.wrapDegrees180(rightSeam.midYawDegrees + rightSeam.relYaw(atPitch: pitch) - centreYaw)
                if left > 0 { left -= 360 }
                if right < 0 { right += 360 }
                tables.left[index * outH + y] = left
                tables.right[index * outH + y] = right
                tables.leftFeather[index * outH + y] = leftSeam.featherDegrees(atPitch: pitch)
                tables.rightFeather[index * outH + y] = rightSeam.featherDegrees(atPitch: pitch)
            }
        }
        return tables
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
