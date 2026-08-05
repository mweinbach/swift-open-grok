// DagreBorderSegments.swift
//
// Open Grok — Swift port of `dagre_rust::layout::add_border_segments`
// (third_party/dagre_rust/src/layout/add_border_segments.rs, W8-S2).
//
// A cluster spans several ranks, so it needs a left and a right border node on
// each of them. Chaining consecutive border nodes keeps the cluster's sides
// straight through the ordering and compaction passes.

enum DagreBorderSegments {
    /// Adds left/right border nodes on every rank each cluster spans.
    static func run(_ g: DagreGraph) {
        for v in g.children(graphRootNodeID) {
            visit(v, g)
        }
    }

    private static func visit(_ v: String, _ g: DagreGraph) {
        for child in g.children(v) {
            visit(child, g)
        }

        guard let node = g.node(v), let minRank = node.minRank else { return }
        g.withNode(v) { node in
            node.borderLeft = OrderedDictionary()
            node.borderRight = OrderedDictionary()
        }

        let maxRank = (node.maxRank ?? 0) + 1
        var rank = minRank
        while rank < maxRank {
            addBorderNode(g, side: .left, namePrefix: "_bl", cluster: v, rank: rank)
            addBorderNode(g, side: .right, namePrefix: "_br", cluster: v, rank: rank)
            rank += 1
        }
    }

    private static func addBorderNode(
        _ g: DagreGraph,
        side: DagreBorderType,
        namePrefix: String,
        cluster: String,
        rank: Int
    ) {
        var label = DagreNode()
        label.rank = rank
        label.borderType = side

        let current = DagreUtil.addDummyNode(g, kind: .border, data: label, namePrefix: namePrefix)

        var previous: String?
        g.withNode(cluster) { node in
            switch side {
            case .left:
                node.borderLeft?.insert(current, forKey: rank)
                previous = node.borderLeft?[rank - 1]
            case .right:
                node.borderRight?.insert(current, forKey: rank)
                previous = node.borderRight?[rank - 1]
            }
        }

        if let previous {
            var edge = DagreEdge()
            edge.weight = 1
            try? g.setEdge(previous, current, edge)
        }

        try? g.setParent(current, cluster)
    }
}
