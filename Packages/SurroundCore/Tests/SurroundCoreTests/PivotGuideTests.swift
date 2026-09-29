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
}
