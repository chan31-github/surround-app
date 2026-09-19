import XCTest
@testable import SurroundCore

final class SphereRefinementTests: XCTestCase {
    /// The test camera: 240x180 at f=160 is 73.7 degrees across width and
    /// 58.7 across height; in the plan the short side spans yaw.
    private static let fovYaw: Float = 58.7
    private static let fovPitch: Float = 73.7

    func testSolveFitsConsistentAndInconsistentGraphs() {
        // Triangle with consistent offsets: exact.
        let exact = SphereRefinement.solve(count: 3, pairs: [(0, 1, 2, 1), (1, 2, 3, 1), (0, 2, 5, 1)], anchor: 0, fixed: [])
        // The light ridge that keeps unmeasured nodes in place shrinks these by 0.1%.
        XCTAssertEqual(exact[0], 0, accuracy: 1e-2)
        XCTAssertEqual(exact[1], 2, accuracy: 1e-2)
        XCTAssertEqual(exact[2], 5, accuracy: 1e-2)

        // Inconsistent closure is spread by weight. Minimising
        // 10(c1-2)^2 + 10(c2-c1-2)^2 + (c2-1)^2 gives c1 = 1.75, c2 = 3.5.
        let fit = SphereRefinement.solve(count: 3, pairs: [(0, 1, 2, 10), (1, 2, 2, 10), (0, 2, 1, 1)], anchor: 0, fixed: [])
        XCTAssertEqual(fit[1], 1.75, accuracy: 0.02)
        XCTAssertEqual(fit[2], 3.5, accuracy: 0.02)

        // A node nobody measured stays at zero; a fixed node too.
        let sparse = SphereRefinement.solve(count: 4, pairs: [(0, 1, 1, 1), (1, 3, 1, 1)], anchor: 0, fixed: [3])
        XCTAssertEqual(sparse[2], 0, accuracy: 1e-6)
        XCTAssertEqual(sparse[3], 0, accuracy: 1e-6)
    }

    /// A full sphere plan photographed at perturbed poses but labelled with
    /// the nominal ones. Rendering is slow in debug builds, so it is shared.
    private struct PerturbedSphere {
        let plan: CapturePlan
        let shots: [StitchShot]
        let yawErrors: [Float]
        let pitchErrors: [Float]
    }

    private static let perturbed: PerturbedSphere = {
        let plan = CapturePlan.sphere(startYawDegrees: 0, fovAcrossYawDegrees: fovYaw, fovAcrossPitchDegrees: fovPitch)
        var seed: UInt32 = 99
        func noise(_ scale: Float) -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed >> 8) / Float(1 << 24) * 2 - 1) * scale
        }
        var yawErrors: [Float] = []
        var pitchErrors: [Float] = []
        var shots: [StitchShot] = []
        for (k, target) in plan.targets.enumerated() {
            let polar = abs(target.pitchDegrees) > 89
            // The front shot is the anchor and keeps whatever pose it has; a
            // true pose there makes the corrections absolute, so the stitch
            // can be compared with the world directly.
            let dy = k == 0 ? 0 : noise(1.5)
            let dp = polar || k == 0 ? 0 : noise(1.0)
            yawErrors.append(dy)
            pitchErrors.append(dp)
            let truePose = RingRefinementTests.pose(yaw: target.yawDegrees + dy, pitch: target.pitchDegrees + dp)
            var shot = RingRefinementTests.shot(rotation: truePose, texturedSky: true)
            shot.rotation = RingRefinementTests.pose(yaw: target.yawDegrees, pitch: target.pitchDegrees)
            shots.append(shot)
        }
        return PerturbedSphere(plan: plan, shots: shots, yawErrors: yawErrors, pitchErrors: pitchErrors)
    }()

    /// Coarser analysis than the app's default so debug test runs stay
    /// short. Two passes are kept: cross-ring pairs mix yaw and pitch, and
    /// the second pass is what removes the part the linear solve misses.
    private static var quickOptions: RingRefinementOptions {
        var o = RingRefinementOptions()
        o.degreesPerPixel = 0.5
        o.passes = 2
        return o
    }

    func testRecoversPerturbedSpherePoses() {
        let plan = Self.perturbed.plan
        let shots = Self.perturbed.shots
        let yawErrors = Self.perturbed.yawErrors
        let pitchErrors = Self.perturbed.pitchErrors
        XCTAssertFalse(RingRefinement.isSingleRing(shots))

        let refined = SphereRefinement.refine(shots: shots, options: Self.quickOptions)
        let report = refined.report
        let accepted = report.pairs.filter { $0.accepted }
        XCTAssertGreaterThan(accepted.count, shots.count, "every shot should have neighbours: \(accepted.count) pairs")
        XCTAssertLessThan(report.residualYawDegrees, 0.5)
        XCTAssertLessThan(report.residualPitchDegrees, 0.5)

        // Corrections are relative to the anchor, the horizon front (target 0).
        for (k, target) in plan.targets.enumerated() where abs(target.pitchDegrees) < 89 {
            XCTAssertEqual(report.yawCorrectionsDegrees[k], yawErrors[k] - yawErrors[0], accuracy: 0.4, "yaw of shot \(k)")
            XCTAssertEqual(report.pitchCorrectionsDegrees[k], pitchErrors[k] - pitchErrors[0], accuracy: 0.4, "pitch of shot \(k)")
        }
        for (k, target) in plan.targets.enumerated() where abs(target.pitchDegrees) > 89 {
            XCTAssertEqual(report.pitchCorrectionsDegrees[k], 0)
            XCTAssertEqual(report.yawCorrectionsDegrees[k], yawErrors[k] - yawErrors[0], accuracy: 0.6, "yaw of pole shot \(k)")
        }
    }

    func testSphereStitchIsSharperThanPlainProjection() {
        let shots = Self.perturbed.shots
        var options = StitchOptions()
        options.outputWidth = 720
        options.refinement = Self.quickOptions
        let refined = ProjectionStitcher.stitch(shots: shots, options: options)
        XCTAssertNotNil(refined.sphereRefinement)
        XCTAssertNil(refined.refinement)
        var plainOptions = StitchOptions.plain
        plainOptions.outputWidth = 720
        let plain = ProjectionStitcher.stitch(shots: shots, options: plainOptions)
        RingRefinementTests.dump(refined.image, name: "sphere_refined")
        RingRefinementTests.dump(plain.image, name: "sphere_plain")

        func meanError(_ result: StitchResult) -> Float {
            var sum: Float = 0
            var count = 0
            for y in stride(from: 40, to: 320, by: 4) {
                for x in stride(from: 0, to: 720, by: 4) {
                    let d = result.layout.direction(column: x, row: y)
                    sum += abs(RingRefinementTests.worldLuma(d, texturedSky: true) * 255 - Float(result.image.pixel(x: x, y: y).r))
                    count += 1
                }
            }
            return sum / Float(count)
        }
        let refinedError = meanError(refined)
        let plainError = meanError(plain)
        XCTAssertLessThan(refinedError, plainError * 0.6, "refined \(refinedError) vs plain \(plainError)")
        XCTAssertEqual(refined.rowCoverage[180], 1, accuracy: 1e-6)
        XCTAssertEqual(refined.coveredPitchRangeDegrees?.upperBound ?? 0, 90, accuracy: 1)
    }
}
