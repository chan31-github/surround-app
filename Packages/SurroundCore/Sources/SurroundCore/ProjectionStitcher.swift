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
    /// Crossfade width at the boundaries between shots of a multi-ring capture.
    public var sphereFeatherDegrees: Float = 2.0
    /// Two-band blending: the seams keep their sharp cuts, but brightness is
    /// crossfaded over this many degrees, so a step at a seam fades out
    /// instead of showing as a line. Off by default: measured against the
    /// rooftop spheres it made the low-frequency steps in flat sky slightly
    /// worse at every width from 6 to 40 degrees, because the per-shot gains
    /// and the radial falloff already remove the brightness differences and
    /// the wide crossfade it blends towards averages misaligned content.
    /// Kept for captures where exposure could not be locked.
    public var lowFrequencyBlendDegrees: Float = 0
    /// Move each boundary of a multi-ring capture to where the two shots
    /// disagree least (a minimum cut); off, the boundary sits midway between
    /// the shots' optical axes.
    public var sphereSeams = true
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
        /// The lens's falloff, as log brightness per unit squared normalised
        /// radius, with the scale that normalises a pixel's radius.
        let vignetteK: Float
        let invHalfDiagonalSquared: Float

        init(shot: StitchShot, rotation: Mat3, gain: Float, featherFraction: Float, vignetteK: Float = 0) {
            projector = ShotProjector(shot: shot, rotation: rotation)
            featherU = max(1, Float(shot.image.width) * featherFraction)
            featherV = max(1, Float(shot.image.height) * featherFraction)
            self.gain = gain
            self.vignetteK = vignetteK
            let halfW = Float(shot.image.width) / 2
            let halfH = Float(shot.image.height) / 2
            invHalfDiagonalSquared = 1 / max(1, halfW * halfW + halfH * halfH)
        }

        /// The shot's gain at one pixel, undoing the lens's falloff there.
        @inline(__always)
        func sampleGain(u: Float, v: Float) -> Float {
            guard vignetteK != 0 else { return gain }
            let du = u - projector.cx
            let dv = v - projector.cy
            return gain * exp(-vignetteK * (du * du + dv * dv) * invHalfDiagonalSquared)
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
        /// Ownership decided per cell of a low-resolution map, with a
        /// distance field for the crossfade.
        case map(OwnershipMap)
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
        var map: OwnershipMap?
        switch ownership {
        case .blend: break
        case .seams(let t): tables = t
        case .nearest(let degrees): nearestFeather = max(0.05, degrees)
        case .map(let m): map = m
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
                                                map: map,
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
        let map: OwnershipMap?
        let seams: Seams?

        private struct Candidate {
            var index = 0
            var u: Float = 0
            var v: Float = 0
            var weight: Float = 0
            /// Angle between the pixel and the shot's optical axis, radians.
            var angle: Float = 0
        }

        /// Ownership weight from the map cell under an output pixel: the owner
        /// fades from 1 at the crossfade radius to 0.5 at the boundary, the
        /// runner-up mirrors it, and anyone else keeps a floor so the pixel
        /// is still painted when neither is visible here.
        static func mapWeight(_ map: OwnershipMap, shot: Int, column: Int, row: Int, outW: Int, outH: Int) -> Float {
            let cx = min(map.width - 1, column * map.width / outW)
            let cy = min(map.height - 1, row * map.height / outH)
            let c = cy * map.width + cx
            let owner = Int(map.owner[c])
            let t = min(1, 0.5 + 0.5 * map.distance[c] / map.featherCells)
            if owner == shot { return t }
            if Int(map.neighbour[c]) == shot { return max(0.02, 1 - t) }
            return 0.02
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
                        if let map {
                            w *= Self.mapWeight(map, shot: i, column: x, row: y, outW: outW, outH: outH)
                        } else if nearestFeatherRadians != nil {
                            // Chord length approximates the angle for small angles.
                            let cosine = max(-1, min(1, d.dot(p.projector.forward)))
                            candidates[found] = Candidate(index: i, u: u, v: v, weight: w, angle: (2 * (1 - cosine)).squareRoot())
                            found += 1
                            continue
                        }
                        let s = PixelSampling.bilinearRGB(sources[i], width: p.projector.width, height: p.projector.height, u: u, v: v)
                        let gain = p.sampleGain(u: u, v: v)
                        r += s.r * gain * w
                        g += s.g * gain * w
                        b += s.b * gain * w
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
                            let gain = p.sampleGain(u: c.u, v: c.v)
                            r += s.r * gain * w
                            g += s.g * gain * w
                            b += s.b * gain * w
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
        var vignetteK: Float = 0
        var report: RingRefinementReport?
        var sphereReport: SphereRefinementReport?
        var ownership = Ownership.blend
        let r = options.refinement
        if n >= 2, r.refineAlignment || r.compensateExposure || r.computeSeams {
            if RingRefinement.isSingleRing(shots) {
                let refined = RingRefinement.refine(shots: shots, options: r)
                rotations = refined.rotations
                gains = refined.gains
                vignetteK = refined.vignetteK
                report = refined.report
                if !refined.seams.isEmpty {
                    ownership = .seams(seamTables(refined: refined, layout: layout))
                }
            } else {
                let refined = SphereRefinement.refine(shots: shots, options: r)
                rotations = refined.rotations
                gains = refined.gains
                vignetteK = refined.vignetteK
                sphereReport = refined.report
                if options.sphereSeams {
                    ownership = .map(SphereSeams.compute(shots: shots, rotations: rotations, gains: gains,
                                                         featherDegrees: options.sphereFeatherDegrees))
                } else {
                    ownership = .nearest(featherDegrees: options.sphereFeatherDegrees)
                }
            }
        }
        progress?(0.1)

        // With nothing deciding ownership, the border feather is the only
        // blend, so widen it.
        var feather = options.featherFraction
        if case .blend = ownership { feather = max(feather, 0.2) }
        let prepared = (0..<n).map {
            Prepared(shot: shots[$0], rotation: rotations[$0], gain: gains[$0], featherFraction: feather, vignetteK: vignetteK)
        }
        let images = shots.map { $0.image }
        let usesBands = options.lowFrequencyBlendDegrees > 0 && { if case .map = ownership { return true } else { return false } }()
        var composite = withPixelPointers(images) { sources in
            self.composite(layout: layout, prepared: prepared, ownership: ownership, seamFeatherDegrees: options.seamFeatherDegrees,
                           sources: sources) { progress?(0.1 + (usesBands ? 0.8 : 0.9) * $0) }
        }

        if usesBands {
            // Two-band blending. The composite above holds the detail, cut at
            // the seams; a wide crossfade of the same shots holds brightness
            // that varies smoothly across them. Adding back the low
            // frequencies of the difference leaves detail exactly where the
            // cut put it while a step at a seam fades out over the blend
            // width. Both are computed small, which is all the low band
            // needs, so this costs a fraction of the main pass.
            let low = EquirectangularLayout(width: max(256, min(outW, 1024)))
            let wide = (0..<n).map {
                Prepared(shot: shots[$0], rotation: rotations[$0], gain: gains[$0], featherFraction: 0.45, vignetteK: vignetteK)
            }
            let (sharpLow, smoothLow) = withPixelPointers(images) { sources -> (Composite, Composite) in
                (self.composite(layout: low, prepared: prepared, ownership: ownership,
                                seamFeatherDegrees: options.seamFeatherDegrees, sources: sources, progress: nil),
                 self.composite(layout: low, prepared: wide, ownership: .blend,
                                seamFeatherDegrees: options.seamFeatherDegrees, sources: sources, progress: nil))
            }
            let radius = max(1, Int((options.lowFrequencyBlendDegrees / (360 / Float(low.width))).rounded()))
            let correction = lowFrequencyDifference(sharp: sharpLow.pixels, smooth: smoothLow.pixels,
                                                    width: low.width, height: low.height, radius: radius)
            applyLowFrequency(correction, lowWidth: low.width, lowHeight: low.height,
                              to: &composite.pixels, width: outW, height: layout.height)
            progress?(1)
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

    /// Blurred (smooth minus sharp) per low-resolution pixel, as RGB floats.
    /// The blur wraps in yaw and is weighted by coverage, so the edge of the
    /// covered band does not drag the correction towards black.
    static func lowFrequencyDifference(sharp: [UInt8], smooth: [UInt8], width: Int, height: Int, radius: Int) -> [Float] {
        let count = width * height
        var diff = [SIMD3<Float>](repeating: .zero, count: count)
        var valid = [Float](repeating: 0, count: count)
        for i in 0..<count where sharp[i * 4 + 3] != 0 && smooth[i * 4 + 3] != 0 {
            diff[i] = SIMD3(Float(smooth[i * 4]) - Float(sharp[i * 4]),
                            Float(smooth[i * 4 + 1]) - Float(sharp[i * 4 + 1]),
                            Float(smooth[i * 4 + 2]) - Float(sharp[i * 4 + 2]))
            valid[i] = 1
        }
        // Two box passes approximate a Gaussian closely enough here.
        for _ in 0..<2 {
            var hDiff = [SIMD3<Float>](repeating: .zero, count: count)
            var hValid = [Float](repeating: 0, count: count)
            for y in 0..<height {
                for x in 0..<width {
                    var sum = SIMD3<Float>.zero
                    var w: Float = 0
                    for k in -radius...radius {
                        let i = y * width + ((x + k) % width + width) % width
                        sum += diff[i]
                        w += valid[i]
                    }
                    hDiff[y * width + x] = sum
                    hValid[y * width + x] = w
                }
            }
            var vDiff = [SIMD3<Float>](repeating: .zero, count: count)
            var vValid = [Float](repeating: 0, count: count)
            for y in 0..<height {
                let y0 = max(0, y - radius)
                let y1 = min(height - 1, y + radius)
                for x in 0..<width {
                    var sum = SIMD3<Float>.zero
                    var w: Float = 0
                    for yy in y0...y1 {
                        sum += hDiff[yy * width + x]
                        w += hValid[yy * width + x]
                    }
                    if w > 0 {
                        vDiff[y * width + x] = sum / w
                        vValid[y * width + x] = 1
                    }
                }
            }
            diff = vDiff
            valid = vValid
        }
        var out = [Float](repeating: 0, count: count * 3)
        for i in 0..<count {
            out[i * 3] = diff[i].x
            out[i * 3 + 1] = diff[i].y
            out[i * 3 + 2] = diff[i].z
        }
        return out
    }

    private struct UpsampleWork: @unchecked Sendable {
        let pixels: UnsafeMutablePointer<UInt8>
        let correction: UnsafePointer<Float>
    }

    /// Adds the bilinearly upsampled low-resolution correction to the
    /// full-resolution pixels, wrapping in yaw.
    static func applyLowFrequency(_ correction: [Float], lowWidth: Int, lowHeight: Int,
                                  to pixels: inout [UInt8], width: Int, height: Int) {
        let sx = Float(lowWidth) / Float(width)
        let sy = Float(lowHeight) / Float(height)
        pixels.withUnsafeMutableBufferPointer { px in
            correction.withUnsafeBufferPointer { c in
                // Each row writes only its own pixels and reads a shared
                // correction, which the compiler cannot see through pointers.
                let work = UpsampleWork(pixels: px.baseAddress!, correction: c.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let px = work.pixels
                    let c = work.correction
                    let fy = max(0, min(Float(lowHeight - 1), (Float(y) + 0.5) * sy - 0.5))
                    let y0 = Int(fy)
                    let y1 = min(y0 + 1, lowHeight - 1)
                    let ty = fy - Float(y0)
                    for x in 0..<width {
                        let o = (y * width + x) * 4
                        if px[o + 3] == 0 { continue }
                        let fx = (Float(x) + 0.5) * sx - 0.5
                        let x0i = Int(fx.rounded(.down))
                        let tx = fx - Float(x0i)
                        let x0 = ((x0i % lowWidth) + lowWidth) % lowWidth
                        let x1 = (x0 + 1) % lowWidth
                        let i00 = (y0 * lowWidth + x0) * 3, i10 = (y0 * lowWidth + x1) * 3
                        let i01 = (y1 * lowWidth + x0) * 3, i11 = (y1 * lowWidth + x1) * 3
                        let w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty)
                        let w01 = (1 - tx) * ty, w11 = tx * ty
                        for ch in 0..<3 {
                            let d = c[i00 + ch] * w00 + c[i10 + ch] * w10 + c[i01 + ch] * w01 + c[i11 + ch] * w11
                            px[o + ch] = UInt8(max(0, min(255, (Float(px[o + ch]) + d).rounded())))
                        }
                    }
                }
            }
        }
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
