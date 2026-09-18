import XCTest
@testable import SurroundCore

final class StitcherTests: XCTestCase {
    /// 200x200 image with a 90 degree field of view.
    private func squareShot(rotation: Mat3, r: UInt8, g: UInt8, b: UInt8) -> StitchShot {
        StitchShot(image: RGBAImage.filled(width: 200, height: 200, r: r, g: g, b: b),
                   intrinsics: CameraIntrinsics(fx: 100, fy: 100, cx: 100, cy: 100, width: 200, height: 200),
                   rotation: rotation)
    }

    func testLayoutRoundTrip() {
        let layout = EquirectangularLayout(width: 360)
        XCTAssertEqual(layout.height, 180)
        let centre = layout.direction(column: 180, row: 90)
        XCTAssertEqual(centre.z, -1, accuracy: 1e-2)
        let px = layout.pixel(for: CapturePlan.direction(yawDegrees: 90, pitchDegrees: 45))
        XCTAssertEqual(px.x, 270, accuracy: 1e-3)
        XCTAssertEqual(px.y, 45, accuracy: 1e-3)
    }

    func testSingleShotPaintsFrontOnly() {
        var options = StitchOptions()
        options.outputWidth = 360
        let result = ProjectionStitcher.stitch(shots: [squareShot(rotation: .identity, r: 255, g: 0, b: 0)], options: options)
        XCTAssertEqual(result.image.width, 360)
        XCTAssertEqual(result.image.height, 180)

        let centre = result.image.pixel(x: 180, y: 90)
        XCTAssertGreaterThanOrEqual(centre.r, 250)
        XCTAssertEqual(centre.a, 255)

        let behind = result.image.pixel(x: 0, y: 90)
        XCTAssertEqual(behind.a, 0)

        // Roughly a quarter of the horizon row is covered by a 90 degree shot.
        XCTAssertEqual(result.rowCoverage[90], 0.25, accuracy: 0.03)
        XCTAssertNil(result.coveredPitchRangeDegrees)
    }

    func testRingOfShotsCoversHorizonBand() throws {
        var options = StitchOptions()
        options.outputWidth = 360
        var shots: [StitchShot] = []
        for k in 0..<8 {
            let yaw = Float(k) * 45
            shots.append(squareShot(rotation: Mat3.rotationY(-Angle.radians(yaw)), r: 10, g: 200, b: 30))
        }
        let result = ProjectionStitcher.stitch(shots: shots, options: options)
        XCTAssertEqual(result.rowCoverage[90], 1, accuracy: 1e-6)
        let range = try XCTUnwrap(result.coveredPitchRangeDegrees)
        XCTAssertLessThanOrEqual(range.lowerBound, -30)
        XCTAssertGreaterThanOrEqual(range.upperBound, 30)
        XCTAssertLessThan(range.upperBound, 60)

        for x in stride(from: 0, to: 360, by: 7) {
            let p = result.image.pixel(x: x, y: 90)
            XCTAssertEqual(p.a, 255, "column \(x) should be painted")
            XCTAssertEqual(Int(p.g), 200, accuracy: 2, "column \(x) should be green")
        }
        let zenith = result.image.pixel(x: 180, y: 0)
        XCTAssertEqual(zenith.a, 0)
    }

    func testFillTransparentUsesGradient() {
        var img = RGBAImage(width: 4, height: 4)
        img.setPixel(x: 1, y: 1, r: 9, g: 9, b: 9)
        img.fillTransparentPixels(with: RGBAImage.skyGroundGradient(height: 4))
        XCTAssertEqual(img.pixel(x: 1, y: 1).r, 9)
        XCTAssertEqual(img.pixel(x: 0, y: 0).a, 255)
        XCTAssertGreaterThan(img.pixel(x: 0, y: 0).r, img.pixel(x: 0, y: 3).r)
    }

    func testCoveredRowsPicksLongestRun() {
        let cov: [Float] = [1, 1, 0, 1, 1, 1, 0, 1]
        XCTAssertEqual(ProjectionStitcher.coveredRows(cov, threshold: 0.98), 3...5)
        XCTAssertNil(ProjectionStitcher.coveredRows([0, 0.5], threshold: 0.98))
    }
}
