import XCTest
@testable import SurroundCore

final class RingRefinementTests: XCTestCase {
    /// Deterministic textured world: blobs and stripes as a function of direction.
    private static let blobs: [(Vec3, Float)] = {
        var seed: UInt32 = 12345
        func next() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24)
        }
        return (0..<160).map { _ in
            let yaw = next() * 360 - 180
            let pitch = next() * 120 - 60
            return (CapturePlan.direction(yawDegrees: yaw, pitchDegrees: pitch), 2 + next() * 4)
        }
    }()

    /// Textured below about 12 degrees of pitch, a smooth sky above it.
    static func worldLuma(_ d: Vec3) -> Float {
        var v: Float = 0.45
        let yaw = atan2(d.x, -d.z)
        let pitch = asin(max(-1, min(1, d.y)))
        let pitchDeg = Angle.degrees(pitch)
        let texture = max(0, min(1, (15 - pitchDeg) / 5))
        v += 0.1 * sin(pitch)
        if texture > 0 {
            var t: Float = 0.08 * sin(41 * yaw) * sin(29 * pitch + 1)
            for (c, sigma) in blobs {
                let a = Angle.degrees(d.angle(to: c))
                if a < sigma * 3 { t += 0.35 * exp(-(a * a) / (sigma * sigma)) }
            }
            v += t * texture
        }
        return max(0, min(1, v))
    }

    /// Renders what a camera with `rotation` would see of the world.
    static func shot(rotation: Mat3, width: Int = 240, height: Int = 180, fx: Float = 160) -> StitchShot {
        let intrinsics = CameraIntrinsics(fx: fx, fy: fx, cx: Float(width) / 2, cy: Float(height) / 2, width: width, height: height)
        let projector = ShotProjector(intrinsics: intrinsics, rotation: rotation, width: width, height: height)
        var image = RGBAImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let d = projector.direction(u: Float(x) + 0.5, v: Float(y) + 0.5)
                let g = UInt8(max(0, min(255, (worldLuma(d) * 255).rounded())))
                image.setPixel(x: x, y: y, r: g, g: g, b: g)
            }
        }
        return StitchShot(image: image, intrinsics: intrinsics, rotation: rotation)
    }

    static func pose(yaw: Float, pitch: Float) -> Mat3 {
        RingRefinement.corrected(rotation: .identity, yawDegrees: yaw, pitchDegrees: pitch)
    }

    /// Writes an image as binary PPM when SURROUND_DUMP names a directory, for eyeballing failures.
    static func dump(_ image: RGBAImage, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SURROUND_DUMP"] else { return }
        var data = Data("P6\n\(image.width) \(image.height)\n255\n".utf8)
        for i in stride(from: 0, to: image.pixels.count, by: 4) {
            data.append(contentsOf: image.pixels[i..<(i + 3)])
        }
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".ppm"))
    }

    func testCorrectedRotationMovesForwardAsNamed() {
        let r = RingRefinement.corrected(rotation: .identity, yawDegrees: 30, pitchDegrees: 10)
        let pose = CameraPose(rotation: r)
        XCTAssertEqual(pose.yawDegrees, 30, accuracy: 1e-3)
        XCTAssertEqual(pose.pitchDegrees, 10, accuracy: 1e-3)
    }

    func testRecoversPerturbedRingPoses() {
        // Ring of 8 shots 45 degrees apart with a 74 degree yaw field of view.
        let yawErrors: [Float] = [0, 1.3, -0.9, 0.6, -1.4, 0.2, 1.0, -0.5]
        let pitchErrors: [Float] = [0.4, -0.7, 0.9, 0, -0.3, 0.8, -1.1, 0.2]
        var shots: [StitchShot] = []
        for k in 0..<8 {
            let nominalYaw = Float(k) * 45
            // The photo was really taken at the perturbed pose but is labelled with the nominal one.
            var s = Self.shot(rotation: Self.pose(yaw: nominalYaw + yawErrors[k], pitch: pitchErrors[k]))
            s.rotation = Self.pose(yaw: nominalYaw, pitch: 0)
            shots.append(s)
        }
        var options = RingRefinementOptions()
        options.computeSeams = false
        let refined = RingRefinement.refine(shots: shots, options: options)
        let report = refined.report

        for pair in report.pairs {
            let expectedYaw = yawErrors[pair.to] - yawErrors[pair.from]
            let expectedPitch = pitchErrors[pair.to] - pitchErrors[pair.from]
            print(String(format: "pair %d->%d yaw %.2f (exp %.2f) pitch %.2f (exp %.2f) score %.2f n=%d gain %.3f",
                         pair.from, pair.to, pair.yawOffsetDegrees, expectedYaw, pair.pitchOffsetDegrees, expectedPitch,
                         pair.score, pair.overlapPixels, pair.logGainRatio))
            XCTAssertTrue(pair.accepted, "pair \(pair.from)-\(pair.to) score \(pair.score) overlap \(pair.overlapPixels)")
            XCTAssertGreaterThan(pair.score, 0.5)
        }
        XCTAssertEqual(report.closureYawDegrees, 0, accuracy: 0.3)

        let meanPitchError = pitchErrors.reduce(0, +) / 8
        // Yaw is anchored on the shot nearest the front, which is shot 0 here.
        XCTAssertEqual(report.yawCorrectionsDegrees[0], 0)
        for k in 0..<8 {
            XCTAssertEqual(report.yawCorrectionsDegrees[k], yawErrors[k] - yawErrors[0], accuracy: 0.3, "yaw of shot \(k)")
            XCTAssertEqual(report.pitchCorrectionsDegrees[k], pitchErrors[k] - meanPitchError, accuracy: 0.3, "pitch of shot \(k)")
            let corrected = CameraPose(rotation: refined.rotations[k])
            XCTAssertEqual(Angle.wrapDegrees180(corrected.yawDegrees - Float(k) * 45), yawErrors[k] - yawErrors[0], accuracy: 0.3)
        }
        XCTAssertEqual(refined.gains.reduce(0, +) / 8, 1, accuracy: 0.05)
    }

    func testGainCompensationFindsDarkerShot() {
        var shots: [StitchShot] = []
        for k in 0..<6 {
            var s = Self.shot(rotation: Self.pose(yaw: Float(k) * 60, pitch: 0))
            if k == 2 {
                for i in stride(from: 0, to: s.image.pixels.count, by: 4) {
                    s.image.pixels[i] = UInt8(Float(s.image.pixels[i]) * 0.7)
                    s.image.pixels[i + 1] = UInt8(Float(s.image.pixels[i + 1]) * 0.7)
                    s.image.pixels[i + 2] = UInt8(Float(s.image.pixels[i + 2]) * 0.7)
                }
            }
            shots.append(s)
        }
        let refined = RingRefinement.refine(shots: shots)
        let g = refined.gains
        for k in 0..<6 where k != 2 {
            XCTAssertEqual(g[2] / g[k], 1 / 0.7, accuracy: 0.08)
        }
    }

    func testChainDistributesClosureOverAllPairsWhenAllMeasured() {
        let r = RingRefinement.chain(deltas: [1, 1, 1, -2], accepted: [true, true, true, true], anchorFirst: true)
        XCTAssertEqual(r.closure, 1, accuracy: 1e-6)
        XCTAssertEqual(r.corrections, [0, 0.75, 1.5, 2.25])
    }

    func testChainPutsClosureIntoUnmeasuredPair() {
        let r = RingRefinement.chain(deltas: [1, 1, 0, -1], accepted: [true, true, false, true], anchorFirst: true)
        XCTAssertEqual(r.corrections, [0, 1, 2, 1])
        let centred = RingRefinement.chain(deltas: [1, 1, 0, -1], accepted: [true, true, false, true], anchorFirst: false)
        XCTAssertEqual(centred.corrections.reduce(0, +), 0, accuracy: 1e-5)
    }

    func testSeamFollowsCheapestColumn() {
        let w = 5, h = 6
        var a = LumaPatch(width: w, height: h, yawMin: 0, pitchMax: 0, degreesPerPixel: 1,
                          luma: [Float](repeating: 0.2, count: w * h), valid: [UInt8](repeating: 1, count: w * h))
        var b = a
        // The shots disagree everywhere except column 3.
        for y in 0..<h {
            for x in 0..<w where x != 3 { b.luma[y * w + x] = 0.9 }
        }
        a.luma[0] = 0.2
        XCTAssertEqual(RingRefinement.seamColumns(a: a, b: b, gainA: 1, gainB: 1), [Int](repeating: 3, count: h))
    }

    func testSeamInterpolatesBetweenRows() {
        let seam = RingSeam(midYawDegrees: 0, pitchTopDegrees: 10, degreesPerRow: 1, relYaw: [0, 2, 4])
        XCTAssertEqual(seam.relYaw(atPitch: 20), 0)
        XCTAssertEqual(seam.relYaw(atPitch: 9.5), 0, accuracy: 1e-5)
        XCTAssertEqual(seam.relYaw(atPitch: 8.5), 2, accuracy: 1e-5)
        XCTAssertEqual(seam.relYaw(atPitch: 8), 3, accuracy: 1e-5)
        XCTAssertEqual(seam.relYaw(atPitch: -5), 4)
    }

    func testFullStitchOfRingIsSeamlessAndAligned() {
        var shots: [StitchShot] = []
        let errors: [Float] = [0, 1.1, -0.8, 0.5, -1.2, 0.3]
        for k in 0..<6 {
            var s = Self.shot(rotation: Self.pose(yaw: Float(k) * 60 + errors[k], pitch: 0))
            s.rotation = Self.pose(yaw: Float(k) * 60, pitch: 0)
            shots.append(s)
        }
        var options = StitchOptions()
        options.outputWidth = 720
        let result = ProjectionStitcher.stitch(shots: shots, options: options)
        XCTAssertNotNil(result.refinement)
        Self.dump(result.image, name: "refined")
        if let rep = result.refinement {
            for p in rep.pairs {
                print(String(format: "full pair %d->%d yaw %.2f (exp %.2f) pitch %.2f score %.2f gain %.3f", p.from, p.to,
                             p.yawOffsetDegrees, errors[p.to] - errors[p.from], p.pitchOffsetDegrees, p.score, p.logGainRatio))
            }
            print("gains", rep.gains, "yaw", rep.yawCorrectionsDegrees, "pitch", rep.pitchCorrectionsDegrees)
        }
        XCTAssertEqual(result.rowCoverage[180], 1, accuracy: 1e-6)

        // Compare the horizon band with the world itself: pose errors of about
        // a degree would otherwise show up as doubled blobs.
        var sumErr: Float = 0
        var count = 0
        for y in stride(from: 150, to: 210, by: 3) {
            for x in stride(from: 0, to: 720, by: 3) {
                let d = result.layout.direction(column: x, row: y)
                let expected = Self.worldLuma(d) * 255
                let got = Float(result.image.pixel(x: x, y: y).r)
                sumErr += abs(expected - got)
                count += 1
            }
        }
        let meanErr = sumErr / Float(count)
        XCTAssertLessThan(meanErr, 6, "mean abs error \(meanErr)")

        let plain = ProjectionStitcher.stitch(shots: shots, options: { var o = StitchOptions.plain; o.outputWidth = 720; return o }())
        Self.dump(plain.image, name: "plain")
        var plainErr: Float = 0
        for y in stride(from: 150, to: 210, by: 3) {
            for x in stride(from: 0, to: 720, by: 3) {
                let d = plain.layout.direction(column: x, row: y)
                plainErr += abs(Self.worldLuma(d) * 255 - Float(plain.image.pixel(x: x, y: y).r))
            }
        }
        XCTAssertLessThan(meanErr, plainErr / Float(count) * 0.6, "refined stitch should beat pose-only stitch")
    }

    /// Largest brightness jump along a row, over 6 columns, beyond what the world itself has.
    private static func worstStep(_ result: StitchResult, row: Int) -> Float {
        var worst: Float = 0
        let w = result.image.width
        for x in 4..<(w - 4) {
            let got = Float(result.image.pixel(x: x + 3, y: row).r) - Float(result.image.pixel(x: x - 3, y: row).r)
            let dA = result.layout.direction(column: x + 3, row: row)
            let dB = result.layout.direction(column: x - 3, row: row)
            let expected = (worldLuma(dA) - worldLuma(dB)) * 255
            worst = max(worst, abs(got - expected))
        }
        return worst
    }

    func testSmoothSkyGetsWideCrossfadeAndTextureStaysSharp() {
        var shots: [StitchShot] = []
        for k in 0..<6 {
            var s = Self.shot(rotation: Self.pose(yaw: Float(k) * 60, pitch: 0))
            // Brightness ramps across each frame, as a sky grading towards the
            // sun does, so neighbours disagree most where they meet.
            let w = s.image.width, h = s.image.height
            for y in 0..<h {
                for x in 0..<w {
                    let rx = (Float(x) - Float(w) / 2) / (Float(w) / 2)
                    let f = 1 + 0.2 * rx
                    let p = s.image.pixel(x: x, y: y)
                    s.image.setPixel(x: x, y: y, r: UInt8(min(255, Float(p.r) * f)), g: UInt8(min(255, Float(p.g) * f)), b: UInt8(min(255, Float(p.b) * f)))
                }
            }
            shots.append(s)
        }
        var options = StitchOptions()
        options.outputWidth = 720
        let adaptive = ProjectionStitcher.stitch(shots: shots, options: options)
        options.refinement.smoothSeamFeatherDegrees = options.seamFeatherDegrees
        let narrow = ProjectionStitcher.stitch(shots: shots, options: options)
        Self.dump(adaptive.image, name: "ramp_adaptive")
        Self.dump(narrow.image, name: "ramp_narrow")

        // Row at pitch 25: smooth sky. The ramp leaves a step at every seam
        // with a narrow crossfade; the adaptive one fades it out.
        let skyRow = 130
        let skyAdaptive = Self.worstStep(adaptive, row: skyRow)
        let skyNarrow = Self.worstStep(narrow, row: skyRow)
        XCTAssertLessThan(skyAdaptive, 24, "sky step with adaptive feather \(skyAdaptive)")
        XCTAssertGreaterThan(skyNarrow, 20, "sky step with narrow feather \(skyNarrow)")
        XCTAssertLessThan(skyAdaptive, skyNarrow * 0.5)

        // Horizon row: textured, so the crossfade must stay narrow and the
        // detail must not be doubled. Compare against the world directly.
        var sumErr: Float = 0
        var count = 0
        for y in stride(from: 170, to: 190, by: 2) {
            for x in stride(from: 0, to: 720, by: 2) {
                let d = adaptive.layout.direction(column: x, row: y)
                sumErr += abs(Self.worldLuma(d) * 255 - Float(adaptive.image.pixel(x: x, y: y).r))
                count += 1
            }
        }
        // The ramp itself costs some error away from the seams; ghosting would cost far more.
        XCTAssertLessThan(sumErr / Float(count), 14, "horizon mean error \(sumErr / Float(count))")
    }
}
