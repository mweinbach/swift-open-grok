// DagreRank.swift
//
// Open Grok — Swift port of `dagre_rust::layout::rank`
// (third_party/dagre_rust/src/layout/rank/{mod,util,feasible_tree,network_simplex}.rs,
// W8-S2).
//
// Ranking assigns each node a layer index that respects every edge's `minlen`.
// The structure follows Gansner et al., "A Technique for Drawing Directed
// Graphs": longest-path for an initial feasible ranking, a tight spanning tree,
// then network simplex to shorten edges.

enum DagreRank {
    /// Assigns `rank` to every node using the configured ranker.
    static func run(_ g: DagreGraph) {
        switch g.graphLabel.ranker {
        case .networkSimplex, nil:
            networkSimplex(g)
        case .tightTree:
            longestPath(g)
            _ = feasibleTree(g)
        case .longestPath:
            longestPath(g)
        }
    }

    // MARK: - Longest path

    /// Pushes every node to the lowest layer its out-edges allow. Fast, wide,
    /// and good enough as a starting point for the other rankers.
    static func longestPath(_ g: DagreGraph) {
        var visited = Set<String>()

        @discardableResult
        func visit(_ v: String) -> Int {
            if !visited.insert(v).inserted {
                return g.node(v)?.rank ?? 0
            }

            let ranks = (g.outEdges(v) ?? []).map { e in
                visit(e.w) - Int((g.edge(e)?.minlen ?? 0).rounded())
            }
            let rank = ranks.min() ?? 0
            g.withNode(v) { $0.rank = rank }
            return rank
        }

        for nodeID in g.sources() {
            visit(nodeID)
        }
    }

    /// How much longer an edge is than its `minlen` requires.
    static func slack(_ g: DagreGraph, _ e: GraphEdgeRef) -> Int {
        let wRank = g.node(e.w)?.rank ?? 0
        let vRank = g.node(e.v)?.rank ?? 0
        // Upstream's fallback here is 10, not 1; kept for parity, though every
        // edge reaching this point has been given a `minlen` by
        // `setEdgeLabelDefaults`.
        let minlen = Int((g.edge(e)?.minlen ?? 10).rounded())
        return wRank - vRank - minlen
    }

    // MARK: - Feasible tree

    /// Builds a spanning tree of tight edges, shifting ranks until every tree
    /// edge has zero slack. Returns the (undirected) tree.
    @discardableResult
    static func feasibleTree(_ g: DagreGraph) -> DagreGraph {
        let t = DagreGraph.makeDagreGraph(directed: false, multigraph: false, compound: false)

        let start = g.nodes().first ?? ""
        let size = g.nodeCount
        t.setNode(start, DagreNode())

        // Each pass adds at least one node to the tree, so `size` iterations is
        // a hard upper bound; the guard keeps a malformed graph from hanging.
        var iterations = 0
        while tightTree(t, g) < size {
            guard iterations < size + 1, let edge = minimumSlackIncidentEdge(t, g) else { break }
            iterations += 1
            let delta = t.hasNode(edge.v) ? slack(g, edge) : -slack(g, edge)
            shiftRanks(t, g, by: delta)
        }

        return t
    }

    /// Grows `t` along zero-slack edges and returns its node count.
    private static func tightTree(_ t: DagreGraph, _ g: DagreGraph) -> Int {
        func visit(_ v: String) {
            for edge in g.nodeEdges(v) ?? [] {
                let w = (v == edge.v) ? edge.w : edge.v
                if !t.hasNode(w) && slack(g, edge) == 0 {
                    t.setNode(w, DagreNode())
                    try? t.setEdge(v, w, DagreEdge())
                    visit(w)
                }
            }
        }

        for nodeID in t.nodes() {
            visit(nodeID)
        }
        return t.nodeCount
    }

    /// The lowest-slack edge with exactly one endpoint already in the tree.
    private static func minimumSlackIncidentEdge(_ t: DagreGraph, _ g: DagreGraph) -> GraphEdgeRef? {
        var best: (edge: GraphEdgeRef, slack: Int)?
        for e in g.edges() where t.hasNode(e.v) != t.hasNode(e.w) {
            let value = slack(g, e)
            if best == nil || value < best!.slack {
                best = (e, value)
            }
        }
        return best?.edge
    }

    private static func shiftRanks(_ t: DagreGraph, _ g: DagreGraph, by delta: Int) {
        for nodeID in t.nodes() {
            g.withNode(nodeID) { $0.rank = ($0.rank ?? 0) + delta }
        }
    }

    // MARK: - Network simplex

    /// Iteratively swaps tree edges with negative cut values for tighter ones,
    /// shortening total edge length. Ranks land on `g`'s nodes.
    static func networkSimplex(_ g: DagreGraph) {
        let simplified = DagreUtil.simplify(g)

        longestPath(simplified)

        let t = feasibleTree(simplified)
        initLowLimValues(t)
        initCutValues(t, simplified)

        // Each exchange strictly reduces total weighted edge length, so the loop
        // terminates; the cap bounds the work for pathological inputs rather
        // than changing the result on well-formed ones.
        let maximumExchanges = max(64, simplified.nodeCount * simplified.edgeCount)
        var exchanges = 0
        while let e = leaveEdge(t) {
            guard exchanges < maximumExchanges, let f = enterEdge(t, simplified, e) else { break }
            exchanges += 1
            exchangeEdges(t, simplified, e, f)
        }

        for v in g.nodes() {
            guard let rank = simplified.node(v)?.rank else { continue }
            g.withNode(v) { $0.rank = rank }
        }
    }

    private static func initCutValues(_ t: DagreGraph, _ g: DagreGraph) {
        var vs = t.postorder(from: t.nodes())
        // The last entry is the tree root, which has no parent edge.
        if !vs.isEmpty { vs.removeLast() }
        for nodeID in vs {
            assignCutValue(t, g, nodeID)
        }
    }

    private static func assignCutValue(_ t: DagreGraph, _ g: DagreGraph, _ child: String) {
        let cutValue = calculateCutValue(t, g, child)
        guard let parent = t.node(child)?.parent else { return }
        t.withEdge(child, parent) { $0.cutValue = cutValue }
    }

    /// The cut value of the tree edge between `child` and its parent: the net
    /// weight of graph edges crossing the cut that removing it would create.
    private static func calculateCutValue(_ t: DagreGraph, _ g: DagreGraph, _ child: String) -> Float {
        guard let childLabel = t.node(child) else { return 0 }
        let parent = childLabel.parent ?? ""

        // True when the tree edge runs child -> parent in the directed graph.
        var childIsTail = true
        var graphEdge = g.edge(child, parent)
        if graphEdge == nil {
            childIsTail = false
            graphEdge = g.edge(parent, child)
        }

        var cutValue = graphEdge?.weight ?? 0

        for e in g.nodeEdges(child) ?? [] {
            let isOutEdge = e.v == child
            let other = isOutEdge ? e.w : e.v
            guard other != parent else { continue }

            let pointsToHead = isOutEdge == childIsTail
            let otherWeight = g.edge(e)?.weight ?? 0
            cutValue += pointsToHead ? otherWeight : -otherWeight

            if t.hasEdge(child, other) {
                let outCutValue = t.edge(child, other)?.cutValue ?? 0
                cutValue += pointsToHead ? -outCutValue : outCutValue
            }
        }

        return cutValue
    }

    /// Numbers the tree so ancestry is a range check: `low <= lim(v) <= lim(root)`.
    private static func initLowLimValues(_ tree: DagreGraph, root explicitRoot: String? = nil) {
        let root = explicitRoot ?? tree.nodes().first ?? ""
        var visited = Set<String>()
        _ = assignLowLim(tree, &visited, nextLim: 1, v: root, parent: nil)
    }

    private static func assignLowLim(
        _ tree: DagreGraph,
        _ visited: inout Set<String>,
        nextLim: Int,
        v: String,
        parent: String?
    ) -> Int {
        let low = nextLim
        var nextLim = nextLim

        visited.insert(v)
        for w in tree.neighbors(v) ?? [] where !visited.contains(w) {
            nextLim = assignLowLim(tree, &visited, nextLim: nextLim, v: w, parent: v)
        }

        let limit = nextLim
        // Upstream only advances the counter when the node exists in the tree,
        // so the numbering stays contiguous over the nodes it actually visited.
        let visitedExistingNode: Bool = tree.withNode(v) { node in
            node.low = low
            node.lim = limit
            node.parent = parent
            return true
        } ?? false
        if visitedExistingNode {
            nextLim += 1
        }

        return nextLim
    }

    /// The first tree edge whose cut value is negative, if any.
    private static func leaveEdge(_ tree: DagreGraph) -> GraphEdgeRef? {
        tree.edges().first { (tree.edge($0)?.cutValue ?? 0) < 0 }
    }

    /// The lowest-slack graph edge that would reconnect the tree after `edge` is
    /// removed.
    private static func enterEdge(_ t: DagreGraph, _ g: DagreGraph, _ edge: GraphEdgeRef) -> GraphEdgeRef? {
        var v = edge.v
        var w = edge.w

        // Assume v is the tail; flip if the graph disagrees.
        if !g.hasEdge(v, w) {
            v = edge.w
            w = edge.v
        }

        let vLabel = t.node(v) ?? DagreNode()
        let wLabel = t.node(w) ?? DagreNode()
        var tailLabel = vLabel
        var flip = false

        // With the root on the tail side, the descendant test inverts.
        if (vLabel.lim ?? 0) > (wLabel.lim ?? 0) {
            tailLabel = wLabel
            flip = true
        }

        var best: (edge: GraphEdgeRef, slack: Int)?
        for candidate in g.edges() {
            let vNode = t.node(candidate.v) ?? DagreNode()
            let wNode = t.node(candidate.w) ?? DagreNode()
            guard flip == isDescendant(vNode, of: tailLabel),
                  flip != isDescendant(wNode, of: tailLabel)
            else { continue }
            let value = slack(g, candidate)
            if best == nil || value < best!.slack {
                best = (candidate, value)
            }
        }
        return best?.edge
    }

    private static func exchangeEdges(
        _ t: DagreGraph,
        _ g: DagreGraph,
        _ e: GraphEdgeRef,
        _ f: GraphEdgeRef
    ) {
        t.removeEdge(e.v, e.w)
        try? t.setEdge(f.v, f.w, DagreEdge())
        initLowLimValues(t)
        initCutValues(t, g)
        updateRanks(t, g)
    }

    /// Re-derives ranks by walking the tree from its root, each child sitting
    /// exactly `minlen` away from its parent.
    private static func updateRanks(_ t: DagreGraph, _ g: DagreGraph) {
        guard let root = t.nodes().first else { return }

        var children: [String: [String]] = [:]
        for v in t.nodes() {
            guard let parent = t.node(v)?.parent else { continue }
            children[parent, default: []].append(v)
        }

        var stack = [root]
        while let parent = stack.popLast() {
            guard let vs = children[parent] else { continue }
            for v in vs {
                var edge = g.edge(v, parent)
                var flipped = false
                if edge == nil {
                    edge = g.edge(parent, v)
                    flipped = true
                }

                let minlen = Int(edge?.minlen ?? 0)
                let parentRank = g.node(parent)?.rank ?? 0
                g.withNode(v) { $0.rank = parentRank + (flipped ? minlen : -minlen) }
                stack.append(v)
            }
        }
    }

    private static func isDescendant(_ node: DagreNode, of root: DagreNode) -> Bool {
        let low = root.low ?? 0
        let lim = node.lim ?? 0
        return low <= lim && lim <= (root.lim ?? 0)
    }
}
