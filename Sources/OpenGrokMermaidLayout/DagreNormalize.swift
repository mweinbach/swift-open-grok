// DagreNormalize.swift
//
// Open Grok — Swift port of `dagre_rust::layout::normalize`
// (third_party/dagre_rust/src/layout/normalize/mod.rs, W8-S2).
//
// Ordering and coordinate assignment both assume every edge spans exactly one
// rank. `run` splits longer edges into chains of dummy nodes; `undo` collapses
// each chain back into the original edge, the dummies' positions becoming its
// route.

enum DagreNormalize {
    /// Replaces every multi-rank edge with a chain of unit-length segments.
    static func run(_ g: DagreGraph) {
        g.withGraphLabel { $0.dummyChains = [] }
        for edgeRef in g.edges() {
            normalizeEdge(g, edgeRef)
        }
    }

    private static func normalizeEdge(_ g: DagreGraph, _ e: GraphEdgeRef) {
        var v = e.v
        let w = e.w
        var vRank = g.node(v)?.rank ?? 0
        let wRank = g.node(w)?.rank ?? 0

        guard var edgeLabel = g.edge(e) else { return }
        edgeLabel.points = []
        g.withEdge(e) { $0.points = [] }

        let weight = edgeLabel.weight
        let labelRank = edgeLabel.labelRank ?? 0

        if wRank == vRank + 1 { return }

        g.removeEdge(e)

        var isFirst = true
        vRank += 1
        while vRank < wRank {
            var attributes = DagreNode()
            attributes.edgeLabel = edgeLabel
            attributes.edgeObj = e
            attributes.rank = vRank

            var kind = DagreDummyKind.edge
            if vRank == labelRank {
                attributes.width = edgeLabel.width ?? 0
                attributes.height = edgeLabel.height ?? 0
                attributes.labelPosition = edgeLabel.labelPosition
                kind = .edgeLabel
            }

            let dummy = DagreUtil.addDummyNode(g, kind: kind, data: attributes, namePrefix: "_d")
            var segment = DagreEdge()
            segment.weight = weight
            try? g.setEdge(v, dummy, segment)

            if isFirst {
                g.withGraphLabel { label in
                    var chains = label.dummyChains ?? []
                    chains.append(dummy)
                    label.dummyChains = chains
                }
                isFirst = false
            }

            v = dummy
            vRank += 1
        }

        var lastSegment = DagreEdge()
        lastSegment.weight = weight
        try? g.setEdge(v, w, lastSegment)
    }

    /// Walks each dummy chain, removing the dummies and turning their centres
    /// into the original edge's polyline.
    static func undo(_ g: DagreGraph) {
        guard let dummyChains = g.graphLabel.dummyChains else { return }

        for chainStart in dummyChains {
            guard var node = g.node(chainStart), let edgeObj = node.edgeObj else { continue }
            var originalLabel = node.edgeLabel ?? DagreEdge()
            var points = originalLabel.points ?? []
            var v = chainStart

            while node.dummy != nil {
                let successor = g.successors(v)?.first
                g.removeNode(v)
                points.append(DagrePoint(x: node.x, y: node.y))
                if node.dummy == .edgeLabel {
                    originalLabel.x = node.x
                    originalLabel.y = node.y
                    originalLabel.width = node.width
                    originalLabel.height = node.height
                }
                guard let successor, let next = g.node(successor) else { break }
                v = successor
                node = next
            }

            originalLabel.points = points
            try? g.setEdge(edgeObj, originalLabel)
        }
    }
}
