// DagrePosition.swift
//
// Open Grok — Swift port of `dagre_rust::layout::position`
// (third_party/dagre_rust/src/layout/position/{mod,bk}.rs, W8-S2).
//
// Coordinate assignment follows Brandes and Köpf, "Fast and Simple Horizontal
// Coordinate Assignment": align nodes into vertical blocks four different ways
// (up/down x left/right), compact each independently, then average the middle
// two results so long edges come out straight without biasing either side.

/// The block graph used during compaction: node label is unused, edge label is
/// the minimum separation between two blocks.
typealias DagreBlockGraph = Graph<Int, String, Float>

enum DagrePosition {
    /// Assigns final `x`/`y` to every node in `g`.
    static func run(_ g: DagreGraph) {
        let nonCompound = DagreUtil.asNonCompoundGraph(g)

        positionY(nonCompound)
        for (v, x) in positionX(nonCompound) {
            guard let y = nonCompound.node(v)?.y else { continue }
            g.withNode(v) { node in
                node.x = x
                node.y = y
            }
        }
    }

    /// Stacks ranks vertically, each centred within the tallest node on it.
    static func positionY(_ g: DagreGraph) {
        let layering = DagreUtil.buildLayerMatrix(g)
        let rankSeparation = g.graphLabel.rankSeparation ?? 50
        var previousY: Float = 0

        for layer in layering {
            // Upstream truncates heights to integers before taking the maximum;
            // kept so rank spacing matches the reference exactly.
            let maxHeight = Float(layer.compactMap { g.node($0).map { Int($0.height) } }.max() ?? 0)
            for v in layer {
                g.withNode(v) { $0.y = previousY + maxHeight / 2 }
            }
            previousY += maxHeight + rankSeparation
        }
    }

    // MARK: - Conflicts

    typealias ConflictSet = OrderedDictionary<String, OrderedDictionary<String, Bool>>

    static func addConflict(_ conflicts: inout ConflictSet, _ v: String, _ w: String) {
        let (first, second) = v > w ? (w, v) : (v, w)
        conflicts.withValue(forKey: first, default: OrderedDictionary()) { entry in
            entry.insert(true, forKey: second)
        }
    }

    static func hasConflict(_ conflicts: ConflictSet, _ v: String, _ w: String) -> Bool {
        let (first, second) = v > w ? (w, v) : (v, w)
        return conflicts[first]?.containsKey(second) ?? false
    }

    /// Type-1 conflicts: a segment between two real nodes crossing a segment
    /// between two dummies. The dummy chain wins, so the real edge is the one
    /// that must bend.
    static func findType1Conflicts(_ g: DagreGraph, _ layering: [[String]]) -> ConflictSet {
        var conflicts = ConflictSet()

        func visitLayer(_ previousLayer: [String], _ layer: [String]) {
            // Position in the previous layer of the last inner segment seen.
            var k0 = 0
            // How far along this layer crossings have already been checked.
            var scanPosition = 0
            let previousLayerLength = previousLayer.count
            guard let lastNode = layer.last else { return }

            for (i, v) in layer.enumerated() {
                let w = otherInnerSegmentNode(g, v)
                let k1 = w.flatMap { g.node($0)?.order } ?? previousLayerLength

                if w != nil || v == lastNode {
                    for scanNode in layer[scanPosition...i] {
                        for u in g.predecessors(scanNode) ?? [] {
                            guard let uLabel = g.node(u) else { continue }
                            let uPosition = uLabel.order ?? 0
                            let bothDummy = uLabel.dummy != nil && g.node(scanNode)?.dummy != nil
                            if (uPosition < k0 || k1 < uPosition) && !bothDummy {
                                addConflict(&conflicts, u, scanNode)
                            }
                        }
                    }
                    scanPosition = i + 1
                    k0 = k1
                }
            }
        }

        var previousLayer: [String]?
        for layer in layering where !layer.isEmpty {
            if let previous = previousLayer {
                visitLayer(previous, layer)
            }
            previousLayer = layer
        }

        return conflicts
    }

    /// Type-2 conflicts: two dummy segments crossing, which would put an edge
    /// through a cluster wall.
    static func findType2Conflicts(_ g: DagreGraph, _ layering: [[String]]) -> ConflictSet {
        var conflicts = ConflictSet()

        func scan(
            _ south: [String],
            _ southPosition: Int,
            _ southEnd: Int,
            _ previousNorthBorder: Int,
            _ nextNorthBorder: Int
        ) {
            guard southPosition < southEnd else { return }
            for i in southPosition..<min(southEnd, south.count) {
                let v = south[i]
                guard g.node(v)?.dummy != nil else { continue }
                for u in g.predecessors(v) ?? [] {
                    guard let uNode = g.node(u), uNode.dummy != nil else { continue }
                    let order = uNode.order ?? 0
                    if order < previousNorthBorder || order > nextNorthBorder {
                        addConflict(&conflicts, u, v)
                    }
                }
            }
        }

        func visitLayer(_ north: [String], _ south: [String]) {
            var previousNorthPosition = -1
            var nextNorthPosition = -1
            var southPosition = 0

            for (southLookahead, v) in south.enumerated() {
                if g.node(v)?.dummy == .border {
                    let predecessors = g.predecessors(v) ?? []
                    if let first = predecessors.first {
                        nextNorthPosition = g.node(first)?.order ?? 0
                        scan(
                            south,
                            southPosition,
                            southLookahead,
                            previousNorthPosition,
                            nextNorthPosition
                        )
                        southPosition = southLookahead
                        previousNorthPosition = nextNorthPosition
                    }
                }

                // Deviation preserved from `dagre_rust`: dagre.js runs this
                // trailing scan once, after the loop. Upstream nests it inside,
                // which reports extra conflicts on clustered graphs. Hoisting it
                // would change geometry relative to the reference renderer.
                scan(south, southPosition, south.count, nextNorthPosition, north.count)
            }
        }

        for i in 1..<max(layering.count, 1) {
            guard !layering[i - 1].isEmpty, !layering[i].isEmpty else { continue }
            visitLayer(layering[i - 1], layering[i])
        }

        return conflicts
    }

    /// The dummy predecessor of `v` when both ends of the segment are dummies.
    private static func otherInnerSegmentNode(_ g: DagreGraph, _ v: String) -> String? {
        guard g.node(v)?.dummy != nil else { return nil }
        return (g.predecessors(v) ?? []).first { g.node($0)?.dummy != nil }
    }

    // MARK: - Alignment

    /// Chains each node to a median neighbor to form vertical blocks, skipping
    /// links that would cross a conflict or split an existing block.
    /// Returns the block root of every node plus the nodes in alignment order.
    static func verticalAlignment(
        _ g: DagreGraph,
        _ layering: [[String]],
        _ conflicts: ConflictSet,
        neighbors neighborFunction: (DagreGraph, String) -> [String]
    ) -> (root: OrderedDictionary<String, String>, order: [String]) {
        var root = OrderedDictionary<String, String>()
        var align = OrderedDictionary<String, String>()
        var position = OrderedDictionary<String, Int>()

        // Positions come from the layering, not the graph: the caller mirrors
        // the layering to produce the four extreme alignments.
        for layer in layering {
            for (order, v) in layer.enumerated() {
                root.insert(v, forKey: v)
                align.insert(v, forKey: v)
                position.insert(order, forKey: v)
            }
        }

        for layer in layering {
            var previousIndex = -1
            for v in layer {
                var ws = neighborFunction(g, v).filter { position.containsKey($0) }
                guard !ws.isEmpty else { continue }
                ws.sort { (position[$0] ?? 0) < (position[$1] ?? 0) }

                let median = (Float(ws.count) - 1) / 2
                var i = Int(median)
                let last = Int(median.rounded(.up))
                while i <= last {
                    let w = ws[i]
                    if align[v] == v,
                       previousIndex < (position[w] ?? 0),
                       !hasConflict(conflicts, v, w),
                       let wRoot = root[w] {
                        align.insert(v, forKey: w)
                        root.insert(wRoot, forKey: v)
                        align.insert(wRoot, forKey: v)
                        previousIndex = position[w] ?? 0
                    }
                    i += 1
                }
            }
        }

        return (root, align.orderedKeys)
    }

    /// Places every block at the smallest coordinate its predecessors allow,
    /// then slides blocks right into any slack their successors leave.
    static func horizontalCompaction(
        _ g: DagreGraph,
        _ layering: [[String]],
        _ root: OrderedDictionary<String, String>,
        _ alignOrder: [String],
        reverseSeparation: Bool
    ) -> OrderedDictionary<String, Float> {
        var xs = OrderedDictionary<String, Float>()
        let blockGraph = buildBlockGraph(g, layering, root, reverseSeparation: reverseSeparation)
        let borderType: DagreBorderType = reverseSeparation ? .left : .right

        func iterate(
            assign: (String, inout OrderedDictionary<String, Float>) -> Void,
            nextNodes: (String) -> [String]
        ) {
            var stack = blockGraph.nodes()
            var visited = Set<String>()
            while let element = stack.popLast() {
                if visited.contains(element) {
                    assign(element, &xs)
                } else {
                    visited.insert(element)
                    stack.append(element)
                    stack.append(contentsOf: nextNodes(element))
                }
            }
        }

        // First pass: smallest feasible coordinates.
        iterate(
            assign: { element, xs in
                let value = (blockGraph.inEdges(element) ?? []).reduce(Float(0)) { accumulator, e in
                    let predecessorX = xs[e.v] ?? 0
                    let separation = blockGraph.edge(e) ?? 0
                    return max(accumulator, predecessorX + separation)
                }
                xs.insert(value, forKey: element)
            },
            nextNodes: { blockGraph.predecessors($0) ?? [] }
        )

        // Second pass: reclaim unused space, except at the cluster border that
        // must stay pinned.
        iterate(
            assign: { element, xs in
                var minimum = Float.infinity
                for e in blockGraph.outEdges(element) ?? [] {
                    let successorX = xs[e.w] ?? 0
                    let separation = blockGraph.edge(e) ?? 0
                    minimum = min(minimum, successorX - separation)
                }
                guard minimum != .infinity, let node = g.node(element) else { return }
                if node.borderType != borderType {
                    xs.insert(max(xs[element] ?? 0, minimum), forKey: element)
                }
            },
            nextNodes: { blockGraph.successors($0) ?? [] }
        )

        // Every node inherits its block root's coordinate.
        for v in alignOrder {
            guard let rootID = root[v], let rootX = xs[rootID] else { continue }
            xs.insert(rootX, forKey: v)
        }

        return xs
    }

    /// One node per block, with an edge carrying the minimum gap between
    /// horizontally adjacent blocks.
    static func buildBlockGraph(
        _ g: DagreGraph,
        _ layering: [[String]],
        _ root: OrderedDictionary<String, String>,
        reverseSeparation: Bool
    ) -> DagreBlockGraph {
        let blockGraph = DagreBlockGraph(
            directed: true,
            multigraph: false,
            compound: false,
            label: 0,
            defaultNodeLabel: "",
            defaultEdgeLabel: 0
        )
        let nodeSeparation = g.graphLabel.nodeSeparation ?? 50
        let edgeSeparation = g.graphLabel.edgeSeparation ?? 20

        for layer in layering {
            var previous: String?
            for v in layer {
                guard let vRoot = root[v] else { continue }
                blockGraph.setNode(vRoot)
                if let previous, let previousRoot = root[previous], previousRoot != vRoot {
                    let previousMax = blockGraph.edge(previousRoot, vRoot) ?? 0
                    let separation = self.separation(
                        g,
                        v,
                        previous,
                        nodeSeparation: nodeSeparation,
                        edgeSeparation: edgeSeparation,
                        reverseSeparation: reverseSeparation
                    )
                    try? blockGraph.setEdge(previousRoot, vRoot, max(separation, previousMax))
                }
                previous = v
            }
        }

        return blockGraph
    }

    /// Minimum centre-to-centre distance between two horizontally adjacent
    /// nodes, accounting for half-widths, the node/edge gap, and any label
    /// offset that pushes a label box to one side.
    private static func separation(
        _ g: DagreGraph,
        _ v: String,
        _ w: String,
        nodeSeparation: Float,
        edgeSeparation: Float,
        reverseSeparation: Bool
    ) -> Float {
        guard let vLabel = g.node(v), let wLabel = g.node(w) else { return 0 }
        var sum: Float = 0
        var delta: Float = 0

        sum += vLabel.width / 2
        switch vLabel.labelPosition {
        case .left: delta = -vLabel.width / 2
        case .right: delta = vLabel.width / 2
        default: delta = 0
        }
        if delta != 0 {
            sum += reverseSeparation ? delta : -delta
        }

        sum += (vLabel.dummy != nil ? edgeSeparation : nodeSeparation) / 2
        sum += (wLabel.dummy != nil ? edgeSeparation : nodeSeparation) / 2

        sum += wLabel.width / 2
        switch wLabel.labelPosition {
        case .left: delta = wLabel.width / 2
        case .right: delta = -wLabel.width / 2
        default: delta = 0
        }
        if delta != 0 {
            sum += reverseSeparation ? delta : -delta
        }

        return sum
    }

    // MARK: - Combining the four alignments

    /// The alignment whose laid-out width is smallest; the other three are
    /// shifted to line up with it.
    static func findSmallestWidthAlignment(
        _ g: DagreGraph,
        _ alignments: OrderedDictionary<String, OrderedDictionary<String, Float>>
    ) -> OrderedDictionary<String, Float>? {
        var best: (xs: OrderedDictionary<String, Float>, width: Double)?
        for xs in alignments.values {
            var maximum = -Double.infinity
            var minimum = Double.infinity
            for (v, x) in xs {
                let halfWidth = (g.node(v)?.width ?? 0) / 2
                maximum = max(maximum, Double(x + halfWidth))
                minimum = min(minimum, Double(x - halfWidth))
            }
            let width = maximum - minimum
            if best == nil || width < best!.width {
                best = (xs, width)
            }
        }
        return best?.xs
    }

    /// Translates each alignment so left-biased ones share the reference's
    /// minimum coordinate and right-biased ones share its maximum.
    static func alignCoordinates(
        _ alignments: inout OrderedDictionary<String, OrderedDictionary<String, Float>>,
        _ alignTo: OrderedDictionary<String, Float>
    ) {
        let reference = alignTo.values
        guard let referenceMin = reference.min(), let referenceMax = reference.max() else { return }

        for vertical in ["u", "d"] {
            for horizontal in ["l", "r"] {
                let key = vertical + horizontal
                guard let xs = alignments[key], xs != alignTo else { continue }
                let values = xs.values
                guard let minimum = values.min(), let maximum = values.max() else { continue }
                let delta = horizontal == "l" ? referenceMin - minimum : referenceMax - maximum
                guard delta != 0 else { continue }
                alignments.withValue(forKey: key) { xs in
                    xs.mapValuesInPlace { $0 += delta }
                }
            }
        }
    }

    /// Averages the two middle coordinates of the four alignments, or takes one
    /// outright when the caller pinned an alignment.
    static func balance(
        _ alignments: OrderedDictionary<String, OrderedDictionary<String, Float>>,
        alignment: DagreAlignment?
    ) -> OrderedDictionary<String, Float> {
        guard var result = alignments["ul"] else { return OrderedDictionary() }

        for v in result.orderedKeys {
            if let alignment {
                result.insert(alignments[alignment.rawValue]?[v] ?? 0, forKey: v)
            } else {
                let candidates = alignments.values.map { $0[v] ?? .infinity }.sorted()
                let lower = candidates.count > 1 ? candidates[1] : 0
                let upper = candidates.count > 2 ? candidates[2] : 0
                result.insert((lower + upper) / 2, forKey: v)
            }
        }

        return result
    }

    /// Runs the four Brandes–Köpf passes and combines them into final x
    /// coordinates.
    static func positionX(_ g: DagreGraph) -> OrderedDictionary<String, Float> {
        let layering = DagreUtil.buildLayerMatrix(g)
        guard layering.contains(where: { !$0.isEmpty }) else { return OrderedDictionary() }

        var conflicts = findType1Conflicts(g, layering)
        conflicts.extend(findType2Conflicts(g, layering))

        var alignments = OrderedDictionary<String, OrderedDictionary<String, Float>>()
        for vertical in ["u", "d"] {
            var adjustedLayering = vertical == "u" ? layering : layering.reversed().map { $0 }

            for horizontal in ["l", "r"] {
                if horizontal == "r" {
                    adjustedLayering = adjustedLayering.map { $0.reversed() }
                }

                let neighborFunction: (DagreGraph, String) -> [String] =
                    vertical == "u"
                    ? { graph, v in graph.predecessors(v) ?? [] }
                    : { graph, v in graph.successors(v) ?? [] }

                let alignment = verticalAlignment(
                    g,
                    adjustedLayering,
                    conflicts,
                    neighbors: neighborFunction
                )
                var xs = horizontalCompaction(
                    g,
                    adjustedLayering,
                    alignment.root,
                    alignment.order,
                    reverseSeparation: horizontal == "r"
                )
                if horizontal == "r" {
                    var negated = OrderedDictionary<String, Float>()
                    for (key, value) in xs {
                        negated.insert(-value, forKey: key)
                    }
                    xs = negated
                }

                alignments.insert(xs, forKey: vertical + horizontal)
            }
        }

        guard let smallest = findSmallestWidthAlignment(g, alignments) else {
            return OrderedDictionary()
        }
        alignCoordinates(&alignments, smallest)
        return balance(alignments, alignment: g.graphLabel.alignment)
    }
}
