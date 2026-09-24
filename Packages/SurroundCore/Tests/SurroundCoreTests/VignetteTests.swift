import XCTest
@testable import SurroundCore

final class VignetteTests: XCTestCase {
    /// Darkens a shot towards its corners by exp(k * r²), r normalised so a
    /// corner is 1: what a lens does, and what the fit has to recover.
    private static func applyVignette(_ shot: inout StitchShot, k: Float) {
        let w = shot.image.width
        let h = shot.image.height
        let cx = shot.intrinsics.cx
        let cy = shot.intrinsics.cy
        let invHalf = 1 / (pow(Float(w) / 2, 2) + pow(Float(h) / 2, 2))
        for y in 0..<h {
            for x in 0..<w {
                let du = Float(x) + 0.5 - cx
                let dv = Float(y) + 0.5 - cy
                let factor = exp(k * (du * du + dv * dv) * invHalf)
                let p = shot.image.pixel(x: x, y: y)
                shot.image.setPixel(x: x, y: y,
                                    r: UInt8(max(0, min(255, Float(p.r) * factor))),
                                    g: UInt8(max(0, min(255, Float(p.g) * factor))),
                                    b: UInt8(max(0, min(255, Float(p.b) * factor))))
            }
        }
    }

    private static func ring(vignette k: Float) -> [StitchShot] {
        (0..<8).map { i in
            var shot = RingRefinementTests.shot(rotation: RingRefinementTests.pose(yaw: Float(i) * 45, pitch: 0),
                                                texturedSky: true)
            if k != 0 { applyVignette(&shot, k: k) }
            return shot
        }
    }

    func testRecoversTheLensFalloffFromOverlaps() {
        var options = RingRefinementOptions()
        options.computeSeams = false
        options.degreesPerPixel = 0.5

        // No falloff: nothing to find.
        XCTAssertEqual(RingRefinement.refine(shots: Self.ring(vignette: 0), options: options).vignetteK, 0, accuracy: 0.02)

        // A 25 percent darkening at the corners, which is a strong but real lens.
        let k: Float = -0.29
        let refined = RingRefinement.refine(shots: Self.ring(vignette: k), options: options)
        XCTAssertEqual(refined.vignetteK, k, accuracy: 0.06, "recovered \(refined.vignetteK) for \(k)")
        // Gains stay near 1: the falloff must not be absorbed into them.
        for gain in refined.gains {
            XCTAssertEqual(gain, 1, accuracy: 0.12)
        }
    }

    func testCorrectionFlattensTheStitchedRing() {
        let k: Float = -0.29
        let shots = Self.ring(vignette: k)
        var options = StitchOptions()
        options.outputWidth = 720
        options.refinement.degreesPerPixel = 0.5
        let corrected = ProjectionStitcher.stitch(shots: shots, options: options)
        options.refinement.compensateVignetting = false
        let uncorrected = ProjectionStitcher.stitch(shots: shots, options: options)

        // Against the world itself, along the textured horizon band.
        func meanError(_ result: StitchResult) -> Float {
            var sum: Float = 0
            var count = 0
            for y in stride(from: 170, to: 190, by: 2) {
                for x in stride(from: 0, to: 720, by: 2) {
                    let d = result.layout.direction(column: x, row: y)
                    sum += abs(RingRefinementTests.worldLuma(d, texturedSky: true) * 255 - Float(result.image.pixel(x: x, y: y).r))
                    count += 1
                }
            }
            return sum / Float(count)
        }
        let with = meanError(corrected)
        let without = meanError(uncorrected)
        XCTAssertLessThan(with, without * 0.8, "corrected \(with) vs uncorrected \(without)")
    }
}
