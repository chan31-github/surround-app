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
}
