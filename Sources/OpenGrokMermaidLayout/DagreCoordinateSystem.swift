// DagreCoordinateSystem.swift
//
// Open Grok — Swift port of `dagre_rust::layout::coordinate_system`
// (third_party/dagre_rust/src/layout/coordinate_system.rs, W8-S2).
//
// Dagre always lays out top-to-bottom internally. Non-`tb` rank directions are
// produced by transposing the input before positioning and undoing the
// transposition afterwards.

enum DagreCoordinateSystem {
    /// Swaps width and height ahead of positioning for horizontal rank
    /// directions.
    static func adjust(_ g: DagreGraph) {
        switch g.graphLabel.rankDirection {
        case .leftToRight, .rightToLeft:
            swapWidthHeight(g)
        default:
            break
        }
    }

    /// Reverses `adjust`, then flips the axis for bottom-up/right-left.
    static func undo(_ g: DagreGraph) {
        switch g.graphLabel.rankDirection {
        case .bottomToTop, .rightToLeft:
            reverseY(g)
        default:
            break
        }

        switch g.graphLabel.rankDirection {
        case .leftToRight, .rightToLeft:
            swapXY(g)
            swapWidthHeight(g)
        default:
            break
        }
    }

    private static func swapWidthHeight(_ g: DagreGraph) {
        for v in g.nodes() {
            g.withNode(v) { node in
                let width = node.width
                node.width = node.height
                node.height = width
            }
        }
        for e in g.edges() {
            g.withEdge(e) { edge in
                let width = edge.width
                edge.width = edge.height
                edge.height = width
            }
        }
    }

    private static func reverseY(_ g: DagreGraph) {
        for v in g.nodes() {
            g.withNode(v) { $0.y = -$0.y }
        }
        for e in g.edges() {
            g.withEdge(e) { edge in
                edge.points = (edge.points ?? []).map { DagrePoint(x: $0.x, y: -$0.y) }
                edge.y = -edge.y
            }
        }
    }

    private static func swapXY(_ g: DagreGraph) {
        for v in g.nodes() {
            g.withNode(v) { node in
                let x = node.x
                node.x = node.y
                node.y = x
            }
        }
        for e in g.edges() {
            g.withEdge(e) { edge in
                edge.points = (edge.points ?? []).map { DagrePoint(x: $0.y, y: $0.x) }
                let x = edge.x
                edge.x = edge.y
                edge.y = x
            }
        }
    }
}
