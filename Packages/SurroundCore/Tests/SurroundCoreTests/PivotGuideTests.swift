import XCTest
@testable import SurroundCore

final class PivotGuideTests: XCTestCase {
    func testOffsetIsRelativeToTheWayTheUserFaces() {
        let start = Vec3(1, 1.5, 2)
        // Facing yaw 0 (-Z): moving +X is to the right.
        var o = PivotGuide.offset(start: start, position: start + Vec3(0.2, 0, 0), heading: Vec3(0, 0, -1))
        XCTAssertEqual(o.distance, 0.2, accuracy: 1e-5)
        XCTAssertEqual(o.right, 0.2, accuracy: 1e-5)
        XCTAssertEqual(o.forward, 0, accuracy: 1e-5)
        // Facing yaw 90 (+X): the same movement is now forward.
        o = PivotGuide.offset(start: start, position: start + Vec3(0.2, 0, 0), heading: Vec3(1, 0, 0))
        XCTAssertEqual(o.forward, 0.2, accuracy: 1e-5)
        XCTAssertEqual(o.right, 0, accuracy: 1e-5)
        // Facing yaw 90, moving +Z (south) is to the right.
        o = PivotGuide.offset(start: start, position: start + Vec3(0, 0, 0.1), heading: Vec3(1, 0, 0))
        XCTAssertEqual(o.right, 0.1, accuracy: 1e-5)
        o = PivotGuide.offset(start: start, position: start + Vec3(0, -0.15, 0), heading: Vec3(0, 0, -1))
        XCTAssertEqual(o.up, -0.15, accuracy: 1e-5)
    }

    func testTurningOnTheSpotDriftsByTheDiameter() {
        // Lens 25 cm in front of the body's axis, turning through 180 degrees.
        let axis = Vec3(0, 1.4, 0)
        let lens = { (yaw: Float) -> Vec3 in axis + CapturePlan.direction(yawDegrees: yaw, pitchDegrees: 0) * 0.25 }
        let positions = stride(from: Float(0), through: 330, by: 30).map(lens)
        XCTAssertEqual(PivotGuide.maxDrift(from: lens(0), positions: positions), 0.5, accuracy: 0.01)
    }

    func testHeadingIsUndefinedWhenLookingStraightDown() {
        let down = RingRefinement.corrected(rotation: .identity, yawDegrees: 30, pitchDegrees: -89)
        XCTAssertNil(PivotGuide.heading(of: down))
        let level = RingRefinement.corrected(rotation: .identity, yawDegrees: 90, pitchDegrees: 0)
        let h = PivotGuide.heading(of: level)
        XCTAssertEqual(h?.x ?? 0, 1, accuracy: 1e-4)
    }

    /// The owner's hilltop sphere of 26 September: distance from the first
    /// shot in metres and the pitch each shot was taken at. Shots 4 and 5
    /// are ARKit's position wandering while it looked at the bright sky.
    func testIgnoresReadingsTakenWhileTrackingLookedAtTheSky() {
        let readings: [(Float, Float)] = [(0, 0), (0.17, -40), (0.32, -87), (0.16, 38), (0.97, 89), (1.80, 38),
                                          (0.51, -1), (0.18, -40), (0.17, 0), (0.23, 40)]
        XCTAssertFalse(PivotGuide.isReliable(distance: 0.97, pitchDegrees: 89))
        XCTAssertFalse(PivotGuide.isReliable(distance: 1.80, pitchDegrees: 38))
        XCTAssertTrue(PivotGuide.isReliable(distance: 0.51, pitchDegrees: -1))
        let start = Vec3(0, 1.5, 0)
        let shots = readings.map { (position: start + Vec3($0.0, 0, 0), pitchDegrees: $0.1) }
        XCTAssertEqual(PivotGuide.maxReliableDrift(from: start, shots: shots) ?? 0, 0.51, accuracy: 1e-5)
        XCTAssertNil(PivotGuide.maxReliableDrift(from: start, shots: [(start + Vec3(0, 2, 0), 10)]))
    }

    private func offset(right: Float, forward: Float, up: Float = 0) -> PivotOffset {
        PivotOffset(distance: (right * right + forward * forward + up * up).squareRoot(), right: right, forward: forward, up: up)
    }

    func testInstructionNamesTheWayBack() {
        // Drifted ahead and to the right: step back and to the left, arrow behind-left.
        var i = PivotGuide.instruction(for: offset(right: 0.2, forward: 0.25))
        XCTAssertEqual(i?.text, "Step back and to the left")
        XCTAssertEqual(i?.arrowDegrees ?? 0, Angle.degrees(atan2(-0.2, -0.25)), accuracy: 0.01)
        // Mostly sideways: the small forward part is not mentioned.
        i = PivotGuide.instruction(for: offset(right: -0.3, forward: 0.05))
        XCTAssertEqual(i?.text, "Step to the right")
        XCTAssertEqual(i?.arrowDegrees ?? 0, 99.5, accuracy: 0.5)  // right and a little behind
        i = PivotGuide.instruction(for: offset(right: 0.02, forward: -0.28))
        XCTAssertEqual(i?.text, "Step forward")
        // Close enough, or only a height change: nothing to say.
        XCTAssertNil(PivotGuide.instruction(for: offset(right: 0.05, forward: 0.05)))
        XCTAssertNil(PivotGuide.instruction(for: offset(right: 0, forward: 0.01, up: -0.3)))
    }

    func testTipsForLeaningIntoATilt() {
        XCTAssertEqual(PivotGuide.instruction(for: offset(right: 0, forward: 0.3), pitchDegrees: -40)?.tip,
                       "Tilt the phone, don't lean forward")
        XCTAssertEqual(PivotGuide.instruction(for: offset(right: 0, forward: -0.3), pitchDegrees: 40)?.tip,
                       "Tilt the phone, don't lean back")
        XCTAssertNil(PivotGuide.instruction(for: offset(right: 0, forward: 0.3), pitchDegrees: 0)?.tip)
    }

    func testHoldHasHysteresisAndIgnoresUntrustedReadings() {
        let far = offset(right: 0.26, forward: 0)
        let between = offset(right: 0.235, forward: 0)
        let near = offset(right: 0.2, forward: 0)
        XCTAssertTrue(PivotGuide.holdsCapture(far, isReliable: true, wasHolding: false))
        XCTAssertFalse(PivotGuide.holdsCapture(between, isReliable: true, wasHolding: false))
        XCTAssertTrue(PivotGuide.holdsCapture(between, isReliable: true, wasHolding: true))
        XCTAssertFalse(PivotGuide.holdsCapture(near, isReliable: true, wasHolding: true))
        XCTAssertFalse(PivotGuide.holdsCapture(far, isReliable: false, wasHolding: true))
    }
}
