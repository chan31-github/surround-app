import XCTest
@testable import SurroundCore

final class CapturePlanTests: XCTestCase {
    func testRingCountFromFOV() {
        // iPhone main camera in portrait: about 49.6 degrees across the short side.
        let plan = CapturePlan.ring(startYawDegrees: 10, fovAcrossYawDegrees: 49.6, minimumOverlap: 0.4)
        XCTAssertEqual(plan.targets.count, 13)
        XCTAssertEqual(plan.yawStepDegrees, 360.0 / 13, accuracy: 1e-4)
        XCTAssertEqual(plan.targets.first?.yawDegrees ?? 0, 10, accuracy: 1e-4)
        // Neighbouring targets overlap by at least the minimum.
        XCTAssertLessThanOrEqual(plan.yawStepDegrees, 49.6 * 0.6 + 1e-3)
        // Last target is one step short of wrapping back to the start.
        let last = plan.targets.last!.yawDegrees
        XCTAssertEqual(Angle.wrapDegrees180(last + plan.yawStepDegrees - 10), 0, accuracy: 1e-3)
    }

    func testRingTargetsAreOnHorizon() {
        let plan = CapturePlan.ring(startYawDegrees: 0, fovAcrossYawDegrees: 60)
        for t in plan.targets {
            XCTAssertEqual(t.pitchDegrees, 0)
            XCTAssertEqual(t.direction.length, 1, accuracy: 1e-5)
        }
    }

    func testSphereHasPolesAndMoreThanOneRing() {
        let plan = CapturePlan.sphere(startYawDegrees: 0, fovAcrossYawDegrees: 49.6, fovAcrossPitchDegrees: 69.4)
        XCTAssertTrue(plan.targets.contains { $0.pitchDegrees == 90 })
        XCTAssertTrue(plan.targets.contains { $0.pitchDegrees == -90 })
        let pitches = Set(plan.targets.map { $0.pitchDegrees })
        XCTAssertGreaterThanOrEqual(pitches.count, 4)
        XCTAssertEqual(plan.targets.first?.pitchDegrees, 0)
        XCTAssertGreaterThan(plan.targets.count, 13)
        XCTAssertLessThan(plan.targets.count, 45)
    }

    func testAlignmentBecomesReadyAfterSettling() {
        var t = AlignmentThresholds()
        t.settleSeconds = 0.25
        let evaluator = AlignmentEvaluator(thresholds: t)
        let target = CaptureTarget(id: 0, yawDegrees: 0, pitchDegrees: 0)
        let pose = CameraPose(rotation: .identity)

        let s0 = evaluator.evaluate(pose: pose, target: target, timestamp: 0)
        XCTAssertTrue(s0.isAligned)
        XCTAssertTrue(s0.isSteady)
        XCTAssertFalse(s0.isReadyToCapture)

        let s1 = evaluator.evaluate(pose: pose, target: target, timestamp: 0.3)
        XCTAssertTrue(s1.isReadyToCapture)

        evaluator.markCaptured(at: 0.3)
        let s2 = evaluator.evaluate(pose: pose, target: target, timestamp: 0.6)
        XCTAssertFalse(s2.isReadyToCapture, "minimum interval between captures not elapsed")
        let s3 = evaluator.evaluate(pose: pose, target: target, timestamp: 1.5)
        XCTAssertTrue(s3.isReadyToCapture)
    }

    func testAlignmentDeltasPointTowardsTarget() {
        let evaluator = AlignmentEvaluator()
        let target = CaptureTarget(id: 0, yawDegrees: 30, pitchDegrees: 10)
        let pose = CameraPose(rotation: .identity)
        let s = evaluator.evaluate(pose: pose, target: target, timestamp: 0)
        XCTAssertEqual(s.deltaYawDegrees, 30, accuracy: 1e-3)
        XCTAssertEqual(s.deltaPitchDegrees, 10, accuracy: 1e-3)
        XCTAssertFalse(s.isAligned)
    }

    func testFastMotionIsNotSteady() {
        let evaluator = AlignmentEvaluator()
        let target = CaptureTarget(id: 0, yawDegrees: 0, pitchDegrees: 0)
        _ = evaluator.evaluate(pose: CameraPose(rotation: Mat3.rotationY(Angle.radians(5))), target: target, timestamp: 0)
        let s = evaluator.evaluate(pose: CameraPose(rotation: .identity), target: target, timestamp: 0.1)
        XCTAssertGreaterThan(s.angularSpeedDegreesPerSecond, 40)
        XCTAssertFalse(s.isSteady)
    }

    func testSphereIsOneTurnStartingAtTheHorizonFront() {
        let plan = CapturePlan.sphere(startYawDegrees: 8.4, fovAcrossYawDegrees: 53, fovAcrossPitchDegrees: 67)
        let targets = plan.targets
        XCTAssertEqual(targets.count, 32)
        XCTAssertEqual(Array(targets.map { $0.id }), Array(0..<targets.count))

        // Exposure locks on the first shot, so it must be the horizon front.
        XCTAssertEqual(targets[0].pitchDegrees, 0)
        XCTAssertEqual(targets[0].yawDegrees, 8.4, accuracy: 1e-4)

        // The first column goes down to the nadir, then up to the zenith.
        let firstColumnPitches = targets.prefix(5).map { $0.pitchDegrees }
        XCTAssertEqual(firstColumnPitches, [0, -40.2, -90, 40.2, 90])

        // Total yaw travel between consecutive non-pole targets is one turn
        // plus the wiggle from rings whose columns do not line up exactly
        // (at most half a step each way per column), not one turn per ring.
        var travel: Float = 0
        var previous: Float?
        for t in targets where abs(t.pitchDegrees) < 89 {
            if let p = previous { travel += abs(Angle.wrapDegrees180(t.yawDegrees - p)) }
            previous = t.yawDegrees
        }
        let columns = Float(targets.filter { $0.pitchDegrees == 0 }.count)
        XCTAssertLessThan(travel, 360 + columns * plan.yawStepDegrees / 2, "yaw travel \(travel)")
        XCTAssertGreaterThan(travel, 300)

        // Every horizon column is visited in yaw order.
        let horizon = targets.filter { $0.pitchDegrees == 0 }
        for (i, t) in horizon.enumerated() {
            XCTAssertEqual(Angle.wrapDegrees360(t.yawDegrees - 8.4), Float(i) * plan.yawStepDegrees, accuracy: 1e-3)
        }

        // Consecutive targets never jump more than one column in yaw.
        for (a, b) in zip(targets, targets.dropFirst()) where abs(a.pitchDegrees) < 89 && abs(b.pitchDegrees) < 89 {
            XCTAssertLessThanOrEqual(abs(Angle.wrapDegrees180(b.yawDegrees - a.yawDegrees)), plan.yawStepDegrees * 1.5 + 1e-3)
        }
    }
}
