import Dispatch
import Foundation

/// Which shot owns each cell of a low-resolution map of the sphere, with the
/// runner-up and the distance to the nearest boundary so the compositor can
/// crossfade. Cells nobody covers have owner -1.
public struct OwnershipMap: Sendable {
    public let layout: EquirectangularLayout
    public var owner: [Int16]
    public var neighbour: [Int16]
    /// Distance to the nearest cell with a different owner, in cells, capped
    /// at the crossfade radius.
    public var distance: [Float]
    public let featherCells: Float

    public var width: Int { layout.width }
    public var height: Int { layout.height }
}

/// Seams for a multi-ring capture. Nearest optical axis decides ownership
/// first; then, for every pair of shots that share a boundary, the boundary
/// is moved to where the two shots disagree least by a minimum cut over the
/// band where those two are the nearest candidates. A cut runs along edges
/// and through featureless areas and away from anything parallax has moved,
/// so a misregistered object ends up wholly in one shot instead of split.
public enum SphereSeams {
    /// Cells closer than this to the nearest-axis boundary are free for the
    /// cut to reassign; beyond it a cell is pinned to its nearest shot.
    static let freeBandRadians: Float = Angle.radians(10)

    public static func compute(shots: [StitchShot], rotations: [Mat3], gains: [Float],
                               degreesPerPixel: Float = 0.35, featherDegrees: Float = 2) -> OwnershipMap {
        let layout = EquirectangularLayout(width: max(64, Int((360 / degreesPerPixel).rounded())))
        let w = layout.width
        let h = layout.height
        let n = shots.count
        let projectors = (0..<n).map { ShotProjector(shot: shots[$0], rotation: rotations[$0]) }

        // 1. Per cell: the two nearest visible shots, their angles, and their luma.
        var first = [Int16](repeating: -1, count: w * h)
        var second = [Int16](repeating: -1, count: w * h)
        var gap = [Float](repeating: 0, count: w * h)
        var lumaFirst = [Float](repeating: 0, count: w * h)
        var lumaSecond = [Float](repeating: 0, count: w * h)
        let sinYaw = (0..<w).map { sin(Angle.radians(layout.yawDegrees(forColumn: Float($0) + 0.5))) }
        let cosYaw = (0..<w).map { cos(Angle.radians(layout.yawDegrees(forColumn: Float($0) + 0.5))) }
        withPixelPointers(shots.map { $0.image }) { sources in
            first.withUnsafeMutableBufferPointer { firstBuf in
            second.withUnsafeMutableBufferPointer { secondBuf in
            gap.withUnsafeMutableBufferPointer { gapBuf in
            lumaFirst.withUnsafeMutableBufferPointer { l1Buf in
            lumaSecond.withUnsafeMutableBufferPointer { l2Buf in
                let cell = CellWork(w: w, h: h, layout: layout, projectors: projectors, gains: gains, sources: sources,
                                    sinYaw: sinYaw, cosYaw: cosYaw,
                                    first: firstBuf.baseAddress!, second: secondBuf.baseAddress!, gap: gapBuf.baseAddress!,
                                    lumaFirst: l1Buf.baseAddress!, lumaSecond: l2Buf.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: h) { y in cell.row(y) }
            }}}}}
        }

        // 2. Cells grouped by their unordered nearest pair.
        var owner = first
        var regions: [Int32: [Int32]] = [:]
        for p in 0..<(w * h) where first[p] >= 0 && second[p] >= 0 {
            let a = min(first[p], second[p])
            let b = max(first[p], second[p])
            regions[Int32(a) << 16 | Int32(b), default: []].append(Int32(p))
        }

        // 3. One cut per pair region.
        let pairRegions = regions.map { (i: Int16($0.key >> 16), j: Int16($0.key & 0xFFFF), cells: $0.value) }
        var results = [[(Int32, Int16)]](repeating: [], count: pairRegions.count)
        results.withUnsafeMutableBufferPointer { out in
            let slots = ResultSlots(base: out.baseAddress!)
            let work = CutWork(w: w, h: h, first: first, second: second, gap: gap, lumaFirst: lumaFirst, lumaSecond: lumaSecond)
            DispatchQueue.concurrentPerform(iterations: pairRegions.count) { k in
                let region = pairRegions[k]
                slots.base[k] = work.cut(i: region.i, j: region.j, cells: region.cells)
            }
        }
        for assignments in results {
            for (p, label) in assignments { owner[Int(p)] = label }
        }

        // 4. Runner-up and distance to the nearest boundary, for the crossfade.
        let featherCells = max(1, featherDegrees / degreesPerPixel / 2)
        let radius = Int(featherCells.rounded(.up))
        var neighbour = [Int16](repeating: -1, count: w * h)
        var distance = [Float](repeating: featherCells, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x
                let me = owner[p]
                guard me >= 0 else { continue }
                var best = featherCells
                var bestLabel: Int16 = -1
                for dy in -radius...radius {
                    let yy = y + dy
                    guard yy >= 0, yy < h else { continue }
                    for dx in -radius...radius {
                        let xx = ((x + dx) % w + w) % w
                        let other = owner[yy * w + xx]
                        guard other != me, other >= 0 else { continue }
                        let d = (Float(dx * dx + dy * dy)).squareRoot()
                        if d < best {
                            best = d
                            bestLabel = other
                        }
                    }
                }
                distance[p] = best
                neighbour[p] = bestLabel
            }
        }
        return OwnershipMap(layout: layout, owner: owner, neighbour: neighbour, distance: distance, featherCells: featherCells)
    }

    // MARK: Cells

    private struct CellWork: @unchecked Sendable {
        let w: Int, h: Int
        let layout: EquirectangularLayout
        let projectors: [ShotProjector]
        let gains: [Float]
        let sources: [UnsafePointer<UInt8>]
        let sinYaw: [Float], cosYaw: [Float]
        let first: UnsafeMutablePointer<Int16>
        let second: UnsafeMutablePointer<Int16>
        let gap: UnsafeMutablePointer<Float>
        let lumaFirst: UnsafeMutablePointer<Float>
        let lumaSecond: UnsafeMutablePointer<Float>

        func row(_ y: Int) {
            let pitch = Angle.radians(layout.pitchDegrees(forRow: Float(y) + 0.5))
            let sp = sin(pitch), cp = cos(pitch)
            for x in 0..<w {
                let d = Vec3(sinYaw[x] * cp, sp, -cosYaw[x] * cp)
                var a1 = Float.greatestFiniteMagnitude, a2 = Float.greatestFiniteMagnitude
                var i1 = -1, i2 = -1
                var uv1: (u: Float, v: Float) = (0, 0), uv2: (u: Float, v: Float) = (0, 0)
                for i in 0..<projectors.count {
                    guard let uv = projectors[i].project(d) else { continue }
                    let cosine = max(-1, min(1, d.dot(projectors[i].forward)))
                    let angle = (2 * (1 - cosine)).squareRoot()
                    if angle < a1 {
                        a2 = a1; i2 = i1; uv2 = uv1
                        a1 = angle; i1 = i; uv1 = uv
                    } else if angle < a2 {
                        a2 = angle; i2 = i; uv2 = uv
                    }
                }
                let p = y * w + x
                first[p] = Int16(i1)
                second[p] = Int16(i2)
                gap[p] = i2 >= 0 ? a2 - a1 : Float.greatestFiniteMagnitude
                if i1 >= 0 {
                    let pr = projectors[i1]
                    lumaFirst[p] = PixelSampling.luma(PixelSampling.bilinearRGB(sources[i1], width: pr.width, height: pr.height, u: uv1.u, v: uv1.v)) * gains[i1]
                }
                if i2 >= 0 {
                    let pr = projectors[i2]
                    lumaSecond[p] = PixelSampling.luma(PixelSampling.bilinearRGB(sources[i2], width: pr.width, height: pr.height, u: uv2.u, v: uv2.v)) * gains[i2]
                }
            }
        }
    }

    // MARK: Cuts

    private struct ResultSlots: @unchecked Sendable {
        let base: UnsafeMutablePointer<[(Int32, Int16)]>
    }

    private struct CutWork: @unchecked Sendable {
        let w: Int, h: Int
        let first: [Int16]
        let second: [Int16]
        let gap: [Float]
        let lumaFirst: [Float]
        let lumaSecond: [Float]

        /// How much shots i and j disagree at cell p.
        func disagreement(_ p: Int) -> Float {
            abs(lumaFirst[p] - lumaSecond[p])
        }

        /// Labels for the cells where i and j are the two nearest shots. Cells
        /// well inside either territory are pinned; the band between is cut
        /// where the two shots disagree least. Empty when the region is too
        /// small to have a band, in which case nearest-axis labels stand.
        func cut(i: Int16, j: Int16, cells: [Int32]) -> [(Int32, Int16)] {
            guard cells.count >= 16 else { return [] }
            var index = [Int32: Int32]()
            index.reserveCapacity(cells.count)
            for (k, p) in cells.enumerated() { index[p] = Int32(k) }

            var cut = MinCut(count: cells.count)
            var sources = 0, sinks = 0
            for (k, pp) in cells.enumerated() {
                let p = Int(pp)
                let x = p % w, y = p / w
                let mine = first[p]
                // Pinned deep inside a territory, or where the region touches a
                // cell that already belongs to i or j, so the cut stays continuous
                // with the surrounding ownership.
                var pinnedTo: Int16 = -1
                if gap[p] > freeBandRadians {
                    pinnedTo = mine
                }
                let neighbours = [(x + 1) % w + y * w, ((x - 1 + w) % w) + y * w, y > 0 ? p - w : -1, y + 1 < h ? p + w : -1]
                for q in neighbours where q >= 0 {
                    if let qk = index[Int32(q)] {
                        // Link to a region neighbour once, from the lower index.
                        if Int(qk) > k {
                            let cost = disagreement(p) + disagreement(q) + 0.002
                            cut.link(k, Int(qk), capacity: cost)
                        }
                    } else if pinnedTo < 0 {
                        let outside = first[q]
                        if outside == i || outside == j { pinnedTo = outside }
                    }
                }
                if pinnedTo == i {
                    cut.tieToSource(k)
                    sources += 1
                } else if pinnedTo == j {
                    cut.tieToSink(k)
                    sinks += 1
                }
            }
            guard sources > 0, sinks > 0 else { return [] }
            let side = cut.sourceSide()
            var out: [(Int32, Int16)] = []
            out.reserveCapacity(cells.count)
            for (k, p) in cells.enumerated() {
                out.append((p, side[k] ? i : j))
            }
            return out
        }
    }

    private static func withPixelPointers<T>(_ images: [RGBAImage],
                                             _ collected: [UnsafePointer<UInt8>] = [],
                                             _ body: ([UnsafePointer<UInt8>]) -> T) -> T {
        if collected.count == images.count { return body(collected) }
        return images[collected.count].pixels.withUnsafeBufferPointer { buf in
            withPixelPointers(images, collected + [buf.baseAddress!], body)
        }
    }
}
