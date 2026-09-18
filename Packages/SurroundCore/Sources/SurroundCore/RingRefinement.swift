import Foundation

/// Tuning for the analysis that runs before compositing a ring of shots.
public struct RingRefinementOptions: Equatable {
    /// Correct each shot's yaw and pitch by matching it against its neighbours.
    public var refineAlignment = true
    /// Equalise brightness between neighbours with a per-shot gain.
    public var compensateExposure = true
    /// Cut each overlap along the path where the two shots agree best instead
    /// of blending the whole overlap.
    public var computeSeams = true
    /// Resolution of the analysis renders.
    public var degreesPerPixel: Float = 0.25
    public var maxYawSearchDegrees: Float = 6
    public var maxPitchSearchDegrees: Float = 3
    /// Restricts the pitch band the alignment is measured on. Content above
    /// the horizon is usually far away, where a rotation-only model holds;
    /// nearby ground, railings and walls below it suffer parallax.
    public var measurePitchRange: ClosedRange<Float>? = nil
    /// Radius of the local-mean filter removed before matching, so vignetting
    /// and sky gradients do not dominate the correlation.
    public var highPassRadiusDegrees: Float = 2
    /// Measure-and-correct rounds. A pitch error moves off-axis content by a
    /// little less than the error itself, so a second round removes what the
    /// first left behind.
    public var passes: Int = 2
    /// A pair below this normalised cross-correlation is treated as unmeasured.
    public var minimumScore: Float = 0.2
    public var minimumOverlapPixels: Int = 300
    public var maxGain: Float = 1.6
    /// Widest crossfade across a seam, used where both shots are smooth
    /// (sky, haze) so brightness differences fade instead of stepping.
    public var smoothSeamFeatherDegrees: Float = 12
    /// Local texture (mean high-pass luma) at or above which a seam row gets
    /// the narrow crossfade, and at or below which it gets the widest.
    public var textureForNarrowSeam: Float = 0.03
    public var textureForWideSeam: Float = 0.008

    public init() {}
}

/// What one adjacent pair of shots told us. `to` should be rotated by the
/// offsets relative to `from` for its content to line up.
public struct PairMeasurement: Equatable {
    public var from: Int
    public var to: Int
    public var yawOffsetDegrees: Float = 0
    public var pitchOffsetDegrees: Float = 0
    public var score: Float = 0
    public var overlapPixels: Int = 0
    /// log(mean luma of `from` / mean luma of `to`) over the overlap.
    public var logGainRatio: Float = 0
    public var accepted = false
}

public struct RingRefinementReport: Equatable {
    /// Shot indices in ring order (increasing yaw).
    public var order: [Int]
    /// Pair k is between `order[k]` and `order[(k + 1) % n]`.
    public var pairs: [PairMeasurement]
    /// Per shot, in input order.
    public var yawCorrectionsDegrees: [Float]
    public var pitchCorrectionsDegrees: [Float]
    public var gains: [Float]
    /// Sum of the measured yaw offsets around the ring; zero for perfect poses.
    public var closureYawDegrees: Float
    public var closurePitchDegrees: Float
}

public struct RefinedRing {
    /// Corrected world-from-camera rotation per shot, in input order.
    public var rotations: [Mat3]
    public var gains: [Float]
    public var report: RingRefinementReport
    /// One seam per pair in ring order; empty when seams were not computed.
    var seams: [RingSeam]
}

/// Where the composite switches from the left shot of a pair to the right
/// one, as a yaw offset from the pair's midpoint per row of pitch.
struct RingSeam {
    var midYawDegrees: Float
    var pitchTopDegrees: Float
    var degreesPerRow: Float
    /// Seam yaw minus `midYawDegrees` per row from `pitchTopDegrees` downwards.
    /// Empty means the seam sits at the midpoint everywhere.
    var relYaw: [Float]
    /// Crossfade width per row, in degrees. Empty means the caller's default.
    var featherDegrees: [Float] = []

    func relYaw(atPitch pitch: Float) -> Float {
        Self.sample(relYaw, atPitch: pitch, top: pitchTopDegrees, degreesPerRow: degreesPerRow)
    }

    func featherDegrees(atPitch pitch: Float) -> Float {
        Self.sample(featherDegrees, atPitch: pitch, top: pitchTopDegrees, degreesPerRow: degreesPerRow)
    }

    static func sample(_ rows: [Float], atPitch pitch: Float, top: Float, degreesPerRow: Float) -> Float {
        guard let first = rows.first else { return 0 }
        guard rows.count > 1 else { return first }
        let r = (top - pitch) / degreesPerRow - 0.5
        if r <= 0 { return first }
        let last = rows.count - 1
        if r >= Float(last) { return rows[last] }
        let i = Int(r)
        let t = r - Float(i)
        return rows[i] * (1 - t) + rows[i + 1] * t
    }
}

/// Grayscale render of one shot over a window of yaw and pitch. Yaw is
/// unwrapped: the window may extend past 180 degrees.
struct LumaPatch {
    let width: Int
    let height: Int
    let yawMin: Float
    let pitchMax: Float
    let degreesPerPixel: Float
    var luma: [Float]
    var valid: [UInt8]
}

struct PatchWindow {
    var yawMin: Float
    var yawMax: Float
    var pitchMin: Float
    var pitchMax: Float
}

/// Refines a single ring of shots taken at roughly the same pitch: measures
/// how far each shot is from its neighbours by image correlation, solves the
/// per-shot yaw and pitch corrections with the ring closed, equalises
/// exposure, and finds the seam through each overlap. Everything works on
/// small equirectangular renders so it costs a fraction of the stitch itself.
public enum RingRefinement {
    public static func refine(shots: [StitchShot], options: RingRefinementOptions = RingRefinementOptions()) -> RefinedRing {
        let n = shots.count
        var projectors = shots.map { ShotProjector(shot: $0) }
        let order = (0..<n).sorted { projectors[$0].centreYawDegrees < projectors[$1].centreYawDegrees }
        var pairs: [PairMeasurement] = []
        let pairCount = n >= 2 ? n : 0
        for k in 0..<pairCount {
            pairs.append(PairMeasurement(from: order[k], to: order[(k + 1) % n]))
        }

        // 1. Measure each pair, solve the ring, and repeat on the corrected
        //    poses. The report keeps the first round's measurements because
        //    they describe the raw pose error; gains come from the last round,
        //    when the overlaps line up best.
        var yawByPosition = [Float](repeating: 0, count: n)
        var pitchByPosition = [Float](repeating: 0, count: n)
        var closureYaw: Float = 0
        var closurePitch: Float = 0
        var rotations = shots.map { $0.rotation }
        var lastPairs = pairs
        if pairCount > 0, options.refineAlignment || options.compensateExposure {
            let margin = max(options.maxYawSearchDegrees, options.maxPitchSearchDegrees) + 1
            let passes = options.refineAlignment ? max(1, options.passes) : 1
            for pass in 0..<passes {
                var measured = pairs
                for k in 0..<pairCount {
                    let i = measured[k].from
                    let j = measured[k].to
                    guard var window = overlapWindow(projectors[i], projectors[j], margin: margin) else { continue }
                    if let band = options.measurePitchRange {
                        window.pitchMin = max(window.pitchMin, band.lowerBound)
                        window.pitchMax = min(window.pitchMax, band.upperBound)
                        guard window.pitchMax > window.pitchMin else { continue }
                    }
                    let a = render(shot: shots[i], projector: projectors[i], window: window, degreesPerPixel: options.degreesPerPixel)
                    let b = render(shot: shots[j], projector: projectors[j], window: window, degreesPerPixel: options.degreesPerPixel)
                    measure(a: a, b: b, options: options, into: &measured[k])
                }
                lastPairs = measured
                if pass == 0 { pairs = measured }
                guard options.refineAlignment else { break }
                let accepted = measured.map { $0.accepted }
                let yaw = chain(deltas: measured.map { $0.yawOffsetDegrees }, accepted: accepted, anchorFirst: true)
                let pitch = chain(deltas: measured.map { $0.pitchOffsetDegrees }, accepted: accepted, anchorFirst: false)
                if pass == 0 {
                    closureYaw = yaw.closure
                    closurePitch = pitch.closure
                }
                for position in 0..<n {
                    yawByPosition[position] += yaw.corrections[position]
                    pitchByPosition[position] += pitch.corrections[position]
                }
                // Keep the shot nearest the sphere's front where it is, so the
                // front direction the user chose survives the corrections.
                let anchor = (0..<n).min { abs(projectors[order[$0]].centreYawDegrees) < abs(projectors[order[$1]].centreYawDegrees) } ?? 0
                let anchorYaw = yawByPosition[anchor]
                for position in 0..<n { yawByPosition[position] -= anchorYaw }
                for (position, index) in order.enumerated() {
                    rotations[index] = corrected(rotation: shots[index].rotation,
                                                 yawDegrees: yawByPosition[position],
                                                 pitchDegrees: pitchByPosition[position])
                }
                projectors = (0..<n).map { ShotProjector(shot: shots[$0], rotation: rotations[$0]) }
            }
        }

        var yawCorrections = [Float](repeating: 0, count: n)
        var pitchCorrections = [Float](repeating: 0, count: n)
        for (position, index) in order.enumerated() {
            yawCorrections[index] = yawByPosition[position]
            pitchCorrections[index] = pitchByPosition[position]
        }

        var gains = [Float](repeating: 1, count: n)
        if options.compensateExposure, pairCount > 0 {
            let logGains = chain(deltas: lastPairs.map { $0.logGainRatio }, accepted: lastPairs.map { $0.accepted }, anchorFirst: false)
            for (position, index) in order.enumerated() {
                gains[index] = max(1 / options.maxGain, min(options.maxGain, exp(logGains.corrections[position])))
            }
        }

        // 3. Seams through the corrected overlaps.
        var seams: [RingSeam] = []
        if options.computeSeams, pairCount > 0 {
            projectors = (0..<n).map { ShotProjector(shot: shots[$0], rotation: rotations[$0]) }
            for k in 0..<pairCount {
                let i = pairs[k].from
                let j = pairs[k].to
                let yawI = projectors[i].centreYawDegrees
                let gap = ringGap(from: yawI, to: projectors[j].centreYawDegrees)
                let mid = yawI + gap / 2
                var seam = RingSeam(midYawDegrees: mid, pitchTopDegrees: 90, degreesPerRow: options.degreesPerPixel, relYaw: [])
                if let window = overlapWindow(projectors[i], projectors[j], margin: 1),
                   window.yawMax - window.yawMin >= 3 * options.degreesPerPixel {
                    let a = render(shot: shots[i], projector: projectors[i], window: window, degreesPerPixel: options.degreesPerPixel)
                    let b = render(shot: shots[j], projector: projectors[j], window: window, degreesPerPixel: options.degreesPerPixel)
                    let columns = seamColumns(a: a, b: b, gainA: gains[i], gainB: gains[j])
                    seam.pitchTopDegrees = window.pitchMax
                    seam.relYaw = columns.map { window.yawMin + (Float($0) + 0.5) * options.degreesPerPixel - mid }
                    seam.featherDegrees = seamFeathers(a: a, b: b, columns: columns, options: options)
                }
                seams.append(seam)
            }
        }

        let report = RingRefinementReport(order: order,
                                          pairs: pairs,
                                          yawCorrectionsDegrees: yawCorrections,
                                          pitchCorrectionsDegrees: pitchCorrections,
                                          gains: gains,
                                          closureYawDegrees: closureYaw,
                                          closurePitchDegrees: closurePitch)
        return RefinedRing(rotations: rotations, gains: gains, report: report, seams: seams)
    }

    // MARK: Geometry helpers

    /// Yaw distance going clockwise from `from` to `to`, in (0, 360].
    static func ringGap(from: Float, to: Float) -> Float {
        let g = Angle.wrapDegrees360(to - from)
        return g == 0 ? 360 : g
    }

    /// Window covering where shot `a` (left) and shot `b` (right, the next one
    /// clockwise) can both have pixels, in yaw unwrapped from `a`'s centre.
    static func overlapWindow(_ a: ShotProjector, _ b: ShotProjector, margin: Float) -> PatchWindow? {
        let ba = a.angularBounds()
        let bb = b.angularBounds()
        let yawA = a.centreYawDegrees
        let yawB = yawA + ringGap(from: yawA, to: b.centreYawDegrees)
        let yawMin = yawB + bb.yawMinRelDegrees - margin
        let yawMax = yawA + ba.yawMaxRelDegrees + margin
        guard yawMax > yawMin else { return nil }
        let pitchMin = max(-90, min(ba.pitchMinDegrees, bb.pitchMinDegrees) - margin)
        let pitchMax = min(90, max(ba.pitchMaxDegrees, bb.pitchMaxDegrees) + margin)
        guard pitchMax > pitchMin else { return nil }
        return PatchWindow(yawMin: yawMin, yawMax: yawMax, pitchMin: pitchMin, pitchMax: pitchMax)
    }

    /// `rotation` with its yaw increased by `yawDegrees` (compass sense) and
    /// its viewing direction tilted up by `pitchDegrees`.
    static func corrected(rotation: Mat3, yawDegrees: Float, pitchDegrees: Float) -> Mat3 {
        var r = rotation
        if pitchDegrees != 0 {
            let forward = (-rotation.c2).normalized
            let right = forward.cross(Vec3.up)
            if right.length > 1e-4 {
                r = Quat(axis: right, radians: Angle.radians(pitchDegrees)).rotationMatrix * r
            }
        }
        if yawDegrees != 0 {
            r = Mat3.rotationY(-Angle.radians(yawDegrees)) * r
        }
        return r
    }

    /// Integrates pairwise offsets around a closed ring. Pair k relates
    /// position k to k + 1; the last pair closes back to position 0. The sum
    /// of the offsets should be zero; whatever remains is spread over the
    /// pairs that were not measured, or over every pair when all were.
    static func chain(deltas: [Float], accepted: [Bool], anchorFirst: Bool) -> (corrections: [Float], closure: Float) {
        let n = deltas.count
        guard n > 0 else { return ([], 0) }
        let closure = deltas.reduce(0, +)
        let rejected = (0..<n).filter { !accepted[$0] }
        var adjust = [Float](repeating: closure / Float(n), count: n)
        if !rejected.isEmpty {
            adjust = [Float](repeating: 0, count: n)
            for r in rejected { adjust[r] = closure / Float(rejected.count) }
        }
        var corrections = [Float](repeating: 0, count: n)
        var acc: Float = 0
        for k in 0..<(n - 1) {
            acc += deltas[k] - adjust[k]
            corrections[k + 1] = acc
        }
        if !anchorFirst {
            let mean = corrections.reduce(0, +) / Float(n)
            corrections = corrections.map { $0 - mean }
        }
        return (corrections, closure)
    }

    // MARK: Rendering

    static func render(shot: StitchShot, projector: ShotProjector, window: PatchWindow, degreesPerPixel dpp: Float) -> LumaPatch {
        let width = max(1, Int(((window.yawMax - window.yawMin) / dpp).rounded(.up)))
        let height = max(1, Int(((window.pitchMax - window.pitchMin) / dpp).rounded(.up)))
        var luma = [Float](repeating: 0, count: width * height)
        var valid = [UInt8](repeating: 0, count: width * height)
        shot.image.pixels.withUnsafeBufferPointer { buf in
            guard let px = buf.baseAddress else { return }
            for y in 0..<height {
                let pitch = Angle.radians(window.pitchMax - (Float(y) + 0.5) * dpp)
                let sp = sin(pitch)
                let cp = cos(pitch)
                for x in 0..<width {
                    let yaw = Angle.radians(window.yawMin + (Float(x) + 0.5) * dpp)
                    let d = Vec3(sin(yaw) * cp, sp, -cos(yaw) * cp)
                    guard let uv = projector.project(d) else { continue }
                    let s = PixelSampling.bilinearRGB(px, width: projector.width, height: projector.height, u: uv.u, v: uv.v)
                    luma[y * width + x] = PixelSampling.luma(s)
                    valid[y * width + x] = 1
                }
            }
        }
        return LumaPatch(width: width, height: height, yawMin: window.yawMin, pitchMax: window.pitchMax,
                         degreesPerPixel: dpp, luma: luma, valid: valid)
    }

    /// Luma minus its local mean over `radius`, with a validity mask eroded by
    /// `radius`. Near the edge of a shot the local mean is one-sided, and that
    /// artefact sits on opposite sides of the overlap for the two shots, which
    /// biases the correlation peak if those pixels take part.
    static func highPass(_ p: LumaPatch, radius: Int) -> (values: [Float], valid: [UInt8]) {
        let w = p.width
        let h = p.height
        let sw = w + 1
        var sumL = [Float](repeating: 0, count: sw * (h + 1))
        var sumV = [Float](repeating: 0, count: sw * (h + 1))
        for y in 0..<h {
            var rowL: Float = 0
            var rowV: Float = 0
            for x in 0..<w {
                let i = y * w + x
                if p.valid[i] != 0 {
                    rowL += p.luma[i]
                    rowV += 1
                }
                sumL[(y + 1) * sw + x + 1] = sumL[y * sw + x + 1] + rowL
                sumV[(y + 1) * sw + x + 1] = sumV[y * sw + x + 1] + rowV
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        var interior = [UInt8](repeating: 0, count: w * h)
        let full = Float((2 * radius + 1) * (2 * radius + 1))
        for y in 0..<h {
            let y0 = max(0, y - radius)
            let y1 = min(h, y + radius + 1)
            for x in 0..<w {
                let i = y * w + x
                if p.valid[i] == 0 { continue }
                let x0 = max(0, x - radius)
                let x1 = min(w, x + radius + 1)
                let count = sumV[y1 * sw + x1] - sumV[y0 * sw + x1] - sumV[y1 * sw + x0] + sumV[y0 * sw + x0]
                let total = sumL[y1 * sw + x1] - sumL[y0 * sw + x1] - sumL[y1 * sw + x0] + sumL[y0 * sw + x0]
                out[i] = count > 0 ? p.luma[i] - total / count : 0
                if count >= full - 0.5 { interior[i] = 1 }
            }
        }
        return (out, interior)
    }

    /// Halves the resolution; a coarse pixel is valid only when all four of its
    /// fine pixels are, so edges do not bleed.
    static func downsample(_ values: [Float], _ valid: [UInt8], width: Int, height: Int) -> (values: [Float], valid: [UInt8], width: Int, height: Int) {
        let w2 = max(1, width / 2)
        let h2 = max(1, height / 2)
        var out = [Float](repeating: 0, count: w2 * h2)
        var outValid = [UInt8](repeating: 0, count: w2 * h2)
        guard width >= 2, height >= 2 else { return (out, outValid, w2, h2) }
        for y in 0..<h2 {
            for x in 0..<w2 {
                let i00 = (2 * y) * width + 2 * x
                let i10 = i00 + 1
                let i01 = i00 + width
                let i11 = i01 + 1
                if valid[i00] != 0, valid[i10] != 0, valid[i01] != 0, valid[i11] != 0 {
                    out[y * w2 + x] = (values[i00] + values[i10] + values[i01] + values[i11]) * 0.25
                    outValid[y * w2 + x] = 1
                }
            }
        }
        return (out, outValid, w2, h2)
    }

    // MARK: Matching

    struct Shift: Hashable {
        let sx: Int
        let sy: Int
    }

    /// Normalised cross-correlation of `a` with `b` shifted right by `sx` and
    /// down by `sy`, over pixels valid in both.
    static func correlation(a: [Float], validA: [UInt8], b: [Float], validB: [UInt8],
                            width: Int, height: Int, sx: Int, sy: Int) -> (score: Float, count: Int) {
        let y0 = max(0, sy)
        let y1 = min(height, height + sy)
        let x0 = max(0, sx)
        let x1 = min(width, width + sx)
        guard y0 < y1, x0 < x1 else { return (-1, 0) }
        var sab: Float = 0
        var saa: Float = 0
        var sbb: Float = 0
        var count = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                validA.withUnsafeBufferPointer { va in
                    validB.withUnsafeBufferPointer { vb in
                        for y in y0..<y1 {
                            let ra = y * width
                            let rb = (y - sy) * width - sx
                            for x in x0..<x1 where va[ra + x] != 0 && vb[rb + x] != 0 {
                                let av = pa[ra + x]
                                let bv = pb[rb + x]
                                sab += av * bv
                                saa += av * av
                                sbb += bv * bv
                                count += 1
                            }
                        }
                    }
                }
            }
        }
        guard count > 0, saa > 0, sbb > 0 else { return (-1, count) }
        return (sab / (saa * sbb).squareRoot(), count)
    }

    static func search(a: [Float], validA: [UInt8], b: [Float], validB: [UInt8], width: Int, height: Int,
                       sxRange: ClosedRange<Int>, syRange: ClosedRange<Int>, minimumCount: Int) -> (best: Shift, score: Float, count: Int, scores: [Shift: Float])? {
        var best: Shift?
        var bestScore: Float = -2
        var bestCount = 0
        var scores: [Shift: Float] = [:]
        for sy in syRange {
            for sx in sxRange {
                let r = correlation(a: a, validA: validA, b: b, validB: validB, width: width, height: height, sx: sx, sy: sy)
                guard r.count >= minimumCount else { continue }
                scores[Shift(sx: sx, sy: sy)] = r.score
                if r.score > bestScore {
                    bestScore = r.score
                    best = Shift(sx: sx, sy: sy)
                    bestCount = r.count
                }
            }
        }
        guard let b = best else { return nil }
        return (b, bestScore, bestCount, scores)
    }

    /// Sub-pixel refinement of a peak from its two neighbours' scores.
    static func parabolicOffset(_ before: Float?, _ peak: Float, _ after: Float?) -> Float {
        guard let s0 = before, let s2 = after else { return 0 }
        let denom = s0 - 2 * peak + s2
        guard denom < 0 else { return 0 }
        return max(-0.5, min(0.5, 0.5 * (s0 - s2) / denom))
    }

    static func measure(a: LumaPatch, b: LumaPatch, options: RingRefinementOptions, into pair: inout PairMeasurement) {
        guard a.width == b.width, a.height == b.height else { return }
        let dpp = options.degreesPerPixel
        let radius = max(1, Int((options.highPassRadiusDegrees / dpp).rounded()))
        let (hpA, validA) = highPass(a, radius: radius)
        let (hpB, validB) = highPass(b, radius: radius)
        let maxSx = max(1, Int((options.maxYawSearchDegrees / dpp).rounded()))
        let maxSy = max(1, Int((options.maxPitchSearchDegrees / dpp).rounded()))

        var fineSx = -maxSx...maxSx
        var fineSy = -maxSy...maxSy
        let coarseA = downsample(hpA, validA, width: a.width, height: a.height)
        let coarseB = downsample(hpB, validB, width: b.width, height: b.height)
        if let coarse = search(a: coarseA.values, validA: coarseA.valid, b: coarseB.values, validB: coarseB.valid,
                               width: coarseA.width, height: coarseA.height,
                               sxRange: (-maxSx / 2)...(maxSx / 2), syRange: (-maxSy / 2)...(maxSy / 2),
                               minimumCount: max(1, options.minimumOverlapPixels / 4)) {
            let cx = 2 * coarse.best.sx
            let cy = 2 * coarse.best.sy
            fineSx = max(-maxSx, cx - 3)...min(maxSx, cx + 3)
            fineSy = max(-maxSy, cy - 3)...min(maxSy, cy + 3)
        }
        guard let fine = search(a: hpA, validA: validA, b: hpB, validB: validB, width: a.width, height: a.height,
                                sxRange: fineSx, syRange: fineSy, minimumCount: options.minimumOverlapPixels) else {
            return
        }
        let s = fine.best
        let subX = parabolicOffset(fine.scores[Shift(sx: s.sx - 1, sy: s.sy)], fine.score, fine.scores[Shift(sx: s.sx + 1, sy: s.sy)])
        let subY = parabolicOffset(fine.scores[Shift(sx: s.sx, sy: s.sy - 1)], fine.score, fine.scores[Shift(sx: s.sx, sy: s.sy + 1)])
        pair.yawOffsetDegrees = (Float(s.sx) + subX) * dpp
        pair.pitchOffsetDegrees = -(Float(s.sy) + subY) * dpp
        pair.score = fine.score
        pair.overlapPixels = fine.count
        pair.accepted = fine.score >= options.minimumScore && fine.count >= options.minimumOverlapPixels

        // Brightness ratio over the aligned overlap.
        var sumA: Float = 0
        var sumB: Float = 0
        var count = 0
        let y0 = max(0, s.sy), y1 = min(a.height, a.height + s.sy)
        let x0 = max(0, s.sx), x1 = min(a.width, a.width + s.sx)
        if y0 < y1, x0 < x1 {
            for y in y0..<y1 {
                let ra = y * a.width
                let rb = (y - s.sy) * a.width - s.sx
                for x in x0..<x1 where a.valid[ra + x] != 0 && b.valid[rb + x] != 0 {
                    sumA += a.luma[ra + x]
                    sumB += b.luma[rb + x]
                    count += 1
                }
            }
        }
        if count > 0, sumA > 0, sumB > 0 {
            pair.logGainRatio = log(sumA / sumB)
        }
    }

    // MARK: Seams

    /// Column of the seam for every row: the top-to-bottom path, moving at
    /// most one column per row, along which the two gain-corrected renders
    /// differ least. Pixels only one shot covers are expensive so the path
    /// stays inside the true overlap, and a weak pull towards the centre
    /// column decides rows where nothing else does.
    static func seamColumns(a: LumaPatch, b: LumaPatch, gainA: Float, gainB: Float) -> [Int] {
        let w = a.width
        let h = a.height
        guard w > 0, h > 0, b.width == w, b.height == h else { return [] }
        let centre = Float(w - 1) / 2
        let pull: Float = 0.0005
        var cost = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            var c: Float = 1
            if a.valid[i] != 0, b.valid[i] != 0 {
                c = abs(min(1, a.luma[i] * gainA) - min(1, b.luma[i] * gainB))
            }
            cost[i] = c + pull * abs(Float(i % w) - centre)
        }
        var acc = cost
        var from = [Int8](repeating: 0, count: w * h)
        if h > 1 {
            for y in 1..<h {
                let row = y * w
                let prev = row - w
                for x in 0..<w {
                    var bestPrev = acc[prev + x]
                    var step: Int8 = 0
                    if x > 0, acc[prev + x - 1] < bestPrev {
                        bestPrev = acc[prev + x - 1]
                        step = -1
                    }
                    if x + 1 < w, acc[prev + x + 1] < bestPrev {
                        bestPrev = acc[prev + x + 1]
                        step = 1
                    }
                    acc[row + x] = cost[row + x] + bestPrev
                    from[row + x] = step
                }
            }
        }
        var x = 0
        let last = (h - 1) * w
        for cx in 1..<max(1, w) where acc[last + cx] < acc[last + x] { x = cx }
        var columns = [Int](repeating: 0, count: h)
        var y = h - 1
        while true {
            columns[y] = x
            if y == 0 { break }
            x += Int(from[y * w + x])
            y -= 1
        }
        return columns
    }

    /// Crossfade width for every seam row from the texture around the seam:
    /// the narrow width where either shot has detail (which would ghost), the
    /// wide one where both are smooth, smoothed over neighbouring rows.
    static func seamFeathers(a: LumaPatch, b: LumaPatch, columns: [Int], options: RingRefinementOptions) -> [Float] {
        let w = a.width
        let h = a.height
        guard columns.count == h, w > 0 else { return [] }
        let dpp = options.degreesPerPixel
        let radius = max(1, Int((1 / dpp).rounded()))
        let (hpA, validA) = highPass(a, radius: radius)
        let (hpB, validB) = highPass(b, radius: radius)
        let reach = max(1, Int((options.smoothSeamFeatherDegrees / dpp).rounded()))
        var texture = [Float](repeating: 0, count: h)
        for y in 0..<h {
            var sum: Float = 0
            var count = 0
            let x0 = max(0, columns[y] - reach)
            let x1 = min(w - 1, columns[y] + reach)
            for x in x0...x1 {
                let i = y * w + x
                if validA[i] != 0 {
                    sum += abs(hpA[i])
                    count += 1
                }
                if validB[i] != 0 {
                    sum += abs(hpB[i])
                    count += 1
                }
            }
            // Negative marks a row with nothing measurable, at the edge of coverage.
            texture[y] = count > 0 ? sum / Float(count) : -1
        }
        // Take the most detailed measured row within a couple of degrees, so a
        // wide fade never reaches into texture, then smooth the width across rows.
        let guardRows = max(1, Int((2 / dpp).rounded()))
        var widest = [Float](repeating: 0, count: h)
        for y in 0..<h {
            var t: Float = -1
            for yy in max(0, y - guardRows)...min(h - 1, y + guardRows) { t = max(t, texture[yy]) }
            widest[y] = t < 0 ? options.textureForNarrowSeam : t
        }
        let narrow = options.textureForNarrowSeam
        let wide = options.textureForWideSeam
        var feather = widest.map { t -> Float in
            let f = narrow > wide ? (narrow - t) / (narrow - wide) : 0
            return max(0, min(1, f)) * options.smoothSeamFeatherDegrees
        }
        let smoothRows = max(1, Int((3 / dpp).rounded()))
        var smoothed = feather
        for y in 0..<h {
            var sum: Float = 0
            var n = 0
            for yy in max(0, y - smoothRows)...min(h - 1, y + smoothRows) {
                sum += feather[yy]
                n += 1
            }
            smoothed[y] = sum / Float(n)
        }
        feather = smoothed
        return feather
    }
}
