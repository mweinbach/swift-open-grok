// DagreUtil.swift
//
// Open Grok — Swift port of `dagre_rust::layout::util`
// (third_party/dagre_rust/src/layout/util.rs, W8-S2).

/// An axis-aligned rectangle centred on `(x, y)`.
public struct DagreRect: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

enum DagreUtil {
    /// Adds a synthesized node under a fresh `<name><n>` id and returns that id.
    static func addDummyNode(
        _ graph: DagreGraph,
        kind: DagreDummyKind,
        data: DagreNode,
        namePrefix: String
    ) -> String {
        var nodeID = "\(namePrefix)\(graph.nextUniqueID())"
        while graph.hasNode(nodeID) {
            nodeID = "\(namePrefix)\(graph.nextUniqueID())"
        }

        var label = data
        label.dummy = kind
        graph.setNode(nodeID, label)
        return nodeID
    }

    /// Adds a cluster border node at an optional rank/order.
    static func addBorderNode(
        _ graph: DagreGraph,
        namePrefix: String,
        rank: Int? = nil,
        order: Int? = nil
    ) -> String {
        var node = DagreNode()
        node.rank = rank
        node.order = order
        return addDummyNode(graph, kind: .border, data: node, namePrefix: namePrefix)
    }

    /// Collapses parallel edges into one, taking the max `minlen` and the sum of
    /// the weights. The result is the simple graph the network simplex needs.
    static func simplify(_ g: DagreGraph) -> DagreGraph {
        let simplified = DagreGraph.makeDagreGraph(directed: true)
        simplified.graphLabel = g.graphLabel

        for nodeID in g.nodes() {
            simplified.setNode(nodeID, g.node(nodeID))
        }

        for edgeRef in g.edges() {
            var accumulated = simplified.edge(edgeRef.v, edgeRef.w) ?? {
                var edge = DagreEdge()
                edge.weight = 0
                edge.minlen = 1
                return edge
            }()

            let original = g.edge(edgeRef) ?? {
                var edge = DagreEdge()
                edge.weight = 0
                edge.minlen = 1
                return edge
            }()

            accumulated.minlen = max(accumulated.minlen ?? 1, original.minlen ?? 1)
            accumulated.weight = (accumulated.weight ?? 0) + (original.weight ?? 0)
            try? simplified.setEdge(edgeRef.v, edgeRef.w, accumulated)
        }

        return simplified
    }

    /// Copies `g` without its cluster hierarchy, keeping only leaf nodes.
    static func asNonCompoundGraph(_ g: DagreGraph) -> DagreGraph {
        let simplified = DagreGraph.makeDagreGraph(directed: true, multigraph: true, compound: false)
        simplified.graphLabel = g.graphLabel

        for v in g.nodes() where g.children(v).isEmpty {
            simplified.setNode(v, g.node(v) ?? DagreNode())
        }
        for e in g.edges() {
            try? simplified.setEdge(e, g.edge(e))
        }
        return simplified
    }

    /// Copies leaf-node and edge labels from `source` back onto `destination`.
    /// Used to fold the ranked non-compound graph back into the compound one.
    static func transferNodeEdgeLabels(from source: DagreGraph, to destination: DagreGraph) {
        for v in source.nodes() where source.children(v).isEmpty {
            destination.setNode(v, source.node(v) ?? DagreNode())
        }
        for e in source.edges() {
            try? destination.setEdge(e, source.edge(e))
        }
    }

    /// Where a ray from `point` toward the centre of `rect` crosses the rect's
    /// boundary. Used to pull edge endpoints back to the node outline.
    static func intersectRect(_ rect: DagreRect, _ point: DagrePoint) -> DagrePoint {
        let x = rect.x
        let y = rect.y
        let dx = point.x - x
        let dy = point.y - y
        let w = rect.width / 2
        let h = rect.height / 2

        if dx == 0 && dy == 0 {
            return DagrePoint(x: x + w, y: y)
        }

        let sx: Float
        let sy: Float
        if abs(dy) * w > abs(dx) * h {
            // Crosses the top or bottom edge.
            if dy < 0 {
                (sx, sy) = (-h * dx / dy, -h)
            } else {
                (sx, sy) = (h * dx / dy, h)
            }
        } else {
            // Crosses the left or right edge.
            if dx < 0 {
                (sx, sy) = (-w, -w * dy / dx)
            } else {
                (sx, sy) = (w, w * dy / dx)
            }
        }

        return DagrePoint(x: x + sx, y: y + sy)
    }

    /// The highest rank assigned to any node, or 0 when none are ranked.
    static func maxRank(_ g: DagreGraph) -> Int {
        g.nodes().compactMap { g.node($0)?.rank }.max() ?? 0
    }

    /// Node ids grouped by rank, each rank sorted by node order.
    static func buildLayerMatrix(_ g: DagreGraph) -> [[String]] {
        let highestRank = maxRank(g)
        guard highestRank >= 0 else { return [] }

        var layering: [OrderedDictionary<Int, String>] =
            Array(repeating: OrderedDictionary(), count: highestRank + 1)

        for v in g.nodes() {
            guard let node = g.node(v), let rank = node.rank else { continue }
            guard rank >= 0 && rank < layering.count else { continue }
            layering[rank].insert(v, forKey: node.order ?? 0)
        }

        return layering.map { layer in
            layer.orderedKeys.sorted().compactMap { layer[$0] }
        }
    }

    /// Shifts every rank so the lowest becomes 0.
    static func normalizeRanks(_ graph: DagreGraph) {
        let nodeIDs = graph.nodes()
        let minimum = nodeIDs.map { graph.node($0)?.rank ?? 0 }.min() ?? 0
        for nodeID in nodeIDs {
            graph.withNode(nodeID) { node in
                if let rank = node.rank {
                    node.rank = rank - minimum
                }
            }
        }
    }

    /// Closes gaps left in the rank sequence by the nesting graph's border
    /// layers, keeping the ranks that are multiples of `nodeRankFactor`.
    static func removeEmptyRanks(_ graph: DagreGraph) {
        let nodes = graph.nodes()
        guard !nodes.isEmpty else { return }

        let ranks = nodes.map { graph.node($0)?.rank ?? 0 }
        let offset = ranks.min() ?? 0
        let highestRank = (ranks.max() ?? 0) - offset

        var layers: [[String]] = Array(repeating: [], count: max(highestRank + 1, 0))
        for v in nodes {
            let rank = (graph.node(v)?.rank ?? 0) - offset
            if rank >= 0 && rank < layers.count {
                layers[rank].append(v)
            }
        }

        let nodeRankFactor = Int(graph.graphLabel.nodeRankFactor ?? 0)
        guard nodeRankFactor > 0 else { return }

        var delta = 0
        for (index, layer) in layers.enumerated() {
            if layer.isEmpty && index % nodeRankFactor != 0 {
                delta -= 1
            } else if delta != 0 {
                for v in layer {
                    graph.withNode(v) { node in
                        node.rank = (node.rank ?? 0) + delta
                    }
                }
            }
        }
    }

    /// Splits `collection` into the elements matching `predicate` and the rest,
    /// preserving relative order in both halves.
    static func partition<Element>(
        _ collection: [Element],
        _ predicate: (Element) -> Bool
    ) -> (matching: [Element], rest: [Element]) {
        var matching: [Element] = []
        var rest: [Element] = []
        for element in collection {
            if predicate(element) {
                matching.append(element)
            } else {
                rest.append(element)
            }
        }
        return (matching, rest)
    }
}
