import Foundation

/// Maximum flow on a small directed graph by Dinic's algorithm, used to cut
/// the boundary between two shots where they disagree least. Graphs here are
/// pixel grids of a few tens of thousands of nodes; capacities are floats.
struct MinCut {
    private struct Edge {
        let to: Int
        var capacity: Float
        let reverse: Int
    }

    let nodeCount: Int
    let source: Int
    let sink: Int
    private var adjacency: [[Int]]
    private var edges: [Edge] = []

    /// Nodes 0..<count are ordinary; the source and sink are added after them.
    init(count: Int) {
        nodeCount = count + 2
        source = count
        sink = count + 1
        adjacency = [[Int]](repeating: [], count: nodeCount)
    }

    /// Undirected capacity between two ordinary nodes.
    mutating func link(_ a: Int, _ b: Int, capacity: Float) {
        addEdge(a, b, capacity, capacity)
    }

    mutating func tieToSource(_ node: Int, capacity: Float = .greatestFiniteMagnitude) {
        addEdge(source, node, capacity, 0)
    }

    mutating func tieToSink(_ node: Int, capacity: Float = .greatestFiniteMagnitude) {
        addEdge(node, sink, capacity, 0)
    }

    private mutating func addEdge(_ a: Int, _ b: Int, _ forward: Float, _ backward: Float) {
        adjacency[a].append(edges.count)
        edges.append(Edge(to: b, capacity: forward, reverse: edges.count + 1))
        adjacency[b].append(edges.count)
        edges.append(Edge(to: a, capacity: backward, reverse: edges.count - 1))
    }

    /// Runs the flow and returns, for every ordinary node, whether it stays on
    /// the source side of the minimum cut.
    mutating func sourceSide() -> [Bool] {
        var level = [Int](repeating: -1, count: nodeCount)
        var next = [Int](repeating: 0, count: nodeCount)
        var queue = [Int]()
        queue.reserveCapacity(nodeCount)

        func buildLevels() -> Bool {
            for i in 0..<nodeCount { level[i] = -1 }
            level[source] = 0
            queue.removeAll(keepingCapacity: true)
            queue.append(source)
            var head = 0
            while head < queue.count {
                let u = queue[head]
                head += 1
                for e in adjacency[u] where edges[e].capacity > 1e-6 && level[edges[e].to] < 0 {
                    level[edges[e].to] = level[u] + 1
                    queue.append(edges[e].to)
                }
            }
            return level[sink] >= 0
        }

        // Iterative blocking-flow search so deep paths cannot overflow the stack.
        var path = [Int]()
        while buildLevels() {
            for i in 0..<nodeCount { next[i] = 0 }
            var u = source
            path.removeAll(keepingCapacity: true)
            while true {
                if u == sink {
                    var bottleneck = Float.greatestFiniteMagnitude
                    for e in path { bottleneck = min(bottleneck, edges[e].capacity) }
                    for e in path {
                        edges[e].capacity -= bottleneck
                        edges[edges[e].reverse].capacity += bottleneck
                    }
                    // Back up to just before the first saturated edge.
                    let saturated = path.firstIndex { edges[$0].capacity <= 1e-6 } ?? 0
                    path.removeSubrange(saturated...)
                    u = path.last.map { edges[$0].to } ?? source
                    continue
                }
                var advanced = false
                while next[u] < adjacency[u].count {
                    let e = adjacency[u][next[u]]
                    let v = edges[e].to
                    if edges[e].capacity > 1e-6 && level[v] == level[u] + 1 {
                        path.append(e)
                        u = v
                        advanced = true
                        break
                    }
                    next[u] += 1
                }
                if advanced { continue }
                if u == source { break }
                // Dead end: retreat one step and skip the edge that led here.
                level[u] = -1
                let e = path.removeLast()
                u = path.last.map { edges[$0].to } ?? source
                if next[u] < adjacency[u].count, adjacency[u][next[u]] == e { next[u] += 1 }
            }
        }

        // Reachable from the source in the residual graph.
        var reachable = [Bool](repeating: false, count: nodeCount)
        reachable[source] = true
        queue.removeAll(keepingCapacity: true)
        queue.append(source)
        var head = 0
        while head < queue.count {
            let u = queue[head]
            head += 1
            for e in adjacency[u] where edges[e].capacity > 1e-6 && !reachable[edges[e].to] {
                reachable[edges[e].to] = true
                queue.append(edges[e].to)
            }
        }
        return Array(reachable[0..<(nodeCount - 2)])
    }
}
