// Graph.swift
//
// Open Grok — Swift port of the `graphlib_rust` crate
// (third_party/graphlib_rust/src/graph.rs, W8-S2 / CRATE_MAP.md row 2), which is
// itself a port of graphlib.js from the dagre project. See THIRD-PARTY-NOTICES
// ("graphlib_rust" and the "mermaid.js / dagre.js / graphlib.js ancestry" entry).
//
// Every adjacency structure is an `OrderedDictionary`, so `nodes()`, `edges()`,
// `predecessors(_:)`, and `successors(_:)` all iterate in insertion order. The
// Dagre pipeline relies on that: its output is a pure function of the order in
// which nodes and edges were declared.

/// Sentinel node id for the implicit root of a compound graph.
/// Matches `graphlib_rust::graph::GRAPH_NODE`.
public let graphRootNodeID = "\u{0}"

/// Default name given to an unnamed edge. Matches `DEFAULT_EDGE_NAME`.
public let defaultEdgeName = "\u{0}"

/// Delimiter joining the parts of a composite edge id. Matches `EDGE_KEY_DELIM`.
public let edgeKeyDelimiter = "\u{1}"

/// An edge identified by its endpoints and an optional name (multigraphs only).
public struct GraphEdgeRef: Hashable, Sendable {
    public var v: String
    public var w: String
    public var name: String?

    public init(v: String, w: String, name: String? = nil) {
        self.v = v
        self.w = w
        self.name = name
    }
}

/// Errors raised by the mutating graph operations that can fail.
public enum GraphError: Error, Equatable, Sendable {
    case notCompound
    case cycleInParentChain(child: String, parent: String)
    case namedEdgeOnSimpleGraph
}

/// A directed/undirected, optionally multi- and compound graph.
///
/// Reference-typed to match the `&mut Graph` threading of the Rust original;
/// the layout pipeline mutates a single graph in place across ~25 passes.
public final class Graph<GraphLabel, NodeLabel, EdgeLabel> {
    public let isDirected: Bool
    public let isMultigraph: Bool
    public let isCompound: Bool

    private var label: GraphLabel
    private let defaultNodeLabel: NodeLabel
    private let defaultEdgeLabel: EdgeLabel

    private var nodeLabels = OrderedDictionary<String, NodeLabel>()
    private var inEdges = OrderedDictionary<String, OrderedDictionary<String, GraphEdgeRef>>()
    private var preds = OrderedDictionary<String, OrderedDictionary<String, Int>>()
    private var outEdges = OrderedDictionary<String, OrderedDictionary<String, GraphEdgeRef>>()
    private var sucs = OrderedDictionary<String, OrderedDictionary<String, Int>>()
    private var edgeObjs = OrderedDictionary<String, GraphEdgeRef>()
    private var edgeLabels = OrderedDictionary<String, EdgeLabel>()
    private var parents = OrderedDictionary<String, String>()
    private var childSets = OrderedDictionary<String, OrderedDictionary<String, Bool>>()

    public private(set) var nodeCount = 0
    public private(set) var edgeCount = 0

    // Monotonic counter backing `nextUniqueID()`.
    //
    // Deviation from `dagre_rust::layout::util::unique_id`, which reads a
    // process-global atomic: scoping the counter to the graph makes the dummy
    // node ids a pure function of the input, so two renders of the same source
    // in one process produce identical ids rather than merely identical
    // geometry. Collisions with author-chosen ids are still ruled out by the
    // `while hasNode` retry loop in `addDummyNode`.
    private var uniqueIDCounter = 0

    public init(
        directed: Bool = true,
        multigraph: Bool = false,
        compound: Bool = false,
        label: GraphLabel,
        defaultNodeLabel: NodeLabel,
        defaultEdgeLabel: EdgeLabel
    ) {
        self.isDirected = directed
        self.isMultigraph = multigraph
        self.isCompound = compound
        self.label = label
        self.defaultNodeLabel = defaultNodeLabel
        self.defaultEdgeLabel = defaultEdgeLabel
        if compound {
            childSets.insert(OrderedDictionary(), forKey: graphRootNodeID)
        }
    }

    /// Returns the next id in this graph's private sequence, starting at 1.
    public func nextUniqueID() -> Int {
        uniqueIDCounter += 1
        return uniqueIDCounter
    }

    // MARK: - Graph label

    public var graphLabel: GraphLabel {
        get { label }
        set { label = newValue }
    }

    /// Mutates the graph label in place.
    public func withGraphLabel<R>(_ body: (inout GraphLabel) -> R) -> R {
        body(&label)
    }

    // MARK: - Nodes

    public func nodes() -> [String] { nodeLabels.orderedKeys }

    /// Node ids with no in-edges.
    public func sources() -> [String] {
        nodes().filter { (inEdges[$0]?.isEmpty ?? true) }
    }

    /// Node ids with no out-edges.
    public func sinks() -> [String] {
        nodes().filter { (outEdges[$0]?.isEmpty ?? true) }
    }

    public func hasNode(_ v: String) -> Bool { nodeLabels.containsKey(v) }

    public func node(_ v: String) -> NodeLabel? { nodeLabels[v] }

    /// Mutates the label of `v` in place; no-op when `v` is absent.
    @discardableResult
    public func withNode<R>(_ v: String, _ body: (inout NodeLabel) -> R) -> R? {
        nodeLabels.withValue(forKey: v, body)
    }

    /// Creates `v` if absent, or replaces its label when one is supplied.
    /// Matches `Graph::set_node`: passing `nil` for an existing node is a no-op.
    public func setNode(_ v: String, _ value: NodeLabel? = nil) {
        if nodeLabels.containsKey(v) {
            if let value {
                nodeLabels.insert(value, forKey: v)
            }
            return
        }

        nodeLabels.insert(value ?? defaultNodeLabel, forKey: v)

        if isCompound {
            parents.insert(graphRootNodeID, forKey: v)
            childSets.insert(OrderedDictionary(), forKey: v)
            childSets.withValue(forKey: graphRootNodeID, default: OrderedDictionary()) { children in
                if !children.containsKey(v) {
                    children.insert(true, forKey: v)
                }
            }
        }

        inEdges.insert(OrderedDictionary(), forKey: v)
        preds.insert(OrderedDictionary(), forKey: v)
        outEdges.insert(OrderedDictionary(), forKey: v)
        sucs.insert(OrderedDictionary(), forKey: v)
        nodeCount += 1
    }

    /// Removes `v` and every edge incident on it.
    public func removeNode(_ v: String) {
        guard nodeLabels.containsKey(v) else { return }
        nodeLabels.removeValue(forKey: v)

        if isCompound {
            removeFromParentsChildList(v)
            parents.removeValue(forKey: v)
            for child in children(v) {
                try? setParent(child, nil)
            }
            childSets.removeValue(forKey: v)
        }

        if let incoming = inEdges[v] {
            for edgeID in incoming.orderedKeys {
                if let edge = edgeObjs[edgeID] {
                    removeEdge(edge)
                }
            }
            inEdges.removeValue(forKey: v)
        }
        preds.removeValue(forKey: v)

        if let outgoing = outEdges[v] {
            for edgeID in outgoing.orderedKeys {
                if let edge = edgeObjs[edgeID] {
                    removeEdge(edge)
                }
            }
            outEdges.removeValue(forKey: v)
        }
        sucs.removeValue(forKey: v)
        nodeCount -= 1
    }

    // MARK: - Compound hierarchy

    /// Sets `parent` as the parent of `v`, or detaches `v` when `parent` is nil.
    public func setParent(_ v: String, _ parent: String?) throws {
        guard isCompound else { throw GraphError.notCompound }

        let resolvedParent: String
        if let parent {
            var ancestor = parent
            while let next = self.parent(ancestor) {
                if next == v {
                    throw GraphError.cycleInParentChain(child: v, parent: parent)
                }
                ancestor = next
            }
            setNode(parent)
            resolvedParent = parent
        } else {
            resolvedParent = graphRootNodeID
        }

        setNode(v)
        removeFromParentsChildList(v)
        parents.insert(resolvedParent, forKey: v)
        childSets.withValue(forKey: resolvedParent, default: OrderedDictionary()) { children in
            children.insert(true, forKey: v)
        }
    }

    private func removeFromParentsChildList(_ v: String) {
        guard let parent = parents[v] else { return }
        childSets.withValue(forKey: parent) { children in
            children.removeValue(forKey: v)
        }
    }

    /// The parent of `v`, or nil when `v` sits at the top level.
    public func parent(_ v: String) -> String? {
        guard isCompound, let parent = parents[v], parent != graphRootNodeID else { return nil }
        return parent
    }

    /// Direct children of `v`. For a non-compound graph, `children(graphRootNodeID)`
    /// is every node — matching `Graph::children`.
    public func children(_ v: String) -> [String] {
        if isCompound {
            if let set = childSets[v] {
                return set.orderedKeys
            }
        } else if v == graphRootNodeID {
            return nodeLabels.orderedKeys
        }
        return []
    }

    // MARK: - Adjacency

    public func predecessors(_ v: String) -> [String]? {
        preds[v]?.orderedKeys
    }

    public func successors(_ v: String) -> [String]? {
        sucs[v]?.orderedKeys
    }

    /// Predecessors and successors of `v` with duplicates removed, in
    /// predecessor-then-successor insertion order.
    ///
    /// Deviation from `Graph::neighbors`, which collects into a `HashSet` and so
    /// returns them in an unspecified order. That order feeds
    /// `dfs_assign_low_lim` in the network simplex ranker, where it would make
    /// low/lim numbering — and therefore the final ranks — vary per process.
    public func neighbors(_ v: String) -> [String]? {
        guard let predecessors = predecessors(v) else { return nil }
        var seen = Set<String>()
        var result: [String] = []
        for u in predecessors where seen.insert(u).inserted {
            result.append(u)
        }
        for u in successors(v) ?? [] where seen.insert(u).inserted {
            result.append(u)
        }
        return result
    }

    // MARK: - Edges

    public func edges() -> [GraphEdgeRef] { edgeObjs.values }

    public func hasEdge(_ v: String, _ w: String, name: String? = nil) -> Bool {
        edgeLabels.containsKey(edgeID(v, w, name))
    }

    public func hasEdge(_ e: GraphEdgeRef) -> Bool {
        edgeLabels.containsKey(edgeID(e.v, e.w, e.name))
    }

    public func edge(_ v: String, _ w: String, name: String? = nil) -> EdgeLabel? {
        edgeLabels[edgeID(v, w, name)]
    }

    public func edge(_ e: GraphEdgeRef) -> EdgeLabel? {
        edgeLabels[edgeID(e.v, e.w, e.name)]
    }

    /// Mutates the label of an edge in place; no-op when the edge is absent.
    @discardableResult
    public func withEdge<R>(_ v: String, _ w: String, name: String? = nil, _ body: (inout EdgeLabel) -> R) -> R? {
        edgeLabels.withValue(forKey: edgeID(v, w, name), body)
    }

    @discardableResult
    public func withEdge<R>(_ e: GraphEdgeRef, _ body: (inout EdgeLabel) -> R) -> R? {
        edgeLabels.withValue(forKey: edgeID(e.v, e.w, e.name), body)
    }

    /// Creates the edge (and its endpoints) if absent, or replaces its label
    /// when one is supplied.
    public func setEdge(_ v: String, _ w: String, _ value: EdgeLabel? = nil, name: String? = nil) throws {
        let id = edgeID(v, w, name)
        if edgeLabels.containsKey(id) {
            if let value {
                edgeLabels.insert(value, forKey: id)
            }
            return
        }

        if name != nil && !isMultigraph {
            throw GraphError.namedEdgeOnSimpleGraph
        }

        setNode(v)
        setNode(w)
        edgeLabels.insert(value ?? defaultEdgeLabel, forKey: id)

        let edge = edgeRef(v, w, name)
        edgeObjs.insert(edge, forKey: id)
        preds.withValue(forKey: edge.w) { entry in
            entry.insert((entry[edge.v] ?? 0) + 1, forKey: edge.v)
        }
        sucs.withValue(forKey: edge.v) { entry in
            entry.insert((entry[edge.w] ?? 0) + 1, forKey: edge.w)
        }
        inEdges.withValue(forKey: edge.w, default: OrderedDictionary()) { entry in
            entry.insert(edge, forKey: id)
        }
        outEdges.withValue(forKey: edge.v, default: OrderedDictionary()) { entry in
            entry.insert(edge, forKey: id)
        }
        edgeCount += 1
    }

    public func setEdge(_ e: GraphEdgeRef, _ value: EdgeLabel? = nil) throws {
        // Matches `set_edge_with_obj`, which drops the name: the layout pipeline
        // re-keys reversed and dummy edges by endpoints only.
        try setEdge(e.v, e.w, value, name: nil)
    }

    public func removeEdge(_ v: String, _ w: String, name: String? = nil) {
        let id = edgeID(v, w, name)
        guard let edge = edgeObjs[id] else { return }
        edgeLabels.removeValue(forKey: id)
        edgeObjs.removeValue(forKey: id)
        preds.withValue(forKey: edge.w) { entry in
            if let count = entry[edge.v] {
                if count <= 1 {
                    entry.removeValue(forKey: edge.v)
                } else {
                    entry.insert(count - 1, forKey: edge.v)
                }
            }
        }
        sucs.withValue(forKey: edge.v) { entry in
            if let count = entry[edge.w] {
                if count <= 1 {
                    entry.removeValue(forKey: edge.w)
                } else {
                    entry.insert(count - 1, forKey: edge.w)
                }
            }
        }
        inEdges.withValue(forKey: edge.w) { $0.removeValue(forKey: id) }
        outEdges.withValue(forKey: edge.v) { $0.removeValue(forKey: id) }
        edgeCount -= 1
    }

    public func removeEdge(_ e: GraphEdgeRef) {
        removeEdge(e.v, e.w, name: nil)
    }

    /// Edges pointing at `v`, optionally narrowed to those originating at `u`.
    public func inEdges(_ v: String, from u: String? = nil) -> [GraphEdgeRef]? {
        guard let incoming = inEdges[v] else { return nil }
        let all = incoming.values
        guard let u else { return all }
        return all.filter { $0.v == u }
    }

    /// Edges leaving `v`, optionally narrowed to those pointing at `w`.
    public func outEdges(_ v: String, to w: String? = nil) -> [GraphEdgeRef]? {
        guard let outgoing = outEdges[v] else { return nil }
        let all = outgoing.values
        guard let w else { return all }
        return all.filter { $0.w == w }
    }

    /// Every edge incident on `v` regardless of direction, in-edges first.
    public func nodeEdges(_ v: String, other w: String? = nil) -> [GraphEdgeRef]? {
        guard var incident = inEdges(v, from: w) else { return nil }
        incident.append(contentsOf: outEdges(v, to: w) ?? [])
        return incident
    }

    // MARK: - Edge identity

    private func edgeRef(_ v: String, _ w: String, _ name: String?) -> GraphEdgeRef {
        if !isDirected && v > w {
            return GraphEdgeRef(v: w, w: v, name: name)
        }
        return GraphEdgeRef(v: v, w: w, name: name)
    }

    private func edgeID(_ v: String, _ w: String, _ name: String?) -> String {
        let (tail, head) = (!isDirected && v > w) ? (w, v) : (v, w)
        return tail + edgeKeyDelimiter + head + edgeKeyDelimiter + (name ?? defaultEdgeName)
    }
}
