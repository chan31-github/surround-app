import Dispatch
import Foundation

public struct SphereRefinementReport: Equatable, Sendable {
    /// Every pair that overlaps enough to measure, in input index order.
    public var pairs: [PairMeasurement]
    public var yawCorrectionsDegrees: [Float]
    public var pitchCorrectionsDegrees: [Float]
    public var gains: [Float]
    /// Root mean square of what the accepted pairs' offsets still disagree
    /// with after the final solve, in degrees: how well a rotation-only
    /// model could fit them. Parallax is what is left.
    public var residualYawDegrees: Float
    public var residualPitchDegrees: Float
}

public struct RefinedSphere: Sendable {
    public var rotations: [Mat3]
    public var gains: [Float]
    public var report: SphereRefinementReport
}

/// Alignment and exposure for a multi-ring capture. Where `RingRefinement`
/// walks one loop of yaw neighbours, a sphere is a graph: each shot overlaps
/// the ones beside it, above and below it, and the pole shots overlap a
/// whole ring. Every overlapping pair is measured with the ring code's
/// correlation, and the per-shot yaw and pitch corrections are solved
/// jointly by weighted least squares over the graph, anchored on the shot
/// nearest the front. Pole shots have no useful pitch axis; they take part
/// in the yaw solve only.
public enum SphereRefinement {
    public static func refine(shots: [StitchShot], options: RingRefinementOptions = RingRefinementOptions()) -> RefinedSphere {
        let n = shots.count
        var rotations = shots.map { $0.rotation }
        var projectors = shots.map { ShotProjector(shot: $0) }
        let polar = projectors.map { isPolar($0) }
        let anchor = (0..<n).min {
            abs(projectors[$0].centrePitchDegrees) + abs(projectors[$0].centreYawDegrees) / 4
                < abs(projectors[$1].centrePitchDegrees) + abs(projectors[$1].centreYawDegrees) / 4
        } ?? 0

        // Candidate pairs: optical axes close enough that the frames can overlap.
        var pairIndices: [(Int, Int)] = []
        for i in 0..<n {
            for j in (i + 1)..<n {
                let cosAngle = projectors[i].forward.dot(projectors[j].forward)
                let limit = shots[i].intrinsics.cornerHalfAngleRadians + shots[j].intrinsics.cornerHalfAngleRadians
                if cosAngle > cos(min(limit, Angle.radians(120))) { pairIndices.append((i, j)) }
            }
        }

        var yawTotal = [Float](repeating: 0, count: n)
        var pitchTotal = [Float](repeating: 0, count: n)
        var pairs: [PairMeasurement] = []
        var lastPairs: [PairMeasurement] = []
        var lastYaw = [Float](repeating: 0, count: n)
        var lastPitch = [Float](repeating: 0, count: n)
        let margin = max(options.maxYawSearchDegrees, options.maxPitchSearchDegrees) + 1
        let passes = options.refineAlignment ? max(1, options.passes) : 1

        for pass in 0..<passes {
            let measured = measurePairs(pairIndices, shots: shots, projectors: projectors, polar: polar, margin: margin, options: options)
            lastPairs = measured
            if pass == 0 { pairs = measured }
            guard options.refineAlignment else { break }

            let accepted = measured.filter { $0.accepted }
            let yaw = solve(count: n, pairs: accepted.map { ($0.from, $0.to, $0.yawOffsetDegrees, weight($0)) },
                            anchor: anchor, fixed: [])
            // A pole shot has no pitch axis to correct about, so its pairs
            // stay out of the pitch system rather than biasing its neighbours;
            // the ridge leaves its own pitch at zero.
            let pitchPairs = accepted.filter { !polar[$0.from] && !polar[$0.to] }
            let pitch = solve(count: n, pairs: pitchPairs.map { ($0.from, $0.to, $0.pitchOffsetDegrees, weight($0)) },
                              anchor: anchor, fixed: [])
            lastYaw = yaw
            lastPitch = pitch
            for k in 0..<n {
                yawTotal[k] += yaw[k]
                pitchTotal[k] += pitch[k]
                rotations[k] = RingRefinement.corrected(rotation: shots[k].rotation, yawDegrees: yawTotal[k], pitchDegrees: pitchTotal[k])
            }
            projectors = (0..<n).map { ShotProjector(shot: shots[$0], rotation: rotations[$0]) }
        }

        var gains = [Float](repeating: 1, count: n)
        if options.compensateExposure {
            let accepted = lastPairs.filter { $0.accepted }
            var logGains = solve(count: n, pairs: accepted.map { ($0.from, $0.to, $0.logGainRatio, weight($0)) }, anchor: anchor, fixed: [])
            let mean = logGains.reduce(0, +) / Float(max(1, n))
            logGains = logGains.map { $0 - mean }
            gains = logGains.map { max(1 / options.maxGain, min(options.maxGain, exp($0))) }
        }

        // Least-squares residual of the final pass: what each measured offset
        // still disagrees with after the corrections that pass produced.
        var sumYaw: Float = 0, sumPitch: Float = 0
        var count = 0
        for p in lastPairs where p.accepted {
            let dy = p.yawOffsetDegrees - (lastYaw[p.to] - lastYaw[p.from])
            let dp = p.pitchOffsetDegrees - (lastPitch[p.to] - lastPitch[p.from])
            sumYaw += dy * dy
            sumPitch += dp * dp
            count += 1
        }
        let report = SphereRefinementReport(pairs: pairs,
                                            yawCorrectionsDegrees: yawTotal,
                                            pitchCorrectionsDegrees: pitchTotal,
                                            gains: gains,
                                            residualYawDegrees: count > 0 ? (sumYaw / Float(count)).squareRoot() : 0,
                                            residualPitchDegrees: count > 0 ? (sumPitch / Float(count)).squareRoot() : 0)
        return RefinedSphere(rotations: rotations, gains: gains, report: report)
    }

    /// Overlaps below this many analysis pixels are not trusted at all;
    /// larger ones count in proportion up to `fullWeightPixels`.
    static let minimumOverlapPixels = 2000
    static let fullWeightPixels: Float = 10000

    /// Measures every candidate pair, spread across cores: each pair reads
    /// shared shots and projectors and writes only its own slot.
    static func measurePairs(_ pairIndices: [(Int, Int)], shots: [StitchShot], projectors: [ShotProjector], polar: [Bool],
                             margin: Float, options: RingRefinementOptions) -> [PairMeasurement] {
        var measured = pairIndices.map { PairMeasurement(from: $0.0, to: $0.1) }
        let work = PairWork(pairIndices: pairIndices, shots: shots, projectors: projectors, polar: polar, margin: margin, options: options)
        measured.withUnsafeMutableBufferPointer { buffer in
            let slots = Slots(base: buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: pairIndices.count) { k in
                slots.base[k] = work.measure(k)
            }
        }
        return measured
    }

    private struct Slots: @unchecked Sendable {
        let base: UnsafeMutablePointer<PairMeasurement>
    }

    private struct PairWork: @unchecked Sendable {
        let pairIndices: [(Int, Int)]
        let shots: [StitchShot]
        let projectors: [ShotProjector]
        let polar: [Bool]
        let margin: Float
        let options: RingRefinementOptions

        func measure(_ k: Int) -> PairMeasurement {
            let (i, j) = pairIndices[k]
            var pair = PairMeasurement(from: i, to: j)
            guard let window = overlapWindow(projectors[i], projectors[j], polarA: polar[i], polarB: polar[j], margin: margin) else {
                return pair
            }
            let a = RingRefinement.render(shot: shots[i], projector: projectors[i], window: window, degreesPerPixel: options.degreesPerPixel)
            let b = RingRefinement.render(shot: shots[j], projector: projectors[j], window: window, degreesPerPixel: options.degreesPerPixel)
            RingRefinement.measure(a: a, b: b, options: options, into: &pair)
            // A sliver of overlap can correlate well by chance and would steer
            // the whole solve; second neighbours on a ring produce exactly that.
            if pair.overlapPixels < minimumOverlapPixels { pair.accepted = false }
            return pair
        }
    }

    static func weight(_ p: PairMeasurement) -> Float {
        let score = max(0.1, p.score)
        return score * score * min(1, Float(p.overlapPixels) / fullWeightPixels)
    }

    /// True when the frame contains the zenith or nadir, where yaw and pitch
    /// stop meaning what the ring solver assumes.
    static func isPolar(_ p: ShotProjector) -> Bool {
        let halfAngle = Angle.degrees(acos(max(-1, min(1, p.cosRadius))))
        return abs(p.centrePitchDegrees) + halfAngle >= 90
    }

    /// Yaw and pitch window where two frames can both have pixels, in yaw
    /// unwrapped from `a`'s centre. A polar frame spans all yaw and reaches
    /// its pole in pitch.
    static func overlapWindow(_ a: ShotProjector, _ b: ShotProjector, polarA: Bool, polarB: Bool, margin: Float) -> PatchWindow? {
        func extent(_ p: ShotProjector, polar: Bool, yawCentre: Float) -> (yawLo: Float, yawHi: Float, pitchLo: Float, pitchHi: Float) {
            let bounds = p.angularBounds()
            if polar {
                let up = p.centrePitchDegrees > 0
                return (yawCentre - 180, yawCentre + 180,
                        up ? bounds.pitchMinDegrees : -90,
                        up ? 90 : bounds.pitchMaxDegrees)
            }
            return (yawCentre + bounds.yawMinRelDegrees, yawCentre + bounds.yawMaxRelDegrees,
                    bounds.pitchMinDegrees, bounds.pitchMaxDegrees)
        }
        let yawA = a.centreYawDegrees
        let yawB = yawA + Angle.wrapDegrees180(b.centreYawDegrees - yawA)
        let ea = extent(a, polar: polarA, yawCentre: yawA)
        let eb = extent(b, polar: polarB, yawCentre: yawB)
        let yawLo = max(ea.yawLo, eb.yawLo)
        let yawHi = min(ea.yawHi, eb.yawHi)
        let pitchLo = max(ea.pitchLo, eb.pitchLo, -90)
        let pitchHi = min(ea.pitchHi, eb.pitchHi, 90)
        // Require a real overlap before padding it for the search.
        guard yawHi - yawLo >= 4, pitchHi - pitchLo >= 4 else { return nil }
        return PatchWindow(yawMin: yawLo - margin, yawMax: yawHi + margin,
                           pitchMin: max(-90, pitchLo - margin), pitchMax: min(90, pitchHi + margin))
    }

    /// Weighted least squares for per-node values c such that c[to] - c[from]
    /// matches each pair's offset. `anchor` is held at zero, as are `fixed`
    /// nodes; a light ridge keeps nodes nobody measured at zero too.
    static func solve(count n: Int, pairs: [(from: Int, to: Int, delta: Float, weight: Float)], anchor: Int, fixed: Set<Int>) -> [Float] {
        guard n > 0 else { return [] }
        var m = [Double](repeating: 0, count: n * n)
        var rhs = [Double](repeating: 0, count: n)
        for k in 0..<n { m[k * n + k] = 1e-3 }
        for (i, j, d, w) in pairs {
            let wd = Double(w)
            let dd = Double(d)
            m[i * n + i] += wd
            m[j * n + j] += wd
            m[i * n + j] -= wd
            m[j * n + i] -= wd
            rhs[i] -= wd * dd
            rhs[j] += wd * dd
        }
        for k in fixed.union([anchor]) {
            for c in 0..<n { m[k * n + c] = 0; m[c * n + k] = 0 }
            m[k * n + k] = 1
            rhs[k] = 0
        }
        // Gaussian elimination with partial pivoting; n is a few dozen.
        var a = m
        var b = rhs
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(a[r * n + col]) > abs(a[pivot * n + col]) { pivot = r }
            if pivot != col {
                for c in 0..<n { a.swapAt(col * n + c, pivot * n + c) }
                b.swapAt(col, pivot)
            }
            let p = a[col * n + col]
            guard abs(p) > 1e-12 else { continue }
            for r in (col + 1)..<n {
                let f = a[r * n + col] / p
                if f == 0 { continue }
                for c in col..<n { a[r * n + c] -= f * a[col * n + c] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for c in (r + 1)..<n { s -= a[r * n + c] * x[c] }
            let p = a[r * n + r]
            x[r] = abs(p) > 1e-12 ? s / p : 0
        }
        return x.map { Float($0) }
    }
}
