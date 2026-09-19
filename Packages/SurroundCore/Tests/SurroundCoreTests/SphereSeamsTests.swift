import XCTest
@testable import SurroundCore

final class SphereSeamsTests: XCTestCase {
    /// Two shots 40 degrees apart looking at the same textured world, except
    /// that the right-hand shot also contains a bright disc that straddles
    /// the midline between them, as a nearby object moved by parallax would.
    /// The nearest-axis boundary would slice the disc; the cut must keep it
    /// whole, on one side or the other.
    func testCutRoutesAroundAnObjectOnlyOneShotContains() {
        let left = RingRefinementTests.shot(rotation: RingRefinementTests.pose(yaw: -20, pitch: 0), texturedSky: true)
        var right = RingRefinementTests.shot(rotation: RingRefinementTests.pose(yaw: 20, pitch: 0), texturedSky: true)
        let disc = CapturePlan.direction(yawDegrees: -3, pitchDegrees: 0)
        let discRadius = Angle.radians(4)
        let projector = ShotProjector(shot: right)
        for y in 0..<right.image.height {
            for x in 0..<right.image.width {
                let d = projector.direction(u: Float(x) + 0.5, v: Float(y) + 0.5)
                if d.angle(to: disc) < discRadius {
                    right.image.setPixel(x: x, y: y, r: 250, g: 250, b: 250)
                }
            }
        }
        let shots = [left, right]
        let map = SphereSeams.compute(shots: shots, rotations: shots.map { $0.rotation }, gains: [1, 1], degreesPerPixel: 0.5)

        // Cells inside the disc, and how the nearest axis would have split them.
        var owners = Set<Int16>()
        var nearestLeft = 0, nearestRight = 0
        for y in 0..<map.height {
            for x in 0..<map.width {
                let d = map.layout.direction(column: x, row: y)
                guard d.angle(to: disc) < discRadius * 0.9 else { continue }
                owners.insert(map.owner[y * map.width + x])
                if map.layout.yawDegrees(forColumn: Float(x) + 0.5) < 0 { nearestLeft += 1 } else { nearestRight += 1 }
            }
        }
        XCTAssertGreaterThan(nearestLeft, 20)
        XCTAssertGreaterThan(nearestRight, 5, "the disc must straddle the midline for the test to mean anything")
        XCTAssertEqual(owners.count, 1, "the disc was split between shots \(owners)")

        // Away from the disc the boundary still sits near the midline.
        let farRow = map.height / 2 + Int(30 / 0.5)
        var flips = 0
        var previous = map.owner[farRow * map.width]
        for x in 1..<map.width {
            let o = map.owner[farRow * map.width + x]
            if o != previous, o >= 0, previous >= 0 { flips += 1 }
            previous = o
        }
        XCTAssertLessThanOrEqual(flips, 2, "one boundary crossing expected on a quiet row, found \(flips)")
    }

    func testMapCoversWhatTheShotsCover() {
        let plan = CapturePlan.sphere(startYawDegrees: 0, fovAcrossYawDegrees: 58.7, fovAcrossPitchDegrees: 73.7)
        let shots = plan.targets.map { RingRefinementTests.shot(rotation: RingRefinementTests.pose(yaw: $0.yawDegrees, pitch: $0.pitchDegrees), texturedSky: true) }
        let map = SphereSeams.compute(shots: shots, rotations: shots.map { $0.rotation }, gains: shots.map { _ in 1 }, degreesPerPixel: 1)
        XCTAssertEqual(map.width, 360)
        let uncovered = map.owner.filter { $0 < 0 }.count
        XCTAssertEqual(uncovered, 0, "\(uncovered) cells have no owner")
        // Every shot owns something, and distances stay within the feather.
        XCTAssertEqual(Set(map.owner).count, shots.count)
        XCTAssertTrue(map.distance.allSatisfy { $0 >= 0 && $0 <= map.featherCells })
    }
}
