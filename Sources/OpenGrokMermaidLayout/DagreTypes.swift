// DagreTypes.swift
//
// Open Grok — Swift port of the label types in `dagre_rust`
// (third_party/dagre_rust/src/lib.rs, W8-S2 / CRATE_MAP.md row 1). Dagre is the
// layered graph-drawing algorithm from Gansner et al., "A Technique for Drawing
// Directed Graphs"; see THIRD-PARTY-NOTICES ("dagre_rust" and the
// "mermaid.js / dagre.js / graphlib.js ancestry" entry).
//
// Coordinates are `Float` (32-bit) rather than `Double` deliberately: the Rust
// crate computes in `f32`, and the barycenter/compaction passes accumulate
// enough that widening the type shifts node positions relative to the reference.

/// A point on a routed edge polyline.
public struct DagrePoint: Equatable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float = 0, y: Float = 0) {
        self.x = x
        self.y = y
    }
}

/// Which side of a cluster a border node guards.
/// Matches `add_border_segments::BorderTypeName`.
public enum DagreBorderType: Equatable, Sendable {
    case left
    case right
}

/// Why a node was synthesized by the pipeline. Author-declared nodes have none.
/// Matches the string tags stored in `GraphNode::dummy`.
public enum DagreDummyKind: String, Equatable, Sendable {
    /// Placeholder marking the rank an edge label will occupy.
    case edgeProxy = "edge-proxy"
    /// Root of the nesting graph that keeps clusters connected.
    case root
    /// Cluster boundary node (top/bottom/left/right).
    case border
    /// Stand-in for a self-loop, positioned then converted back to a polyline.
    case selfEdge = "selfedge"
    /// Waypoint splitting a multi-rank edge into unit-length segments.
    case edge
    /// Like `edge`, but also carrying the edge's label box.
    case edgeLabel = "edge-label"
}

/// Rank direction: the axis ranks advance along. Matches `GraphConfig::rankdir`.
public enum DagreRankDirection: String, Equatable, Sendable {
    case topToBottom = "tb"
    case bottomToTop = "bt"
    case leftToRight = "lr"
    case rightToLeft = "rl"
}

/// Where an edge label sits relative to its edge. Matches `labelpos`.
public enum DagreLabelPosition: String, Equatable, Sendable {
    case left = "l"
    case right = "r"
    case center = "c"
}

/// Which rank-assignment algorithm to run. Matches `GraphConfig::ranker`.
public enum DagreRanker: String, Equatable, Sendable {
    case networkSimplex = "network-simplex"
    case tightTree = "tight-tree"
    case longestPath = "longest-path"
}

/// Which of the four Brandes–Köpf alignments to take coordinates from, instead
/// of averaging them. Matches `GraphConfig::align`.
public enum DagreAlignment: String, Equatable, Sendable {
    case upLeft = "ul"
    case upRight = "ur"
    case downLeft = "dl"
    case downRight = "dr"
}

/// A node label: input geometry plus every field the pipeline annotates onto it.
public struct DagreNode: Sendable {
    // Input geometry. `x`/`y` are the node centre once layout finishes.
    public var x: Float = 0
    public var y: Float = 0
    public var width: Float = 0
    public var height: Float = 0

    /// Label box carried by a self-edge dummy.
    public var label: DagreEdge?
    /// Set on synthesized nodes; nil for author-declared ones.
    public var dummy: DagreDummyKind?

    // Rank/order assignment.
    public var rank: Int?
    public var minRank: Int?
    public var maxRank: Int?
    public var order: Int?

    // Cluster boundary bookkeeping.
    public var borderTop: String?
    public var borderBottom: String?
    public var borderLeft: OrderedDictionary<Int, String>?
    public var borderRight: OrderedDictionary<Int, String>?
    /// The single left/right border node for the rank a layer graph was built
    /// for. Matches `border_left_` / `border_right_`.
    public var borderLeftForRank: String?
    public var borderRightForRank: String?
    public var borderType: DagreBorderType?

    // Network-simplex tree bookkeeping.
    public var low: Int?
    public var lim: Int?
    public var parent: String?

    // Edge-dummy bookkeeping.
    /// The original edge this dummy stands in for.
    public var edgeRef: GraphEdgeRef?
    public var edgeLabel: DagreEdge?
    public var edgeObj: GraphEdgeRef?
    public var labelPosition: DagreLabelPosition?

    /// Self-loops stripped off this node before ranking, restored afterwards.
    public var selfEdges: [(edge: GraphEdgeRef, label: DagreEdge)] = []

    public init() {}
}

/// An edge label: input weights plus the route computed for it.
public struct DagreEdge: Sendable {
    /// Name the edge had before `acyclic` reversed it.
    public var forwardName: String?
    /// True while the edge points against its authored direction.
    public var reversed: Bool?
    /// Minimum rank span. Defaults to 1.
    public var minlen: Float? = 1
    /// Pull strength during ranking and ordering. Defaults to 1.
    public var weight: Float? = 1
    /// Label box size; zero means the edge carries no label.
    public var width: Float? = 0
    public var height: Float? = 0
    /// Rank the label was assigned by `injectEdgeLabelProxies`.
    public var labelRank: Int?
    public var labelOffset: Float? = 0
    public var labelPosition: DagreLabelPosition? = .right
    /// True for the synthetic edges holding clusters together.
    public var nestingEdge: Bool?
    /// Network-simplex cut value; negative means the tree edge can be improved.
    public var cutValue: Float?
    /// Routed polyline, populated by `normalize.undo`.
    public var points: [DagrePoint]?
    /// Label centre.
    public var x: Float = 0
    public var y: Float = 0

    public init() {}
}

/// The graph label: layout settings in, canvas size out.
public struct DagreGraphConfig: Sendable {
    /// Overall canvas size, written by `translateGraph`.
    public var width: Float = 0
    public var height: Float = 0

    /// Horizontal gap between nodes on a rank.
    public var nodeSeparation: Float? = 50
    /// Horizontal gap between edge dummies on a rank.
    public var edgeSeparation: Float? = 20
    /// Vertical gap between ranks.
    public var rankSeparation: Float? = 50
    public var marginX: Float?
    public var marginY: Float?
    public var rankDirection: DagreRankDirection? = .topToBottom
    /// Cycle-breaking strategy. Only the DFS feedback-arc-set is implemented.
    public var acyclicer: String?
    public var ranker: DagreRanker?
    public var alignment: DagreAlignment?

    // Written by the pipeline itself.
    public var nestingRoot: String?
    public var root: String?
    public var nodeRankFactor: Float?
    public var dummyChains: [String]?

    public init() {}
}

/// The graph shape the whole Dagre pipeline operates on.
public typealias DagreGraph = Graph<DagreGraphConfig, DagreNode, DagreEdge>

extension Graph where GraphLabel == DagreGraphConfig, NodeLabel == DagreNode, EdgeLabel == DagreEdge {
    /// Creates a Dagre-shaped graph with the conventional label defaults.
    public static func makeDagreGraph(
        directed: Bool = true,
        multigraph: Bool = false,
        compound: Bool = false
    ) -> DagreGraph {
        DagreGraph(
            directed: directed,
            multigraph: multigraph,
            compound: compound,
            label: DagreGraphConfig(),
            defaultNodeLabel: DagreNode(),
            defaultEdgeLabel: DagreEdge()
        )
    }
}
