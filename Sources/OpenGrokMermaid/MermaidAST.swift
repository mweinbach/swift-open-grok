// MermaidAST.swift
//
// Open Grok — Swift port of `mermaid_to_svg::ast`
// (third_party/mermaid-to-svg/src/ast.rs, W8-S2).
//
// The flowchart AST is shared by the `graph`/`flowchart` and `stateDiagram`
// families: state diagrams parse into the same shape and reuse the same layout
// and renderer, with a few state-specific node shapes.

/// Which way ranks advance.
public enum GraphDirection: String, Equatable, Sendable {
    case topToBottom
    case bottomToTop
    case leftToRight
    case rightToLeft

    /// Parses the token after `graph`/`flowchart` (case-insensitive).
    public static func parse(_ token: String) -> GraphDirection? {
        switch token.uppercased() {
        case "TD", "TB": return .topToBottom
        case "BT": return .bottomToTop
        case "LR": return .leftToRight
        case "RL": return .rightToLeft
        default: return nil
        }
    }

    /// True when ranks advance along y.
    public var isVertical: Bool {
        self == .topToBottom || self == .bottomToTop
    }
}

/// The outline drawn around a node's label.
public enum NodeShape: Equatable, Sendable {
    /// `A[text]`
    case rectangle
    /// `A(text)`
    case roundedRectangle
    /// `A([text])`
    case stadium
    /// `A{text}`
    case diamond
    /// `A{{text}}`
    case hexagon
    /// `A>text]`
    case asymmetric
    /// `A[[text]]`
    case subroutine
    /// `A[(text)]`
    case cylinder
    /// `A((text))`
    case circle
    /// State diagram `[*]` as a source.
    case startState
    /// State diagram `[*]` as a target.
    case endState
    /// State diagram `<<fork>>` / `<<join>>`.
    case forkJoin

    /// True for the shapes only state diagrams produce.
    var isStateShape: Bool {
        self == .startState || self == .endState || self == .forkJoin
    }
}

/// The line style connecting two nodes.
public enum EdgeStyle: Equatable, Sendable {
    /// `-->`
    case arrow
    /// `---`
    case line
    /// `-.->`
    case dottedArrow
    /// `-.-`
    case dottedLine
    /// `==>`
    case thickArrow
    /// `===`
    case thickLine

    var hasArrowhead: Bool {
        self == .arrow || self == .dottedArrow || self == .thickArrow
    }

    var isDotted: Bool {
        self == .dottedArrow || self == .dottedLine
    }

    var isThick: Bool {
        self == .thickArrow || self == .thickLine
    }
}

/// A declared node.
public struct FlowchartNode: Equatable, Sendable {
    public var id: String
    /// nil when the source wrote a bare id, in which case the id is the label.
    public var label: String?
    public var shape: NodeShape

    public init(id: String, label: String? = nil, shape: NodeShape) {
        self.id = id
        self.label = label
        self.shape = shape
    }
}

/// A declared connection.
public struct FlowchartEdge: Equatable, Sendable {
    public var from: String
    public var to: String
    public var label: String?
    public var style: EdgeStyle

    public init(from: String, to: String, label: String? = nil, style: EdgeStyle) {
        self.from = from
        self.to = to
        self.label = label
        self.style = style
    }
}

/// A `subgraph ... end` block.
public struct FlowchartSubgraph: Equatable, Sendable {
    public var id: String
    public var title: String?
    public var statements: [FlowchartStatement]

    public init(id: String, title: String? = nil, statements: [FlowchartStatement]) {
        self.id = id
        self.title = title
        self.statements = statements
    }
}

/// A `style <id> key:value,...` line.
public struct StyleStatement: Equatable, Sendable {
    public var nodeID: String
    public var properties: [(key: String, value: String)]

    public init(nodeID: String, properties: [(key: String, value: String)]) {
        self.nodeID = nodeID
        self.properties = properties
    }

    public static func == (lhs: StyleStatement, rhs: StyleStatement) -> Bool {
        lhs.nodeID == rhs.nodeID
            && lhs.properties.count == rhs.properties.count
            && zip(lhs.properties, rhs.properties).allSatisfy { $0 == $1 }
    }
}

/// One top-level element of a flowchart body.
public enum FlowchartStatement: Equatable, Sendable {
    case node(FlowchartNode)
    case edge(FlowchartEdge)
    case subgraph(FlowchartSubgraph)
    case style(StyleStatement)
}

/// A parsed flowchart or state diagram.
public struct FlowchartGraph: Equatable, Sendable {
    public var direction: GraphDirection
    public var statements: [FlowchartStatement]

    public init(direction: GraphDirection, statements: [FlowchartStatement]) {
        self.direction = direction
        self.statements = statements
    }

    /// True when any node uses a state-only shape, which switches the layout
    /// and renderer into state-diagram metrics.
    var containsStateShapes: Bool {
        Self.containsStateShapes(statements)
    }

    private static func containsStateShapes(_ statements: [FlowchartStatement]) -> Bool {
        for statement in statements {
            switch statement {
            case let .node(node) where node.shape.isStateShape:
                return true
            case let .subgraph(subgraph) where containsStateShapes(subgraph.statements):
                return true
            default:
                continue
            }
        }
        return false
    }
}
