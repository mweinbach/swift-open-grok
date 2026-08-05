// DagreLayout.swift
//
// Open Grok — Swift port of `dagre_rust::layout`
// (third_party/dagre_rust/src/layout/mod.rs, W8-S2 / CRATE_MAP.md row 1).
//
// `DagreLayout.run(_:)` is the entry point: it copies the caller's graph into a
// working graph, runs the pipeline, and writes coordinates back. Every pass is
// deterministic given the input, so the same diagram source always produces
// byte-identical geometry.

public enum DagreLayout {
    private static let defaultRankSeparation: Float = 50

    /// Lays out `g` in place: nodes gain `x`/`y`, edges gain `points`, and the
    /// graph label gains `width`/`height`.
    public static func run(_ g: DagreGraph) {
        let layoutGraph = buildLayoutGraph(g)
        runPipeline(layoutGraph)
        updateInputGraph(g, from: layoutGraph)
    }

    /// The pass sequence, in order. Exposed for tests that need to observe an
    /// intermediate stage.
    static func runPipeline(_ graph: DagreGraph) {
        makeSpaceForEdgeLabels(graph)
        removeSelfEdges(graph)
        DagreAcyclic.run(graph)
        DagreNestingGraph.run(graph)

        // Ranking runs on a flattened copy, then the ranks are folded back in.
        let nonCompound = DagreUtil.asNonCompoundGraph(graph)
        DagreRank.run(nonCompound)
        DagreUtil.transferNodeEdgeLabels(from: nonCompound, to: graph)

        injectEdgeLabelProxies(graph)
        DagreUtil.removeEmptyRanks(graph)
        DagreNestingGraph.cleanup(graph)
        DagreUtil.normalizeRanks(graph)
        assignRankMinMax(graph)
        removeEdgeLabelProxies(graph)
        DagreNormalize.run(graph)
        DagreParentDummyChains.run(graph)
        DagreBorderSegments.run(graph)
        DagreOrder.run(graph)
        insertSelfEdges(graph)
        DagreCoordinateSystem.adjust(graph)
        DagrePosition.run(graph)
        positionSelfEdges(graph)
        removeBorderNodes(graph)
        DagreNormalize.undo(graph)
        fixupEdgeLabelCoordinates(graph)
        DagreCoordinateSystem.undo(graph)
        translateGraph(graph)
        assignNodeIntersects(graph)
        reversePointsForReversedEdges(graph)
        DagreAcyclic.undo(graph)
    }

    // MARK: - Input/output plumbing

    /// Copies the laid-out geometry back onto the caller's graph.
    static func updateInputGraph(_ inputGraph: DagreGraph, from layoutGraph: DagreGraph) {
        for v in inputGraph.nodes() {
            guard let layoutLabel = layoutGraph.node(v) else { continue }
            let hasChildren = !layoutGraph.children(v).isEmpty
            inputGraph.withNode(v) { node in
                node.x = layoutLabel.x
                node.y = layoutLabel.y
                // Clusters are sized by their contents, so their box comes back
                // from layout; leaf nodes keep the size the caller set.
                if hasChildren {
                    node.width = layoutLabel.width
                    node.height = layoutLabel.height
                }
            }
        }

        for e in inputGraph.edges() {
            guard let layoutLabel = layoutGraph.edge(e) else { continue }
            inputGraph.withEdge(e) { edge in
                edge.points = layoutLabel.points
                edge.x = layoutLabel.x
                edge.y = layoutLabel.y
            }
        }

        inputGraph.withGraphLabel { label in
            label.width = layoutGraph.graphLabel.width
            label.height = layoutGraph.graphLabel.height
        }
    }

    static func applyGraphLabelDefaults(_ label: inout DagreGraphConfig) {
        if label.rankSeparation == nil { label.rankSeparation = 50 }
        if label.edgeSeparation == nil { label.edgeSeparation = 20 }
        if label.nodeSeparation == nil { label.nodeSeparation = 50 }
        if label.rankDirection == nil { label.rankDirection = .topToBottom }
        if label.marginX == nil { label.marginX = 0 }
        if label.marginY == nil { label.marginY = 0 }
    }

    static func applyEdgeLabelDefaults(_ label: inout DagreEdge) {
        if label.minlen == nil { label.minlen = 1 }
        if label.weight == nil { label.weight = 1 }
        if label.width == nil { label.width = 0 }
        if label.height == nil { label.height = 0 }
        if label.labelOffset == nil { label.labelOffset = 10 }
        if label.labelPosition == nil { label.labelPosition = .right }
    }

    /// Copies the caller's graph into the compound multigraph the pipeline
    /// needs, filling in defaults. Only layout-relevant attributes cross over.
    static func buildLayoutGraph(_ inputGraph: DagreGraph) -> DagreGraph {
        let g = DagreGraph.makeDagreGraph(directed: true, multigraph: true, compound: true)

        var graphLabel = inputGraph.graphLabel
        applyGraphLabelDefaults(&graphLabel)
        g.graphLabel = graphLabel

        for nodeID in inputGraph.nodes() {
            guard let node = inputGraph.node(nodeID) else { continue }
            g.setNode(nodeID, node)
            try? g.setParent(nodeID, inputGraph.parent(nodeID))
        }

        for edgeRef in inputGraph.edges() {
            guard var edgeLabel = inputGraph.edge(edgeRef) else { continue }
            applyEdgeLabelDefaults(&edgeLabel)
            try? g.setEdge(edgeRef, edgeLabel)
        }

        return g
    }

    // MARK: - Edge labels

    /// Halves the rank gap and doubles every `minlen`, so edge labels get their
    /// own half-rank to sit in (the trick from the Gansner paper).
    static func makeSpaceForEdgeLabels(_ graph: DagreGraph) {
        let rankDirection = graph.graphLabel.rankDirection
        graph.withGraphLabel { label in
            label.rankSeparation = (label.rankSeparation ?? defaultRankSeparation) / 2
        }

        for edgeRef in graph.edges() {
            graph.withEdge(edgeRef) { edge in
                edge.minlen = (edge.minlen ?? 1) * 2
                guard edge.labelPosition != .center else { return }
                let labelOffset = edge.labelOffset ?? 10
                switch rankDirection {
                case .topToBottom, .bottomToTop:
                    edge.width = (edge.width ?? 0) + labelOffset
                default:
                    edge.height = (edge.height ?? 0) + labelOffset
                }
            }
        }
    }

    /// Adds a placeholder node on the rank each edge label will occupy, so
    /// removing empty ranks does not move the label off centre.
    static func injectEdgeLabelProxies(_ g: DagreGraph) {
        for e in g.edges() {
            guard let edge = g.edge(e),
                  (edge.width ?? 0) > 0,
                  (edge.height ?? 0) > 0
            else { continue }

            let vRank = g.node(e.v)?.rank ?? 0
            let wRank = g.node(e.w)?.rank ?? 0
            var label = DagreNode()
            label.rank = (wRank - vRank) / 2 + vRank
            label.width = edge.width ?? 0
            label.height = edge.height ?? 0
            label.labelPosition = edge.labelPosition
            label.edgeRef = e
            _ = DagreUtil.addDummyNode(g, kind: .edgeProxy, data: label, namePrefix: "_ep")
        }
    }

    /// Records each proxy's final rank on its edge and removes the proxy.
    static func removeEdgeLabelProxies(_ g: DagreGraph) {
        for v in g.nodes() {
            guard let node = g.node(v), node.dummy == .edgeProxy else { continue }
            let rank = node.rank ?? 0
            if let edgeRef = node.edgeRef {
                g.withEdge(edgeRef) { $0.labelRank = rank }
            }
            g.removeNode(v)
        }
    }

    /// Nudges label boxes off the edge itself, by the offset reserved in
    /// `makeSpaceForEdgeLabels`.
    static func fixupEdgeLabelCoordinates(_ g: DagreGraph) {
        for e in g.edges() {
            g.withEdge(e) { edge in
                guard edge.x != 0 else { return }
                let labelOffset = edge.labelOffset ?? 0
                if edge.labelPosition == .left || edge.labelPosition == .right {
                    edge.width = (edge.width ?? 0) - labelOffset
                }
                switch edge.labelPosition {
                case .left:
                    edge.x -= (edge.width ?? 0) / 2 + labelOffset
                case .right:
                    edge.x += (edge.width ?? 0) / 2 + labelOffset
                default:
                    break
                }
            }
        }
    }

    // MARK: - Clusters

    /// Records the rank span of each cluster from its top/bottom border nodes.
    static func assignRankMinMax(_ g: DagreGraph) {
        for v in g.nodes() {
            guard let node = g.node(v),
                  let borderTop = node.borderTop,
                  let borderBottom = node.borderBottom
            else { continue }
            let minRank = g.node(borderTop)?.rank ?? 0
            let maxRank = g.node(borderBottom)?.rank ?? 0
            g.withNode(v) { node in
                node.minRank = minRank
                node.maxRank = maxRank
            }
        }
    }

    /// Sizes each cluster box from its border nodes' final positions, then
    /// deletes the border nodes.
    static func removeBorderNodes(_ g: DagreGraph) {
        for v in g.nodes() where !g.children(v).isEmpty {
            guard var node = g.node(v),
                  let borderTop = node.borderTop,
                  let borderBottom = node.borderBottom,
                  let top = g.node(borderTop),
                  let bottom = g.node(borderBottom),
                  let borderLeft = node.borderLeft,
                  let borderRight = node.borderRight
            else { continue }

            let leftKeys = borderLeft.orderedKeys.sorted()
            let rightKeys = borderRight.orderedKeys.sorted()
            guard let lastLeftKey = leftKeys.last,
                  let lastRightKey = rightKeys.last,
                  let leftNodeID = borderLeft[lastLeftKey],
                  let rightNodeID = borderRight[lastRightKey],
                  let left = g.node(leftNodeID),
                  let right = g.node(rightNodeID)
            else { continue }

            node.width = abs(right.x - left.x)
            node.height = abs(bottom.y - top.y)
            node.x = left.x + node.width / 2
            node.y = top.y + node.height / 2
            g.setNode(v, node)
        }

        for v in g.nodes() where g.node(v)?.dummy == .border {
            g.removeNode(v)
        }
    }

    // MARK: - Self edges

    /// Detaches self-loops before ranking; they carry no layering information
    /// and would break the DAG precondition.
    static func removeSelfEdges(_ graph: DagreGraph) {
        for edgeRef in graph.edges() where edgeRef.v == edgeRef.w {
            guard let edgeLabel = graph.edge(edgeRef) else { continue }
            graph.withNode(edgeRef.v) { $0.selfEdges.append((edge: edgeRef, label: edgeLabel)) }
            graph.removeEdge(edgeRef)
        }
    }

    /// Reserves a slot immediately to the right of each node for its self-loops,
    /// shifting the rest of the rank along.
    static func insertSelfEdges(_ graph: DagreGraph) {
        for layer in DagreUtil.buildLayerMatrix(graph) {
            var orderShift = 0
            for (index, v) in layer.enumerated() {
                guard let node = graph.node(v) else { continue }
                graph.withNode(v) { $0.order = index + orderShift }
                let rank = node.rank

                for (edge, edgeLabel) in node.selfEdges {
                    var dummy = DagreNode()
                    dummy.width = edgeLabel.width ?? 0
                    dummy.height = edgeLabel.height ?? 0
                    dummy.rank = rank
                    orderShift += 1
                    dummy.order = index + orderShift
                    dummy.edgeRef = edge
                    dummy.label = edgeLabel
                    _ = DagreUtil.addDummyNode(graph, kind: .selfEdge, data: dummy, namePrefix: "_se")
                }
            }
        }
    }

    /// Turns each self-loop placeholder into a rounded stub leaving and
    /// re-entering the right side of its node.
    static func positionSelfEdges(_ g: DagreGraph) {
        for v in g.nodes() {
            guard let node = g.node(v),
                  node.dummy == .selfEdge,
                  let edgeRef = node.edgeRef,
                  let selfNode = g.node(edgeRef.v),
                  var edgeLabel = node.label
            else { continue }

            let x = selfNode.x + selfNode.width / 2
            let y = selfNode.y
            let dx = node.x - x
            let dy = selfNode.height / 2

            edgeLabel.points = [
                DagrePoint(x: x + 2 * dx / 3, y: y - dy),
                DagrePoint(x: x + 2 * dx / 3, y: y - dy),
                DagrePoint(x: x + 5 * dx / 6, y: y - dy),
                DagrePoint(x: x + dx, y: y),
                DagrePoint(x: x + 5 * dx / 6, y: y + dy),
                DagrePoint(x: x + 2 * dx / 3, y: y + dy),
            ]
            edgeLabel.x = node.x
            edgeLabel.y = node.y
            try? g.setEdge(edgeRef, edgeLabel)
            g.removeNode(v)
        }
    }

    // MARK: - Finishing

    /// Shifts everything into the positive quadrant and records the canvas size.
    static func translateGraph(_ g: DagreGraph) {
        var minX = Float.infinity
        var maxX: Float = 0
        var minY = Float.infinity
        var maxY: Float = 0

        var graphLabel = g.graphLabel
        let marginX = graphLabel.marginX ?? 0
        let marginY = graphLabel.marginY ?? 0

        func extend(x: Float, y: Float, width: Float, height: Float) {
            minX = min(minX, x - width / 2)
            maxX = max(maxX, x + width / 2)
            minY = min(minY, y - height / 2)
            maxY = max(maxY, y + height / 2)
        }

        for v in g.nodes() {
            guard let node = g.node(v) else { continue }
            extend(x: node.x, y: node.y, width: node.width, height: node.height)
        }

        for e in g.edges() {
            guard let edge = g.edge(e), (edge.width ?? 0) > 0, (edge.height ?? 0) > 0 else { continue }
            extend(x: edge.x, y: edge.y, width: edge.width ?? 0, height: edge.height ?? 0)
        }

        minX -= marginX
        minY -= marginY

        for v in g.nodes() {
            g.withNode(v) { node in
                node.x -= minX
                node.y -= minY
            }
        }

        for e in g.edges() {
            g.withEdge(e) { edge in
                let hasLabel = (edge.width ?? 0) > 0 && (edge.height ?? 0) > 0
                if edge.points != nil {
                    edge.points = edge.points?.map { DagrePoint(x: $0.x - minX, y: $0.y - minY) }
                }
                if hasLabel {
                    edge.x -= minX
                    edge.y -= minY
                }
            }
        }

        graphLabel.width = maxX - minX + marginX
        graphLabel.height = maxY - minY + marginY
        g.graphLabel = graphLabel
    }

    /// Clips each edge's first and last segment back to the outline of the node
    /// it touches, so arrowheads land on the border rather than the centre.
    static func assignNodeIntersects(_ g: DagreGraph) {
        for e in g.edges() {
            guard var edge = g.edge(e),
                  let nodeV = g.node(e.v),
                  let nodeW = g.node(e.w)
            else { continue }

            let firstTarget: DagrePoint
            let lastTarget: DagrePoint
            if let points = edge.points, !points.isEmpty {
                firstTarget = points[0]
                lastTarget = points[points.count - 1]
            } else {
                edge.points = []
                firstTarget = DagrePoint(x: nodeW.x, y: nodeW.y)
                lastTarget = DagrePoint(x: nodeV.x, y: nodeV.y)
            }

            var points = edge.points ?? []
            points.insert(
                DagreUtil.intersectRect(
                    DagreRect(x: nodeV.x, y: nodeV.y, width: nodeV.width, height: nodeV.height),
                    firstTarget
                ),
                at: 0
            )
            points.append(
                DagreUtil.intersectRect(
                    DagreRect(x: nodeW.x, y: nodeW.y, width: nodeW.width, height: nodeW.height),
                    lastTarget
                )
            )
            edge.points = points
            try? g.setEdge(e, edge)
        }
    }

    /// Puts the route of each reversed edge back into authored order.
    static func reversePointsForReversedEdges(_ g: DagreGraph) {
        for e in g.edges() {
            g.withEdge(e) { edge in
                guard edge.reversed == true, let points = edge.points else { return }
                edge.points = points.reversed()
            }
        }
    }
}
