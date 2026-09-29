import XCTest
@testable import SurroundCore

final class TwoBandTests: XCTestCase {
    /// A sphere of shots whose brightness ramps across each frame, as the
    /// sky does near the sun: no gain per shot or radial falloff can match
    /// neighbours all along a boundary, so a cut leaves a step unless the
    /// coarse layers are blended.
    private static func rampedSphere() -> [StitchShot] {
        let plan = CapturePlan.sphere(startYawDegrees: 0, fovAcrossYawDegrees: 58.7, fovAcrossPitchDegrees: 73.7)
        return plan.targets.map { target in
            var shot = RingRefinementTests.shot(rotation: RingRefinementTests.pose(yaw: target.yawDegrees, pitch: target.pitchDegrees))
            let w = shot.image.width
            for y in 0..<shot.image.height {
                for x in 0..<w {
                    let f = 1 + 0.25 * (Float(x) - Float(w) / 2) / (Float(w) / 2)
                    let p = shot.image.pixel(x: x, y: y)
                    shot.image.setPixel(x: x, y: y, r: UInt8(min(255, Float(p.r) * f)),
                                        g: UInt8(min(255, Float(p.g) * f)), b: UInt8(min(255, Float(p.b) * f)))
                }
            }
            return shot
        }
    }

    /// Largest jump between neighbouring pixels in the smooth sky rows,
    /// where the world itself changes by well under a level per pixel.
    private static func worstSkyJump(_ result: StitchResult) -> Int {
        var worst = 0
        let w = result.image.width
        for row in stride(from: 40, to: 100, by: 3) {  // pitch 70 to 40 degrees
            for x in 0..<(w - 1) {
                let a = Int(result.image.pixel(x: x, y: row).r)
                let b = Int(result.image.pixel(x: x + 1, y: row).r)
                worst = max(worst, abs(a - b))
            }
        }
        return worst
    }

    func testCoarseBlendRemovesStepsTheCutWouldLeave() {
        let shots = Self.rampedSphere()
        var options = StitchOptions()
        options.outputWidth = 720
        options.refinement.degreesPerPixel = 0.5
        options.refinement.passes = 1
        let banded = ProjectionStitcher.stitch(shots: shots, options: options)
        options.bandSplitDegrees = 0
        let cut = ProjectionStitcher.stitch(shots: shots, options: options)
        RingRefinementTests.dump(banded.image, name: "twoband_on")
        RingRefinementTests.dump(cut.image, name: "twoband_off")

        let withBands = Self.worstSkyJump(banded)
        let without = Self.worstSkyJump(cut)
        XCTAssertGreaterThan(without, 6, "the test needs a visible step to remove, got \(without)")
        XCTAssertLessThanOrEqual(withBands * 2, without, "bands \(withBands) vs cut \(without)")
    }

    func testCoarseLayerIsTheLocalAverage() {
        var image = RGBAImage.filled(width: 64, height: 32, r: 100, g: 100, b: 100)
        for y in 0..<32 { for x in 32..<64 { image.setPixel(x: x, y: y, r: 200, g: 200, b: 200) } }
        let coarse = ProjectionStitcher.coarseLayer(of: image, factor: 8)
        XCTAssertEqual(coarse.width, 8)
        XCTAssertEqual(coarse.height, 4)
        XCTAssertEqual(Int(coarse.pixel(x: 0, y: 1).r), 100, accuracy: 1)
        XCTAssertEqual(Int(coarse.pixel(x: 7, y: 1).r), 200, accuracy: 1)
        // Softened across the edge, so bilinear sampling has no hard step.
        XCTAssertGreaterThan(Int(coarse.pixel(x: 3, y: 1).r), 100)
        XCTAssertLessThan(Int(coarse.pixel(x: 4, y: 1).r), 200)
    }
}
