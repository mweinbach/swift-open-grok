// DagreAcyclic.swift
//
// Open Grok — Swift port of `dagre_rust::layout::acyclic`
// (third_party/dagre_rust/src/layout/acyclic.rs, W8-S2).
//
// Ranking requires a DAG, so back edges are temporarily reversed here and
// restored by `undo` once the geometry is known.

enum DagreAcyclic {
    /// Reverses every edge in a depth-first feedback arc set, tagging each with
    /// `reversed` so `undo` can put it back.
    static func run(_ graph: DagreGraph) {
        // Only the DFS feedback-arc-set is implemented; upstream leaves the
        // "greedy" acyclicer unimplemented too and falls through to this path.
        let feedbackArcSet = depthFirstFeedbackArcSet(graph)

        for edge in feedbackArcSet {
            guard var label = graph.edge(edge) else { continue }
            graph.removeEdge(edge)
            label.forwardName = edge.name
            label.reversed = true
            try? graph.setEdge(edge.w, edge.v, label, name: "rev\(graph.nextUniqueID())")
        }
    }

    /// Edges that close a cycle, found by a depth-first walk in node insertion
    /// order.
    private static func depthFirstFeedbackArcSet(_ graph: DagreGraph) -> [GraphEdgeRef] {
        var feedbackArcSet: [GraphEdgeRef] = []
        var onStack = Set<String>()
        var visited = Set<String>()

        func visit(_ nodeID: String) {
            guard visited.insert(nodeID).inserted else { return }
            onStack.insert(nodeID)
            for edge in graph.outEdges(nodeID) ?? [] {
                if onStack.contains(edge.w) {
                    feedbackArcSet.append(edge)
                } else {
                    visit(edge.w)
                }
            }
            onStack.remove(nodeID)
        }

        for nodeID in graph.nodes() {
            visit(nodeID)
        }
        return feedbackArcSet
    }

    /// Restores every reversed edge to its authored direction and name.
    static func undo(_ g: DagreGraph) {
        for e in g.edges() {
            guard let edge = g.edge(e), edge.reversed == true else { continue }
            var label = edge
            let forwardName = label.forwardName
            label.reversed = nil
            label.forwardName = nil
            try? g.setEdge(e.w, e.v, label, name: forwardName)
        }
    }
}
