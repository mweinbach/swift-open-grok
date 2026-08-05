// DagreNestingGraph.swift
//
// Open Grok — Swift port of `dagre_rust::layout::nesting_graph`
// (third_party/dagre_rust/src/layout/nesting_graph.rs, W8-S2).
//
// The nesting graph idea comes from Sander, "Layout of Compound Directed
// Graphs": dummy nodes mark the top and bottom of each cluster, edges pin every
// member between them, and a synthetic root keeps the whole graph connected so
// ranking has a single source.

enum DagreNestingGraph {
    /// Adds the nesting root, the per-cluster top/bottom border nodes, and the
    /// edges that keep cluster members inside their bounds. Also inflates every
    /// `minlen` so ordinary nodes never share a rank with a cluster border.
    static func run(_ graph: DagreGraph) {
        let root = DagreUtil.addDummyNode(graph, kind: .root, data: DagreNode(), namePrefix: "_root")
        let depths = treeDepths(graph)
        var height = depths.values.max() ?? 0
        if height > 0 {
            height -= 1
        }

        let nodeSeparation = Float(2 * height + 1)
        graph.withGraphLabel { $0.nestingRoot = root }

        for edgeRef in graph.edges() {
            graph.withEdge(edgeRef) { edge in
                edge.minlen = (edge.minlen ?? 1) * nodeSeparation
            }
        }

        // Heavy enough to outweigh every real edge, so clusters stay compact.
        let weight = sumWeights(graph) + 1

        for childID in graph.children(graphRootNodeID) {
            visit(
                graph,
                root: root,
                nodeSeparation: nodeSeparation,
                weight: weight,
                height: height,
                depths: depths,
                nodeID: childID
            )
        }

        // Remembered so `removeEmptyRanks` knows which ranks are border layers.
        graph.withGraphLabel { $0.nodeRankFactor = nodeSeparation }
    }

    /// Depth of every node in the cluster tree, top-level nodes being depth 1.
    private static func treeDepths(_ graph: DagreGraph) -> OrderedDictionary<String, Int> {
        var depths = OrderedDictionary<String, Int>()

        func visit(_ nodeID: String, depth: Int) {
            for childID in graph.children(nodeID) {
                visit(childID, depth: depth + 1)
            }
            depths.insert(depth, forKey: nodeID)
        }

        for nodeID in graph.children(graphRootNodeID) {
            visit(nodeID, depth: 1)
        }
        return depths
    }

    private static func visit(
        _ graph: DagreGraph,
        root: String,
        nodeSeparation: Float,
        weight: Float,
        height: Int,
        depths: OrderedDictionary<String, Int>,
        nodeID: String
    ) {
        let children = graph.children(nodeID)
        if children.isEmpty {
            if nodeID != root {
                var edge = DagreEdge()
                edge.minlen = nodeSeparation
                edge.weight = 0
                try? graph.setEdge(root, nodeID, edge)
            }
            return
        }

        let top = DagreUtil.addBorderNode(graph, namePrefix: "_bt")
        let bottom = DagreUtil.addBorderNode(graph, namePrefix: "_bb")

        try? graph.setParent(top, nodeID)
        try? graph.setParent(bottom, nodeID)

        graph.withNode(nodeID) { node in
            node.borderTop = top
            node.borderBottom = bottom
        }

        for childID in children {
            visit(
                graph,
                root: root,
                nodeSeparation: nodeSeparation,
                weight: weight,
                height: height,
                depths: depths,
                nodeID: childID
            )

            guard let childNode = graph.node(childID) else { continue }
            let childBorderTop = childNode.borderTop
            let childTop = childBorderTop ?? childID
            let childBottom = childNode.borderBottom ?? childID
            // A nested cluster only needs half the pull: its own borders already
            // hold its members in place.
            let thisWeight = childBorderTop != nil ? weight : 2 * weight
            // A leaf must clear every rank the deeper subtrees could occupy.
            let minlen = childTop == childBottom ? height - (depths[nodeID] ?? 0) + 1 : 1

            var topEdge = DagreEdge()
            topEdge.minlen = Float(minlen)
            topEdge.weight = thisWeight
            topEdge.nestingEdge = true
            try? graph.setEdge(top, childTop, topEdge)

            var bottomEdge = DagreEdge()
            bottomEdge.minlen = Float(minlen)
            bottomEdge.weight = thisWeight
            bottomEdge.nestingEdge = true
            try? graph.setEdge(childBottom, bottom, bottomEdge)
        }

        if graph.parent(nodeID) == nil {
            var edge = DagreEdge()
            edge.minlen = Float((depths[nodeID] ?? 0) + height)
            edge.weight = 0
            edge.nestingEdge = true
            try? graph.setEdge(root, top, edge)
        }
    }

    private static func sumWeights(_ graph: DagreGraph) -> Float {
        graph.edges().reduce(Float(0)) { total, edgeRef in
            total + (graph.edge(edgeRef)?.weight ?? 0)
        }
    }

    /// Removes the nesting root and every edge it added, once ranks are final.
    static func cleanup(_ graph: DagreGraph) {
        if let nestingRoot = graph.graphLabel.nestingRoot {
            graph.removeNode(nestingRoot)
        }
        graph.withGraphLabel { $0.nestingRoot = nil }

        for edgeRef in graph.edges() where graph.edge(edgeRef)?.nestingEdge == true {
            graph.removeEdge(edgeRef)
        }
    }
}
