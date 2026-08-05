// MermaidTheme.swift
//
// Open Grok — Swift port of `mermaid_to_svg::theme`
// (third_party/mermaid-to-svg/src/theme.rs, W8-S2).

/// The seven colours every diagram family draws with.
public struct MermaidTheme: Equatable, Hashable, Sendable {
    public var background: String
    public var nodeFill: String
    public var nodeStroke: String
    public var textColor: String
    public var edgeColor: String
    public var subgraphFill: String
    public var subgraphStroke: String

    public init(
        background: String,
        nodeFill: String,
        nodeStroke: String,
        textColor: String,
        edgeColor: String,
        subgraphFill: String,
        subgraphStroke: String
    ) {
        self.background = background
        self.nodeFill = nodeFill
        self.nodeStroke = nodeStroke
        self.textColor = textColor
        self.edgeColor = edgeColor
        self.subgraphFill = subgraphFill
        self.subgraphStroke = subgraphStroke
    }

    /// Mermaid's `default` palette, and this port's default.
    public static let light = MermaidTheme(
        background: "#ffffff",
        nodeFill: "#ECECFF",
        nodeStroke: "#9370DB",
        textColor: "#333333",
        edgeColor: "#333333",
        subgraphFill: "#ffffde",
        subgraphStroke: "#aaaa33"
    )

    public static let dark = MermaidTheme(
        background: "#1e1e1e",
        nodeFill: "#2d2d2d",
        nodeStroke: "#888888",
        textColor: "#ffffff",
        edgeColor: "#888888",
        subgraphFill: "#3a3a20",
        subgraphStroke: "#888844"
    )

    /// Mermaid's `base` preset, which upstream aliases to `default`.
    public static let base = light

    public static let forest = MermaidTheme(
        background: "#f4f4f4",
        nodeFill: "#cde498",
        nodeStroke: "#13540c",
        textColor: "#333333",
        edgeColor: "#333333",
        subgraphFill: "#cde498",
        subgraphStroke: "#13540c"
    )

    public static let neutral = MermaidTheme(
        background: "#ffffff",
        nodeFill: "#eeeeee",
        nodeStroke: "#999999",
        textColor: "#333333",
        edgeColor: "#333333",
        subgraphFill: "#eeeeee",
        subgraphStroke: "#999999"
    )
}

/// A named Mermaid theme, as written in `config: theme:` frontmatter.
public enum MermaidThemePreset: String, Equatable, Hashable, Sendable, CaseIterable {
    case `default`
    case base
    case dark
    case forest
    case neutral

    public var theme: MermaidTheme {
        switch self {
        case .default: return .light
        case .base: return .base
        case .dark: return .dark
        case .forest: return .forest
        case .neutral: return .neutral
        }
    }
}

/// Per-colour overrides from `config: themeVariables:` frontmatter.
public struct MermaidThemeVariables: Equatable, Hashable, Sendable {
    public var background: String?
    public var nodeFill: String?
    public var nodeStroke: String?
    public var textColor: String?
    public var edgeColor: String?
    public var subgraphFill: String?
    public var subgraphStroke: String?

    public init() {}

    public var isEmpty: Bool {
        background == nil && nodeFill == nil && nodeStroke == nil && textColor == nil
            && edgeColor == nil && subgraphFill == nil && subgraphStroke == nil
    }

    /// Maps a Mermaid theme-variable name onto this port's colour slots,
    /// returning false for names it does not model.
    @discardableResult
    public mutating func applyMermaidAlias(key: String, value: String) -> Bool {
        switch key {
        case "background": background = value
        case "primaryColor", "mainBkg": nodeFill = value
        case "primaryBorderColor", "nodeBorder": nodeStroke = value
        case "primaryTextColor", "nodeTextColor", "textColor": textColor = value
        case "lineColor", "defaultLinkColor": edgeColor = value
        case "clusterBkg": subgraphFill = value
        case "clusterBorder": subgraphStroke = value
        default: return false
        }
        return true
    }

    public func applied(to theme: MermaidTheme) -> MermaidTheme {
        var theme = theme
        if let background { theme.background = background }
        if let nodeFill { theme.nodeFill = nodeFill }
        if let nodeStroke { theme.nodeStroke = nodeStroke }
        if let textColor { theme.textColor = textColor }
        if let edgeColor { theme.edgeColor = edgeColor }
        if let subgraphFill { theme.subgraphFill = subgraphFill }
        if let subgraphStroke { theme.subgraphStroke = subgraphStroke }
        return theme
    }
}
