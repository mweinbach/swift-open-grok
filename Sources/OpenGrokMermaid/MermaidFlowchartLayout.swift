// MermaidFlowchartLayout.swift
//
// Open Grok — Swift port of `mermaid_to_svg::layout`
// (third_party/mermaid-to-svg/src/layout.rs, W8-S2).
//
// Turns a parsed flowchart into placed boxes and routed polylines. Node ranking
// and coordinates come from the Dagre port in OpenGrokMermaidLayout; everything
// here is the Mermaid-specific work around it — measuring shapes, building the
// Dagre graph, and post-processing routes (back edges, straightening, cluster
// trimming, boundary clipping).
//
// Deviation from upstream: every map whose iteration order can reach the output
// is an `OrderedDictionary` rather than a `HashMap`. Upstream averages node
// coordinates while iterating a `HashMap`, so its subgraph centring varies with
// hash order in the last floating-point bits; keyed insertion order removes
// that.

import Foundation
import OpenGrokMermaidLayout

/// A placed node.
public struct MermaidLayoutNode: Equatable, Sendable {
    public var id: String
    /// Centre of the shape.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var shape: NodeShape
    public var label: String
    /// From a `style` statement, overriding the theme.
    public var fillColor: String?
    public var strokeColor: String?
}

/// A routed edge.
public struct MermaidLayoutEdge: Equatable, Sendable {
    public var from: String
    public var to: String
    public var label: String?
    public var style: EdgeStyle
    /// Polyline from the source outline to the target outline.
    public var points: [MermaidPoint]
    /// Centre of the label box, when the edge has a label.
    public var labelPosition: MermaidPoint?
}

/// A placed cluster box.
public struct MermaidLayoutSubgraph: Equatable, Sendable {
    public var id: String
    public var title: String?
    /// Top-left corner.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
}

public struct MermaidPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The geometry of a laid-out diagram: the intermediate representation between
/// parsing and rendering, and the form a terminal front end should consume.
public struct MermaidLayoutResult: Equatable, Sendable {
    /// Nodes in declaration order.
    public var nodes: [MermaidLayoutNode]
    public var edges: [MermaidLayoutEdge]
    public var subgraphs: [MermaidLayoutSubgraph]
    public var width: Double
    public var height: Double

    public func node(id: String) -> MermaidLayoutNode? {
        nodes.first { $0.id == id }
    }
}

/// Tunables from the frontmatter's `flowchart:` config.
struct FlowchartLayoutOptions {
    var nodeSpacing: Double = FlowchartLayoutEngine.defaultNodeSeparation
    var rankSpacing: Double = FlowchartLayoutEngine.defaultRankSeparation
    var padding: Double = FlowchartLayoutEngine.defaultPadding
    var wrappingWidth: Double = MermaidTextWrap.defaultWrapWidth
    var fontSize: Double = MermaidTextWrap.defaultFontSize

    init() {}

    init(_ config: RenderConfig) {
        let defaults = FlowchartLayoutOptions()
        nodeSpacing = config.flowchart.nodeSpacing.map(Double.init) ?? defaults.nodeSpacing
        rankSpacing = config.flowchart.rankSpacing.map(Double.init) ?? defaults.rankSpacing
        padding = config.flowchart.padding.map(Double.init) ?? defaults.padding
        wrappingWidth = config.flowchart.wrappingWidth.map(Double.init) ?? defaults.wrappingWidth
        fontSize = config.fontSizePixels() ?? defaults.fontSize
    }
}

/// Lays out a flowchart or state diagram.
public func computeFlowchartLayout(
    _ graph: FlowchartGraph,
    config: RenderConfig = RenderConfig()
) -> MermaidLayoutResult {
    FlowchartLayoutEngine(graph, options: FlowchartLayoutOptions(config)).compute()
}

struct FlowchartLayoutEngine {
    static let defaultPadding: Double = 15
    static let defaultNodeSeparation: Double = 50
    static let defaultRankSeparation: Double = 50

    private static let edgeLabelPadding: Double = 2
    private static let margin: Double = 8
    private static let subgraphPadding: Double = 8
    private static let subgraphTitleHeight: Double = 24
    private static let stateNodeWidthPadding: Double = 6
    private static let stateNodeHeightPadding: Double = 16
    private static let stateNodeMinHeight: Double = 40
    private static let stateDiamondPadding: Double = 18
    private static let stateForkWidth: Double = 70
    private static let stateForkHeight: Double = 7

    private struct NodeInfo {
        var id: String
        var label: String
        var shape: NodeShape
        var width: Double
        var height: Double
        var order: Int
    }

    private struct EdgeInfo {
        var from: String
        var to: String
        var label: String?
        var style: EdgeStyle
    }

    private struct SubgraphInfo {
        var id: String
        var title: String?
        var parentSubgraphID: String?
    }

    private let graph: FlowchartGraph
    private let options: FlowchartLayoutOptions
    private let isStateDiagram: Bool

    private var nodes = OrderedDictionary<String, NodeInfo>()
    private var edges: [EdgeInfo] = []
    private var subgraphs: [SubgraphInfo] = []
    private var adjacency = OrderedDictionary<String, [String]>()
    private var reverseAdjacency = OrderedDictionary<String, [String]>()
    private var nodeToSubgraph = OrderedDictionary<String, String>()
    private var nodeStyles = OrderedDictionary<String, [(key: String, value: String)]>()
    private var nextNodeOrder = 0

    init(_ graph: FlowchartGraph, options: FlowchartLayoutOptions = FlowchartLayoutOptions()) {
        self.graph = graph
        self.options = options
        self.isStateDiagram = graph.containsStateShapes
        collect(graph.statements, in: nil)
    }

    // MARK: - Collection

    private mutating func collect(_ statements: [FlowchartStatement], in subgraphID: String?) {
        for statement in statements {
            switch statement {
            case let .node(node):
                guard !isSubgraphID(node.id) else { continue }
                addNode(node)
                if let subgraphID, !nodeToSubgraph.containsKey(node.id) {
                    nodeToSubgraph.insert(subgraphID, forKey: node.id)
                }

            case let .edge(edge):
                ensureNodeExists(edge.from)
                ensureNodeExists(edge.to)

                if let subgraphID {
                    // A node first mentioned inside a subgraph belongs to it.
                    for endpoint in [edge.from, edge.to]
                    where !isSubgraphID(endpoint) && !nodeToSubgraph.containsKey(endpoint) {
                        nodeToSubgraph.insert(subgraphID, forKey: endpoint)
                    }
                }

                adjacency.withValue(forKey: edge.from, default: []) { $0.append(edge.to) }
                reverseAdjacency.withValue(forKey: edge.to, default: []) { $0.append(edge.from) }
                edges.append(
                    EdgeInfo(from: edge.from, to: edge.to, label: edge.label, style: edge.style)
                )

            case let .subgraph(subgraph):
                subgraphs.append(
                    SubgraphInfo(
                        id: subgraph.id,
                        title: subgraph.title ?? subgraph.id,
                        parentSubgraphID: subgraphID
                    )
                )
                collect(subgraph.statements, in: subgraph.id)

            case let .style(style):
                nodeStyles.insert(style.properties, forKey: style.nodeID)
            }
        }
    }

    private mutating func addNode(_ node: FlowchartNode) {
        guard !isSubgraphID(node.id) else { return }
        // A later bare mention never overwrites an earlier labelled declaration.
        if nodes.containsKey(node.id) && node.label == nil { return }

        let label = node.label ?? node.id
        let size = measureNode(label: label, shape: node.shape)
        let order = nodes[node.id]?.order ?? takeNextOrder()

        nodes.insert(
            NodeInfo(
                id: node.id,
                label: label,
                shape: node.shape,
                width: size.width,
                height: size.height,
                order: order
            ),
            forKey: node.id
        )
    }

    private mutating func ensureNodeExists(_ id: String) {
        guard !isSubgraphID(id), !nodes.containsKey(id) else { return }
        let size = measureNode(label: id, shape: .rectangle)
        nodes.insert(
            NodeInfo(
                id: id,
                label: id,
                shape: .rectangle,
                width: size.width,
                height: size.height,
                order: takeNextOrder()
            ),
            forKey: id
        )
    }

    private mutating func takeNextOrder() -> Int {
        defer { nextNodeOrder += 1 }
        return nextNodeOrder
    }

    private func isSubgraphID(_ id: String) -> Bool {
        subgraphs.contains { $0.id == id }
    }

    // MARK: - Measurement

    private var charWidth: Double {
        MermaidTextWrap.scaleCharWidth(
            isStateDiagram ? MermaidTextWrap.stateCharWidth : MermaidTextWrap.defaultCharWidth,
            fontSize: options.fontSize
        )
    }

    /// Node box size for a label, mirroring mermaid.js's per-shape sizing in
    /// `rendering-util/rendering-elements/shapes/*.ts`.
    private func measureNode(label: String, shape: NodeShape) -> (width: Double, height: Double) {
        let charWidth = self.charWidth
        let lines = MermaidTextWrap.wrapTextLines(
            label,
            maxWidth: options.wrappingWidth,
            charWidth: charWidth
        )
        let text = MermaidTextWrap.measure(
            lines: lines,
            charWidth: charWidth,
            fontSize: options.fontSize
        )
        let padding = options.padding

        if isStateDiagram {
            switch shape {
            case .roundedRectangle:
                return (
                    max(text.width + Self.stateNodeWidthPadding, 32),
                    max(text.height + Self.stateNodeHeightPadding, Self.stateNodeMinHeight)
                )
            case .diamond:
                let size = max(
                    max(text.width + Self.stateDiamondPadding, text.height + Self.stateDiamondPadding),
                    Self.stateNodeMinHeight
                )
                return (size, size)
            case .startState, .endState:
                return (14, 14)
            case .forkJoin:
                return (Self.stateForkWidth, Self.stateForkHeight)
            default:
                break
            }
        }

        switch shape {
        case .rectangle:
            return (text.width + padding * 4, text.height + padding * 2)
        case .roundedRectangle:
            return (text.width + padding * 2, text.height + padding * 2)
        case .subroutine:
            return (text.width + padding + 16, text.height + padding)
        case .asymmetric:
            let height = text.height + padding
            return (text.width + padding + height / 4, height)
        case .hexagon:
            return ((text.width + padding * 2.5) * 7 / 6, text.height + padding)
        case .diamond:
            let size = (text.width + padding) + (text.height + padding)
            return (size, size)
        case .circle:
            let diameter = text.width + padding
            return (diameter, diameter)
        case .startState:
            return (14, 14)
        case .endState:
            return (20, 20)
        case .forkJoin:
            return (70, 10)
        case .stadium:
            let height = text.height + padding
            return (text.width + height / 4 + padding, height)
        case .cylinder:
            let width = text.width + padding
            let rx = width / 2
            let ry = rx / (2.5 + width / 50)
            return (width, text.height + ry + padding + 2 * ry)
        }
    }

    /// Edge label box size, including the background rect's padding.
    private func edgeLabelDimensions(_ label: String) -> (width: Double, height: Double)? {
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let charWidth = self.charWidth
        let lines = MermaidTextWrap.wrapTextLines(
            label,
            maxWidth: options.wrappingWidth,
            charWidth: charWidth
        )
        guard !lines.isEmpty else { return nil }
        let text = MermaidTextWrap.measure(
            lines: lines,
            charWidth: charWidth,
            fontSize: options.fontSize
        )
        return (text.width + Self.edgeLabelPadding * 2, text.height + Self.edgeLabelPadding * 2)
    }

    private func subgraphTitleHeight(_ title: String) -> Double {
        let charWidth = MermaidTextWrap.scaleCharWidth(
            MermaidTextWrap.defaultCharWidth,
            fontSize: options.fontSize
        )
        let lines = MermaidTextWrap.wrapTextLines(
            title,
            maxWidth: options.wrappingWidth,
            charWidth: charWidth
        )
        let text = MermaidTextWrap.measure(
            lines: lines,
            charWidth: charWidth,
            fontSize: options.fontSize
        )
        return max(text.height, Self.subgraphTitleHeight)
    }

    // MARK: - Main pass

    func compute() -> MermaidLayoutResult {
        let backEdges = detectBackEdges()
        let (dagreGraph, edgeMap) = buildDagreGraph(backEdges: backEdges)
        DagreLayout.run(dagreGraph)

        var extracted = extractLayout(from: dagreGraph, edgeMap: edgeMap)
        if isStateDiagram {
            snapStateRanks(&extracted.positions, backEdges: backEdges)
            alignStateTerminalSingletons(&extracted.positions, backEdges: backEdges)
        }
        centerNodesInSubgraphs(&extracted.positions)

        let bounds = computeBounds(extracted.positions)
        var layoutNodes: [MermaidLayoutNode] = []
        for nodeID in nodes.orderedKeys {
            guard let info = nodes[nodeID], let position = extracted.positions[nodeID] else { continue }
            let colors = nodeColors(nodeID)
            layoutNodes.append(
                MermaidLayoutNode(
                    id: nodeID,
                    x: position.x,
                    y: position.y,
                    width: info.width,
                    height: info.height,
                    shape: info.shape,
                    label: info.label,
                    fillColor: colors.fill,
                    strokeColor: colors.stroke
                )
            )
        }

        let layoutSubgraphs = computeSubgraphBounds(layoutNodes)
        var layoutEdges = routeEdges(
            layoutNodes: layoutNodes,
            layoutSubgraphs: layoutSubgraphs,
            edgePoints: extracted.edgePoints,
            edgeLabelPositions: extracted.edgeLabelPositions
        )

        // Shift everything into the positive quadrant, leaving a margin.
        var minX = Double.infinity
        var minY = Double.infinity
        for subgraph in layoutSubgraphs {
            minX = min(minX, subgraph.x)
            minY = min(minY, subgraph.y)
        }
        for node in layoutNodes {
            minX = min(minX, node.x - node.width / 2)
            minY = min(minY, node.y - node.height / 2)
        }
        for edge in layoutEdges {
            guard let label = edgeLabelBounds(edge) else { continue }
            minX = min(minX, label.x - label.width / 2)
            minY = min(minY, label.y - label.height / 2)
        }

        let xShift = minX < Self.margin ? Self.margin - minX : 0
        let yShift = minY < Self.margin ? Self.margin - minY : 0

        for index in layoutNodes.indices {
            layoutNodes[index].x += xShift
            layoutNodes[index].y += yShift
        }
        for index in layoutEdges.indices {
            for pointIndex in layoutEdges[index].points.indices {
                layoutEdges[index].points[pointIndex].x += xShift
                layoutEdges[index].points[pointIndex].y += yShift
            }
            layoutEdges[index].labelPosition?.x += xShift
            layoutEdges[index].labelPosition?.y += yShift
        }
        var shiftedSubgraphs = layoutSubgraphs
        for index in shiftedSubgraphs.indices {
            shiftedSubgraphs[index].x += xShift
            shiftedSubgraphs[index].y += yShift
        }

        // Grow the canvas to cover anything that sticks out past the nodes.
        var finalWidth = bounds.width + xShift
        var finalHeight = bounds.height + yShift
        for subgraph in shiftedSubgraphs {
            finalWidth = max(finalWidth, subgraph.x + subgraph.width + Self.margin)
            finalHeight = max(finalHeight, subgraph.y + subgraph.height + Self.margin)
        }
        for edge in layoutEdges {
            for point in edge.points {
                finalWidth = max(finalWidth, point.x + Self.margin)
                finalHeight = max(finalHeight, point.y + Self.margin)
            }
            if let label = edgeLabelBounds(edge) {
                finalWidth = max(finalWidth, label.x + label.width / 2 + Self.margin)
                finalHeight = max(finalHeight, label.y + label.height / 2 + Self.margin)
            }
        }

        return MermaidLayoutResult(
            nodes: layoutNodes,
            edges: layoutEdges,
            subgraphs: shiftedSubgraphs,
            width: finalWidth,
            height: finalHeight
        )
    }

    // MARK: - Dagre bridge

    private func buildDagreGraph(
        backEdges: Set<EdgeKey>
    ) -> (graph: DagreGraph, edgeMap: [Int: (from: String, to: String)]) {
        let g = DagreGraph.makeDagreGraph(directed: true, multigraph: true, compound: true)

        var config = DagreGraphConfig()
        config.rankDirection = dagreRankDirection
        config.nodeSeparation = Float(options.nodeSpacing)
        config.rankSeparation = Float(options.rankSpacing)
        config.edgeSeparation = 20
        config.marginX = Float(Self.margin)
        config.marginY = Float(Self.margin)
        // State diagrams want every transition to advance exactly one rank, so
        // the ranks line up with the snapping pass below.
        config.ranker = isStateDiagram ? .longestPath : nil
        g.graphLabel = config

        for subgraphID in subgraphIDsInMermaidOrder() {
            g.setNode(subgraphID, DagreNode())
        }

        for nodeID in nodes.orderedKeys.sorted(by: { (nodes[$0]?.order ?? 0) < (nodes[$1]?.order ?? 0) }) {
            guard let info = nodes[nodeID] else { continue }
            var node = DagreNode()
            node.width = Float(info.width)
            node.height = Float(info.height)
            g.setNode(nodeID, node)
        }

        for (nodeID, subgraphID) in nodeToSubgraph {
            try? g.setParent(nodeID, subgraphID)
        }
        for subgraph in subgraphs {
            guard let parentID = subgraph.parentSubgraphID else { continue }
            try? g.setParent(subgraph.id, parentID)
        }

        var edgeMap: [Int: (from: String, to: String)] = [:]
        for (index, edge) in edges.enumerated() {
            // Back edges are routed by hand afterwards, so they are kept out of
            // the ranking entirely.
            if backEdges.contains(EdgeKey(edge.from, edge.to)) { continue }

            let from = dagreEndpoint(edge.from, isSource: true) ?? edge.from
            let to = dagreEndpoint(edge.to, isSource: false) ?? edge.to
            if from == to { continue }

            var label = DagreEdge()
            label.labelPosition = .center
            if let text = edge.label, let size = edgeLabelDimensions(text) {
                label.width = Float(size.width)
                label.height = Float(size.height)
            }

            try? g.setEdge(from, to, label)
            edgeMap[index] = (from, to)
        }

        return (g, edgeMap)
    }

    private var dagreRankDirection: DagreRankDirection {
        switch graph.direction {
        case .topToBottom: return .topToBottom
        case .bottomToTop: return .bottomToTop
        case .leftToRight: return .leftToRight
        case .rightToLeft: return .rightToLeft
        }
    }

    private struct ExtractedLayout {
        var positions = OrderedDictionary<String, MermaidPoint>()
        var edgePoints: [Int: [MermaidPoint]] = [:]
        var edgeLabelPositions: [Int: MermaidPoint] = [:]
    }

    private func extractLayout(
        from g: DagreGraph,
        edgeMap: [Int: (from: String, to: String)]
    ) -> ExtractedLayout {
        var result = ExtractedLayout()
        for nodeID in g.nodes() {
            guard let node = g.node(nodeID) else { continue }
            result.positions.insert(
                MermaidPoint(x: Double(node.x), y: Double(node.y)),
                forKey: nodeID
            )
        }
        for (index, endpoints) in edgeMap {
            guard let edge = g.edge(endpoints.from, endpoints.to) else { continue }
            if let points = edge.points {
                result.edgePoints[index] = points.map {
                    MermaidPoint(x: Double($0.x), y: Double($0.y))
                }
            }
            if (edge.width ?? 0) > 0 || (edge.height ?? 0) > 0 {
                result.edgeLabelPositions[index] = MermaidPoint(
                    x: Double(edge.x),
                    y: Double(edge.y)
                )
            }
        }
        return result
    }

    /// The concrete node a cluster-endpoint edge should attach to during
    /// ranking: the cluster's first node with no internal predecessor when the
    /// cluster is the source, its last node with no internal successor when it
    /// is the target.
    private func dagreEndpoint(_ id: String, isSource: Bool) -> String? {
        guard isSubgraphID(id) else { return id }
        let nodeIDs = nodesInSubgraphByOrder(id)
        guard !nodeIDs.isEmpty else { return nil }

        if isSource {
            return nodeIDs.reversed().first { candidate in
                !edges.contains { $0.from == candidate && nodeIDs.contains($0.to) }
            } ?? nodeIDs.last
        }
        return nodeIDs.first { candidate in
            !edges.contains { nodeIDs.contains($0.from) && $0.to == candidate }
        } ?? nodeIDs.first
    }

    private func nodesInSubgraphByOrder(_ subgraphID: String) -> [String] {
        nodeToSubgraph
            .filter { $0.value == subgraphID }
            .map(\.key)
            .sorted { (nodes[$0]?.order ?? .max) < (nodes[$1]?.order ?? .max) }
    }

    // MARK: - Back edges

    /// An unordered-by-nothing pair identifying one authored edge.
    private struct EdgeKey: Hashable {
        var from: String
        var to: String

        init(_ from: String, _ to: String) {
            self.from = from
            self.to = to
        }
    }

    /// Edges that close a cycle, found by a depth-first walk from the sources.
    private func detectBackEdges() -> Set<EdgeKey> {
        var backEdges = Set<EdgeKey>()
        var visited = Set<String>()
        var onStack = Set<String>()

        func visit(_ node: String) {
            guard visited.insert(node).inserted else { return }
            onStack.insert(node)
            for neighbor in adjacency[node] ?? [] {
                if onStack.contains(neighbor) {
                    backEdges.insert(EdgeKey(node, neighbor))
                } else if !visited.contains(neighbor) {
                    visit(neighbor)
                }
            }
            onStack.remove(node)
        }

        var startNodes = nodes.orderedKeys.filter { !reverseAdjacency.containsKey($0) }
        if startNodes.isEmpty {
            if let first = edges.first {
                startNodes = [first.from]
            } else if let first = nodes.orderedKeys.sorted().first {
                startNodes = [first]
            }
        }

        for start in startNodes {
            visit(start)
        }
        // Components with no source of their own still need a walk.
        for nodeID in nodes.orderedKeys.sorted() where !visited.contains(nodeID) {
            visit(nodeID)
        }

        return backEdges
    }

    // MARK: - State-diagram adjustments

    /// Snaps every state onto the y of its longest-path rank, so transitions
    /// read as one clean row per step.
    private func snapStateRanks(
        _ positions: inout OrderedDictionary<String, MermaidPoint>,
        backEdges: Set<EdgeKey>
    ) {
        let ranks = longestPathRanks(backEdges: backEdges)
        guard !ranks.isEmpty else { return }

        var levels = positions.values.map(\.y).sorted()
        // Collapse ys that are the same row to within half a point.
        var deduplicated: [Double] = []
        for level in levels where deduplicated.last.map({ abs(level - $0) >= 0.5 }) ?? true {
            deduplicated.append(level)
        }
        levels = deduplicated

        let maxRank = ranks.values.max() ?? 0
        guard levels.count > maxRank else { return }

        for (nodeID, rank) in ranks where rank >= 0 && rank < levels.count {
            positions.withValue(forKey: nodeID) { $0.y = levels[rank] }
        }
    }

    /// A lone terminal state on its rank is pulled under its rightmost
    /// predecessor rather than left floating between them.
    private func alignStateTerminalSingletons(
        _ positions: inout OrderedDictionary<String, MermaidPoint>,
        backEdges: Set<EdgeKey>
    ) {
        let ranks = longestPathRanks(backEdges: backEdges)
        guard !ranks.isEmpty else { return }

        var nodesByRank: [Int: [String]] = [:]
        for nodeID in nodes.orderedKeys {
            guard let rank = ranks[nodeID] else { continue }
            nodesByRank[rank, default: []].append(nodeID)
        }

        for nodeID in nodes.orderedKeys {
            guard let rank = ranks[nodeID], rank > 0 else { continue }
            guard nodesByRank[rank]?.count == 1 else { continue }

            let hasForwardOutgoing = edges.contains {
                $0.from == nodeID && !backEdges.contains(EdgeKey($0.from, $0.to))
            }
            if hasForwardOutgoing { continue }

            let predecessorXs = edges
                .filter {
                    $0.to == nodeID
                        && !backEdges.contains(EdgeKey($0.from, $0.to))
                        && (ranks[$0.from].map { $0 < rank } ?? false)
                }
                .compactMap { positions[$0.from]?.x }
                .sorted()
            guard predecessorXs.count >= 2, let rightmost = predecessorXs.last else { continue }

            positions.withValue(forKey: nodeID) { $0.x = rightmost }
        }
    }

    /// Longest-path rank of every node, ignoring back edges.
    private func longestPathRanks(backEdges: Set<EdgeKey>) -> OrderedDictionary<String, Int> {
        var indegree = OrderedDictionary<String, Int>()
        for nodeID in nodes.orderedKeys {
            indegree.insert(0, forKey: nodeID)
        }
        for edge in edges where !backEdges.contains(EdgeKey(edge.from, edge.to)) {
            indegree.withValue(forKey: edge.to) { $0 += 1 }
        }

        func sortedByDeclaration(_ ids: [String]) -> [String] {
            ids.sorted { (nodes[$0]?.order ?? .max) < (nodes[$1]?.order ?? .max) }
        }

        var ready = sortedByDeclaration(indegree.filter { $0.value == 0 }.map(\.key))
        var order: [String] = []
        while !ready.isEmpty {
            let nodeID = ready.removeFirst()
            order.append(nodeID)
            for edge in edges
            where edge.from == nodeID && !backEdges.contains(EdgeKey(edge.from, edge.to)) {
                indegree.withValue(forKey: edge.to) { count in
                    count = max(count - 1, 0)
                    if count == 0 { ready.append(edge.to) }
                }
            }
            ready = sortedByDeclaration(ready)
        }

        var ranks = OrderedDictionary<String, Int>()
        for nodeID in nodes.orderedKeys {
            ranks.insert(0, forKey: nodeID)
        }
        for nodeID in order {
            let baseRank = ranks[nodeID] ?? 0
            for edge in edges
            where edge.from == nodeID && !backEdges.contains(EdgeKey(edge.from, edge.to)) {
                ranks.withValue(forKey: edge.to) { $0 = max($0, baseRank + 1) }
            }
        }
        return ranks
    }

    // MARK: - Subgraphs

    /// Subgraph ids parent-first, matching the order Mermaid declares them in.
    private func subgraphIDsInMermaidOrder() -> [String] {
        guard !subgraphs.isEmpty else { return [] }
        return subgraphIDsBottomUp().reversed()
    }

    /// Subgraph ids children-first, so a parent's box can be grown to cover its
    /// children's finished boxes.
    private func subgraphIDsBottomUp() -> [String] {
        var childrenByParent: [String: [String]] = [:]
        var roots: [String] = []
        for subgraph in subgraphs {
            childrenByParent[subgraph.parentSubgraphID ?? "", default: []].append(subgraph.id)
            if subgraph.parentSubgraphID == nil {
                roots.append(subgraph.id)
            }
        }

        var result: [String] = []
        var visited = Set<String>()
        func visit(_ id: String) {
            guard visited.insert(id).inserted else { return }
            for child in childrenByParent[id] ?? [] {
                visit(child)
            }
            result.append(id)
        }
        for root in roots {
            visit(root)
        }
        return result
    }

    private func computeSubgraphBounds(_ layoutNodes: [MermaidLayoutNode]) -> [MermaidLayoutSubgraph] {
        var rects: [String: (minX: Double, minY: Double, maxX: Double, maxY: Double)] = [:]

        for subgraphID in subgraphIDsBottomUp() {
            guard let subgraph = subgraphs.first(where: { $0.id == subgraphID }) else { continue }
            let directNodeIDs = Set(nodeToSubgraph.filter { $0.value == subgraphID }.map(\.key))

            var minX = Double.infinity
            var minY = Double.infinity
            var maxX = -Double.infinity
            var maxY = -Double.infinity

            for node in layoutNodes where directNodeIDs.contains(node.id) {
                minX = min(minX, node.x - node.width / 2)
                maxX = max(maxX, node.x + node.width / 2)
                minY = min(minY, node.y - node.height / 2)
                maxY = max(maxY, node.y + node.height / 2)
            }

            for child in subgraphs where child.parentSubgraphID == subgraphID {
                guard let rect = rects[child.id] else { continue }
                minX = min(minX, rect.minX)
                minY = min(minY, rect.minY)
                maxX = max(maxX, rect.maxX)
                maxY = max(maxY, rect.maxY)
            }

            guard minX.isFinite else { continue }

            let titlePadding = subgraph.title.map(subgraphTitleHeight) ?? 0
            let padding = Self.subgraphPadding
            let x = minX - padding
            let y = minY - padding - titlePadding
            let width = (maxX - minX) + padding * 2
            let height = (maxY - minY) + padding * 2 + titlePadding
            rects[subgraphID] = (x, y, x + width, y + height)
        }

        return subgraphs.compactMap { subgraph in
            guard let rect = rects[subgraph.id] else { return nil }
            return MermaidLayoutSubgraph(
                id: subgraph.id,
                title: subgraph.title,
                x: rect.minX,
                y: rect.minY,
                width: rect.maxX - rect.minX,
                height: rect.maxY - rect.minY
            )
        }
    }

    /// Shifts each subgraph in a connected group so their centres line up,
    /// keeping the relative offsets inside each subgraph.
    private func centerNodesInSubgraphs(_ positions: inout OrderedDictionary<String, MermaidPoint>) {
        let isVertical = graph.direction.isVertical

        for group in connectedSubgraphGroups() {
            let groupNodes = group.flatMap { subgraphID in
                nodeToSubgraph.filter { $0.value == subgraphID }.map(\.key)
            }
            guard !groupNodes.isEmpty else { continue }

            let groupCoordinates = groupNodes.compactMap { positions[$0] }
                .map { isVertical ? $0.x : $0.y }
            guard !groupCoordinates.isEmpty else { continue }
            let groupAverage = groupCoordinates.reduce(0, +) / Double(groupCoordinates.count)

            for subgraphID in group {
                let subgraphNodes = nodeToSubgraph.filter { $0.value == subgraphID }.map(\.key)
                guard !subgraphNodes.isEmpty else { continue }
                let coordinates = subgraphNodes.compactMap { positions[$0] }
                    .map { isVertical ? $0.x : $0.y }
                guard !coordinates.isEmpty else { continue }

                let shift = groupAverage - coordinates.reduce(0, +) / Double(coordinates.count)
                for nodeID in subgraphNodes {
                    positions.withValue(forKey: nodeID) { point in
                        if isVertical { point.x += shift } else { point.y += shift }
                    }
                }
            }
        }
    }

    /// Subgraphs joined by at least one edge, as groups of two or more.
    private func connectedSubgraphGroups() -> [[String]] {
        guard !subgraphs.isEmpty else { return [] }

        var connections = OrderedDictionary<String, [String]>()
        for subgraph in subgraphs {
            connections.insert([], forKey: subgraph.id)
        }
        for edge in edges {
            guard let from = nodeToSubgraph[edge.from],
                  let to = nodeToSubgraph[edge.to],
                  from != to
            else { continue }
            connections.withValue(forKey: from, default: []) { if !$0.contains(to) { $0.append(to) } }
            connections.withValue(forKey: to, default: []) { if !$0.contains(from) { $0.append(from) } }
        }

        var visited = Set<String>()
        var groups: [[String]] = []
        for subgraph in subgraphs where !visited.contains(subgraph.id) {
            var group: [String] = []
            var stack = [subgraph.id]
            while let current = stack.popLast() {
                guard !group.contains(current) else { continue }
                group.append(current)
                visited.insert(current)
                for neighbor in connections[current] ?? [] where !group.contains(neighbor) {
                    stack.append(neighbor)
                }
            }
            if group.count > 1 { groups.append(group) }
        }
        return groups
    }

    // MARK: - Bounds and styles

    private func computeBounds(
        _ positions: OrderedDictionary<String, MermaidPoint>
    ) -> (width: Double, height: Double) {
        guard !positions.isEmpty else { return (200, 200) }

        var maxX: Double = 0
        var maxY: Double = 0
        for (id, point) in positions {
            guard let info = nodes[id] else { continue }
            maxX = max(maxX, point.x + info.width / 2)
            maxY = max(maxY, point.y + info.height / 2)
        }
        return (maxX + Self.margin, maxY + Self.margin)
    }

    private func nodeColors(_ nodeID: String) -> (fill: String?, stroke: String?) {
        guard let properties = nodeStyles[nodeID] else { return (nil, nil) }
        return (
            properties.first { $0.key == "fill" }?.value,
            properties.first { $0.key == "stroke" }?.value
        )
    }

    private func edgeLabelBounds(
        _ edge: MermaidLayoutEdge
    ) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard let label = edge.label, let size = edgeLabelDimensions(label) else { return nil }
        let position = edge.labelPosition ?? Self.polylineMidpoint(edge.points)
        return (position.x, position.y, size.width, size.height)
    }

    // MARK: - Edge routing

    private func routeEdges(
        layoutNodes: [MermaidLayoutNode],
        layoutSubgraphs: [MermaidLayoutSubgraph],
        edgePoints: [Int: [MermaidPoint]],
        edgeLabelPositions: [Int: MermaidPoint]
    ) -> [MermaidLayoutEdge] {
        let isVertical = graph.direction.isVertical
        var result: [MermaidLayoutEdge] = []

        for (index, edge) in edges.enumerated() {
            guard let fromNode = endpointNode(edge.from, layoutNodes, layoutSubgraphs),
                  let toNode = endpointNode(edge.to, layoutNodes, layoutSubgraphs)
            else { continue }

            let isBackEdge = self.isBackEdge(from: fromNode, to: toNode)
            let dagrePoints = edgePoints[index]
                ?? computeEdgePointsWithObstacles(from: fromNode, to: toNode, allNodes: layoutNodes)

            var points: [MermaidPoint]
            if isBackEdge {
                points = computeBackEdgePoints(
                    from: fromNode,
                    to: toNode,
                    isVertical: isVertical,
                    allNodes: layoutNodes
                )
            } else {
                points = straightenIfAligned(
                    dagrePoints,
                    from: fromNode,
                    to: toNode,
                    isVertical: isVertical,
                    allNodes: layoutNodes
                )
            }

            if !isBackEdge {
                let fromIsCluster = isSubgraphID(edge.from)
                let toIsCluster = isSubgraphID(edge.to)
                if fromIsCluster || toIsCluster {
                    Self.trimClusterInteriorPoints(
                        &points,
                        from: fromNode,
                        to: toNode,
                        fromIsCluster: fromIsCluster,
                        toIsCluster: toIsCluster
                    )
                }
            }
            clipEdgeToBoundaries(&points, from: fromNode, to: toNode)

            var labelPosition: MermaidPoint?
            if let label = edge.label, !label.trimmingCharacters(in: .whitespaces).isEmpty {
                let midpoint = Self.polylineMidpoint(points)
                if isBackEdge {
                    labelPosition = midpoint
                } else if let dagreLabel = edgeLabelPositions[index],
                          Self.point(dagreLabel, isNear: points) {
                    // Dagre's label slot is only trusted when it still sits on
                    // the route this pass produced.
                    labelPosition = dagreLabel
                } else {
                    labelPosition = midpoint
                }
            }

            result.append(
                MermaidLayoutEdge(
                    from: edge.from,
                    to: edge.to,
                    label: edge.label,
                    style: edge.style,
                    points: points,
                    labelPosition: labelPosition
                )
            )
        }

        return result
    }

    private static func point(_ candidate: MermaidPoint, isNear points: [MermaidPoint]) -> Bool {
        guard !points.isEmpty else { return false }
        let tolerance: Double = 8
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        return candidate.x >= minX - tolerance && candidate.x <= maxX + tolerance
            && candidate.y >= minY - tolerance && candidate.y <= maxY + tolerance
    }

    /// A cluster used as an edge endpoint is treated as a node covering its box.
    private func endpointNode(
        _ id: String,
        _ layoutNodes: [MermaidLayoutNode],
        _ layoutSubgraphs: [MermaidLayoutSubgraph]
    ) -> MermaidLayoutNode? {
        if let node = layoutNodes.first(where: { $0.id == id }) { return node }
        guard let subgraph = layoutSubgraphs.first(where: { $0.id == id }) else { return nil }
        return MermaidLayoutNode(
            id: subgraph.id,
            x: subgraph.x + subgraph.width / 2,
            y: subgraph.y + subgraph.height / 2,
            width: subgraph.width,
            height: subgraph.height,
            shape: .rectangle,
            label: subgraph.title ?? subgraph.id,
            fillColor: nil,
            strokeColor: nil
        )
    }

    /// True when the edge runs against the rank direction and so needs the
    /// hand-routed U-shape rather than Dagre's polyline.
    private func isBackEdge(from: MermaidLayoutNode, to: MermaidLayoutNode) -> Bool {
        let dx = to.x - from.x
        let dy = to.y - from.y
        switch graph.direction {
        case .topToBottom: return dy < -10
        case .bottomToTop: return dy > 10
        case .leftToRight: return dx < -10
        case .rightToLeft: return dx > 10
        }
    }

    /// Fallback route used when Dagre produced no polyline for an edge.
    private func computeEdgePointsWithObstacles(
        from: MermaidLayoutNode,
        to: MermaidLayoutNode,
        allNodes: [MermaidLayoutNode]
    ) -> [MermaidPoint] {
        let isVertical = graph.direction.isVertical
        if isBackEdge(from: from, to: to) {
            return computeSimpleBackEdgePoints(from: from, to: to, isVertical: isVertical)
        }

        let obstacles = allNodes.filter { $0.id != from.id && $0.id != to.id }
        return isVertical
            ? verticalEdgeAvoiding(obstacles, from: from, to: to)
            : horizontalEdgeAvoiding(obstacles, from: from, to: to)
    }

    private func horizontalEdgeAvoiding(
        _ obstacles: [MermaidLayoutNode],
        from: MermaidLayoutNode,
        to: MermaidLayoutNode
    ) -> [MermaidPoint] {
        let travelRight = to.x > from.x
        let fromX = from.x + (from.width / 2) * (travelRight ? 1 : -1)
        let toX = to.x + (to.width / 2) * (travelRight ? -1 : 1)

        let box = (
            minX: min(fromX, toX), maxX: max(fromX, toX),
            minY: min(from.y, to.y), maxY: max(from.y, to.y)
        )
        if let obstacle = obstacles.first(where: { overlaps($0, box) }) {
            let obstacleTop = obstacle.y - obstacle.height / 2
            let obstacleBottom = obstacle.y + obstacle.height / 2
            let routeAbove = abs(from.y - obstacleTop) < abs(from.y - obstacleBottom)
            let routeY = routeAbove ? obstacleTop - 30 : obstacleBottom + 30
            return [
                connectionPoint(on: from, towards: MermaidPoint(x: fromX, y: routeY)),
                MermaidPoint(x: fromX, y: routeY),
                MermaidPoint(x: toX, y: routeY),
                connectionPoint(on: to, towards: MermaidPoint(x: toX, y: routeY)),
            ]
        }

        let mid = MermaidPoint(x: (fromX + toX) / 2, y: to.y)
        return deduplicated([
            connectionPoint(on: from, towards: mid), mid, connectionPoint(on: to, towards: mid),
        ])
    }

    private func verticalEdgeAvoiding(
        _ obstacles: [MermaidLayoutNode],
        from: MermaidLayoutNode,
        to: MermaidLayoutNode
    ) -> [MermaidPoint] {
        let travelDown = to.y > from.y
        let fromY = from.y + (from.height / 2) * (travelDown ? 1 : -1)
        let toY = to.y + (to.height / 2) * (travelDown ? -1 : 1)

        let box = (
            minX: min(from.x, to.x), maxX: max(from.x, to.x),
            minY: min(fromY, toY), maxY: max(fromY, toY)
        )
        if let obstacle = obstacles.first(where: { overlaps($0, box) }) {
            let obstacleLeft = obstacle.x - obstacle.width / 2
            let obstacleRight = obstacle.x + obstacle.width / 2
            let routeLeft = abs(from.x - obstacleLeft) < abs(from.x - obstacleRight)
            let routeX = routeLeft ? obstacleLeft - 30 : obstacleRight + 30
            return [
                connectionPoint(on: from, towards: MermaidPoint(x: routeX, y: fromY)),
                MermaidPoint(x: routeX, y: fromY),
                MermaidPoint(x: routeX, y: toY),
                connectionPoint(on: to, towards: MermaidPoint(x: routeX, y: toY)),
            ]
        }

        let mid = MermaidPoint(x: to.x, y: (fromY + toY) / 2)
        return deduplicated([
            connectionPoint(on: from, towards: mid), mid, connectionPoint(on: to, towards: mid),
        ])
    }

    private func overlaps(
        _ node: MermaidLayoutNode,
        _ box: (minX: Double, maxX: Double, minY: Double, maxY: Double)
    ) -> Bool {
        let clearance: Double = 10
        let left = node.x - node.width / 2 - clearance
        let right = node.x + node.width / 2 + clearance
        let top = node.y - node.height / 2 - clearance
        let bottom = node.y + node.height / 2 + clearance
        return left < box.maxX && right > box.minX && top < box.maxY && bottom > box.minY
    }

    private func deduplicated(_ points: [MermaidPoint]) -> [MermaidPoint] {
        var result: [MermaidPoint] = []
        for point in points where result.last != point {
            result.append(point)
        }
        return result
    }

    private func computeSimpleBackEdgePoints(
        from: MermaidLayoutNode,
        to: MermaidLayoutNode,
        isVertical: Bool
    ) -> [MermaidPoint] {
        let offset: Double = 60
        if isVertical {
            let sideX = max(from.x, to.x) + max(from.width, to.width) / 2 + offset
            return Self.smoothUPath(
                start: MermaidPoint(x: from.x + from.width / 2, y: from.y),
                end: MermaidPoint(x: to.x + to.width / 2, y: to.y),
                routeCoordinate: sideX,
                isVertical: true
            )
        }
        let belowY = max(from.y, to.y) + max(from.height, to.height) / 2 + offset
        return Self.smoothUPath(
            start: MermaidPoint(x: from.x, y: from.y + from.height / 2),
            end: MermaidPoint(x: to.x, y: to.y + to.height / 2),
            routeCoordinate: belowY,
            isVertical: false
        )
    }

    /// Routes a back edge around the outside of the diagram, choosing the side
    /// that keeps it clear of the nodes it would otherwise cross.
    private func computeBackEdgePoints(
        from: MermaidLayoutNode,
        to: MermaidLayoutNode,
        isVertical: Bool,
        allNodes: [MermaidLayoutNode]
    ) -> [MermaidPoint] {
        let margin: Double = 30

        if isVertical {
            let maxRight = max(from.x + from.width / 2, to.x + to.width / 2)
            let minLeft = min(from.x - from.width / 2, to.x - to.width / 2)
            let centerX = (from.x + to.x) / 2
            let sideX = from.x >= to.x ? maxRight + margin : minLeft - margin
            let onRight = sideX > centerX

            return Self.smoothUPath(
                start: MermaidPoint(
                    x: onRight ? from.x + from.width / 2 : from.x - from.width / 2,
                    y: from.y
                ),
                end: MermaidPoint(
                    x: onRight ? to.x + to.width / 2 : to.x - to.width / 2,
                    y: to.y
                ),
                routeCoordinate: sideX,
                isVertical: true
            )
        }

        // Route above or below, whichever detour is shorter, clearing every node
        // whose x range the edge spans.
        let minX = min(from.x, to.x)
        let maxX = max(from.x, to.x)
        var maxBottom = max(from.y + from.height / 2, to.y + to.height / 2)
        var minTop = min(from.y - from.height / 2, to.y - to.height / 2)
        for node in allNodes {
            let left = node.x - node.width / 2
            let right = node.x + node.width / 2
            guard right >= minX - margin && left <= maxX + margin else { continue }
            maxBottom = max(maxBottom, node.y + node.height / 2)
            minTop = min(minTop, node.y - node.height / 2)
        }

        let belowY = maxBottom + margin
        let aboveY = minTop - margin
        let centerY = (from.y + to.y) / 2
        let routeY = abs(belowY - centerY) <= abs(aboveY - centerY) ? belowY : aboveY
        let below = routeY > centerY

        return Self.smoothUPath(
            start: MermaidPoint(
                x: from.x,
                y: below ? from.y + from.height / 2 : from.y - from.height / 2
            ),
            end: MermaidPoint(x: to.x, y: below ? to.y + to.height / 2 : to.y - to.height / 2),
            routeCoordinate: routeY,
            isVertical: false
        )
    }

    /// Nine points describing a U-turn with rounded corners.
    private static func smoothUPath(
        start: MermaidPoint,
        end: MermaidPoint,
        routeCoordinate: Double,
        isVertical: Bool
    ) -> [MermaidPoint] {
        let curveFraction = 0.3
        if isVertical {
            let sideX = routeCoordinate
            let curveHeight = abs(start.y - end.y) * curveFraction
            let midY = (start.y + end.y) / 2
            let topCurveEndY = start.y - curveHeight
            let bottomCurveStartY = end.y + curveHeight
            return [
                start,
                MermaidPoint(x: start.x, y: start.y - curveHeight * 0.33),
                MermaidPoint(x: sideX, y: topCurveEndY + curveHeight * 0.33),
                MermaidPoint(x: sideX, y: topCurveEndY),
                MermaidPoint(x: sideX, y: midY),
                MermaidPoint(x: sideX, y: bottomCurveStartY),
                MermaidPoint(x: sideX, y: bottomCurveStartY - curveHeight * 0.33),
                MermaidPoint(x: end.x, y: end.y + curveHeight * 0.33),
                end,
            ]
        }

        let belowY = routeCoordinate
        let curveWidth = abs(start.x - end.x) * curveFraction
        let midX = (start.x + end.x) / 2
        let leftCurveEndX = start.x - curveWidth
        let rightCurveStartX = end.x + curveWidth
        return [
            start,
            MermaidPoint(x: start.x - curveWidth * 0.33, y: start.y),
            MermaidPoint(x: leftCurveEndX + curveWidth * 0.33, y: belowY),
            MermaidPoint(x: leftCurveEndX, y: belowY),
            MermaidPoint(x: midX, y: belowY),
            MermaidPoint(x: rightCurveStartX, y: belowY),
            MermaidPoint(x: rightCurveStartX - curveWidth * 0.33, y: belowY),
            MermaidPoint(x: end.x + curveWidth * 0.33, y: end.y),
            end,
        ]
    }

    /// Replaces Dagre's polyline with a straight line when the endpoints are
    /// nearly aligned and nothing sits in the way.
    private func straightenIfAligned(
        _ dagrePoints: [MermaidPoint],
        from: MermaidLayoutNode,
        to: MermaidLayoutNode,
        isVertical: Bool,
        allNodes: [MermaidLayoutNode]
    ) -> [MermaidPoint] {
        let tolerance: Double = 15
        let aligned = isVertical ? abs(from.x - to.x) < tolerance : abs(from.y - to.y) < tolerance
        guard aligned, dagrePoints.count >= 2,
              let start = dagrePoints.first, let end = dagrePoints.last
        else { return dagrePoints }

        let candidate: [MermaidPoint]
        if isVertical {
            let averageX = (from.x + to.x) / 2
            candidate = [
                MermaidPoint(x: averageX, y: start.y), MermaidPoint(x: averageX, y: end.y),
            ]
        } else {
            let averageY = (from.y + to.y) / 2
            candidate = [
                MermaidPoint(x: start.x, y: averageY), MermaidPoint(x: end.x, y: averageY),
            ]
        }

        return edgeCrossesAnyNode(candidate, from: from, to: to, allNodes: allNodes)
            ? dagrePoints
            : candidate
    }

    private func edgeCrossesAnyNode(
        _ points: [MermaidPoint],
        from: MermaidLayoutNode,
        to: MermaidLayoutNode,
        allNodes: [MermaidLayoutNode]
    ) -> Bool {
        guard let first = points.first, let last = points.last, points.count >= 2 else {
            return false
        }
        let margin: Double = 5
        for node in allNodes where node.id != from.id && node.id != to.id {
            let rectMin = MermaidPoint(
                x: node.x - node.width / 2 - margin,
                y: node.y - node.height / 2 - margin
            )
            let rectMax = MermaidPoint(
                x: node.x + node.width / 2 + margin,
                y: node.y + node.height / 2 + margin
            )
            if Self.segmentIntersectsRect(first, last, rectMin, rectMax) { return true }
        }
        return false
    }

    private static func segmentIntersectsRect(
        _ p1: MermaidPoint,
        _ p2: MermaidPoint,
        _ rectMin: MermaidPoint,
        _ rectMax: MermaidPoint
    ) -> Bool {
        // Wholly on one side of the rect.
        if (p1.x < rectMin.x && p2.x < rectMin.x) || (p1.x > rectMax.x && p2.x > rectMax.x)
            || (p1.y < rectMin.y && p2.y < rectMin.y) || (p1.y > rectMax.y && p2.y > rectMax.y) {
            return false
        }
        // Either endpoint inside.
        for point in [p1, p2]
        where point.x >= rectMin.x && point.x <= rectMax.x
            && point.y >= rectMin.y && point.y <= rectMax.y {
            return true
        }

        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        let edges: [(Double, Double, Double, Double)] = [
            (rectMin.x, rectMin.y, rectMin.x, rectMax.y),
            (rectMax.x, rectMin.y, rectMax.x, rectMax.y),
            (rectMin.x, rectMin.y, rectMax.x, rectMin.y),
            (rectMin.x, rectMax.y, rectMax.x, rectMax.y),
        ]
        for (ex1, ey1, ex2, ey2) in edges {
            let edx = ex2 - ex1
            let edy = ey2 - ey1
            let denominator = dx * edy - dy * edx
            if abs(denominator) < 1e-10 { continue }
            let t = ((ex1 - p1.x) * edy - (ey1 - p1.y) * edx) / denominator
            let u = ((ex1 - p1.x) * dy - (ey1 - p1.y) * dx) / denominator
            if (0...1).contains(t) && (0...1).contains(u) { return true }
        }
        return false
    }

    /// Drops route points that fall inside a cluster endpoint's box, so the edge
    /// meets the cluster boundary from outside instead of diving toward the
    /// interior member Dagre actually routed to. One transition point is kept on
    /// each trimmed side, and the polyline never falls below two points.
    static func trimClusterInteriorPoints(
        _ points: inout [MermaidPoint],
        from fromNode: MermaidLayoutNode,
        to toNode: MermaidLayoutNode,
        fromIsCluster: Bool,
        toIsCluster: Bool
    ) {
        func isInside(_ node: MermaidLayoutNode, _ point: MermaidPoint) -> Bool {
            let halfWidth = node.width / 2
            let halfHeight = node.height / 2
            return point.x > node.x - halfWidth && point.x < node.x + halfWidth
                && point.y > node.y - halfHeight && point.y < node.y + halfHeight
        }

        if toIsCluster, points.count > 2 {
            if let lastOutside = points.lastIndex(where: { !isInside(toNode, $0) }) {
                points.removeSubrange(min(lastOutside + 2, points.count)...)
            }
        }

        if fromIsCluster, points.count > 2 {
            if let firstOutside = points.firstIndex(where: { !isInside(fromNode, $0) }) {
                let drop = max(firstOutside - 1, 0)
                if drop > 0 { points.removeSubrange(0..<drop) }
            }
        }
    }

    private func clipEdgeToBoundaries(
        _ points: inout [MermaidPoint],
        from fromNode: MermaidLayoutNode,
        to toNode: MermaidLayoutNode
    ) {
        guard points.count >= 2 else { return }
        points[0] = connectionPoint(on: fromNode, facing: points[1])
        points[points.count - 1] = connectionPoint(
            on: toNode,
            facing: points[points.count - 2]
        )
    }

    /// Where a line arriving from `source` meets `node`'s outline.
    private func connectionPoint(on node: MermaidLayoutNode, facing source: MermaidPoint) -> MermaidPoint {
        outlinePoint(node, dx: node.x - source.x, dy: node.y - source.y, outward: false)
    }

    /// Where a line leaving `node` toward `target` crosses its outline.
    private func connectionPoint(on node: MermaidLayoutNode, towards target: MermaidPoint) -> MermaidPoint {
        outlinePoint(node, dx: target.x - node.x, dy: target.y - node.y, outward: true)
    }

    private func outlinePoint(
        _ node: MermaidLayoutNode,
        dx: Double,
        dy: Double,
        outward: Bool
    ) -> MermaidPoint {
        let sign: Double = outward ? 1 : -1

        switch node.shape {
        case .circle, .startState, .endState:
            let radius = min(node.width, node.height) / 2
            let length = (dx * dx + dy * dy).squareRoot()
            guard length != 0 else {
                return outward
                    ? MermaidPoint(x: node.x + radius, y: node.y)
                    : MermaidPoint(x: node.x, y: node.y - radius)
            }
            return MermaidPoint(
                x: node.x + sign * radius * dx / length,
                y: node.y + sign * radius * dy / length
            )

        case .diamond:
            let halfWidth = node.width / 2
            let halfHeight = node.height / 2
            let denominator = abs(dx) / halfWidth + abs(dy) / halfHeight
            guard denominator != 0 else {
                return outward
                    ? MermaidPoint(x: node.x + halfWidth, y: node.y)
                    : MermaidPoint(x: node.x, y: node.y - halfHeight)
            }
            let t = 1 / denominator
            return MermaidPoint(x: node.x + sign * dx * t, y: node.y + sign * dy * t)

        default:
            let halfWidth = node.width / 2
            let halfHeight = node.height / 2
            let denominator = max(
                halfWidth > 0 ? abs(dx) / halfWidth : 0,
                halfHeight > 0 ? abs(dy) / halfHeight : 0
            )
            guard denominator != 0 else {
                return outward
                    ? MermaidPoint(x: node.x + halfWidth, y: node.y)
                    : MermaidPoint(x: node.x, y: node.y - halfHeight)
            }
            let t = 1 / denominator
            return MermaidPoint(x: node.x + sign * dx * t, y: node.y + sign * dy * t)
        }
    }

    /// The point halfway along a polyline by arc length.
    static func polylineMidpoint(_ points: [MermaidPoint]) -> MermaidPoint {
        guard points.count >= 2 else { return points.first ?? MermaidPoint(x: 0, y: 0) }

        var segmentLengths: [Double] = []
        var totalLength: Double = 0
        for index in 0..<(points.count - 1) {
            let dx = points[index + 1].x - points[index].x
            let dy = points[index + 1].y - points[index].y
            let length = (dx * dx + dy * dy).squareRoot()
            segmentLengths.append(length)
            totalLength += length
        }

        guard totalLength >= 0.001 else { return points[0] }

        let target = totalLength * 0.5
        var accumulated: Double = 0
        for (index, length) in segmentLengths.enumerated() {
            if accumulated + length >= target {
                let t = length > 0.001 ? (target - accumulated) / length : 0
                return MermaidPoint(
                    x: points[index].x + t * (points[index + 1].x - points[index].x),
                    y: points[index].y + t * (points[index + 1].y - points[index].y)
                )
            }
            accumulated += length
        }

        let last = points.count - 1
        return MermaidPoint(
            x: (points[0].x + points[last].x) / 2,
            y: (points[0].y + points[last].y) / 2
        )
    }
}
