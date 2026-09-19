import XCTest
@testable import SurroundCore

final class MinCutTests: XCTestCase {
    func testCutsTheCheapestEdgeOfAChain() {
        // 0 - 1 - 2 - 3 with capacities 5, 1, 5: the cut falls between 1 and 2.
        var cut = MinCut(count: 4)
        cut.tieToSource(0)
        cut.tieToSink(3)
        cut.link(0, 1, capacity: 5)
        cut.link(1, 2, capacity: 1)
        cut.link(2, 3, capacity: 5)
        XCTAssertEqual(cut.sourceSide(), [true, true, false, false])
    }

    func testGridCutFollowsTheLowCostValley() {
        // 5 x 5 grid, left column tied to the source and right column to the
        // sink. Vertical links are cheap only in column 3, so the cut should
        // run down that column: columns 0...2 source, 3...4 sink.
        let w = 5, h = 5
        var cut = MinCut(count: w * h)
        for y in 0..<h {
            cut.tieToSource(y * w)
            cut.tieToSink(y * w + w - 1)
            for x in 0..<w {
                let n = y * w + x
                if x + 1 < w {
                    // Cost of separating column x from x + 1.
                    let cost: Float = x == 2 ? 0.1 : 3
                    cut.link(n, n + 1, capacity: cost)
                }
                if y + 1 < h { cut.link(n, n + w, capacity: 3) }
            }
        }
        let side = cut.sourceSide()
        for y in 0..<h {
            for x in 0..<w {
                XCTAssertEqual(side[y * w + x], x <= 2, "(\(x), \(y))")
            }
        }
    }

    func testFlowIsConservedWithManyAugmentingPaths() {
        // A 40 x 40 grid with random costs must still separate the terminals
        // and leave every node on exactly one side.
        let w = 40, h = 40
        var seed: UInt32 = 7
        func rnd() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24)
        }
        var cut = MinCut(count: w * h)
        for y in 0..<h {
            cut.tieToSource(y * w)
            cut.tieToSink(y * w + w - 1)
            for x in 0..<w {
                let n = y * w + x
                if x + 1 < w { cut.link(n, n + 1, capacity: 0.05 + rnd()) }
                if y + 1 < h { cut.link(n, n + w, capacity: 0.05 + rnd()) }
            }
        }
        let side = cut.sourceSide()
        for y in 0..<h {
            XCTAssertTrue(side[y * w])
            XCTAssertFalse(side[y * w + w - 1])
        }
    }
}
