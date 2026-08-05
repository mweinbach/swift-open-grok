// OpenGrokMermaid.swift
//
// Open Grok — Mermaid diagram parsing and rendering (PORT_PLAN.md W8-S2).
//
// Ported from the vendored `mermaid-to-svg` crate (CRATE_MAP.md row 3); see
// THIRD-PARTY-NOTICES for its attribution and the mermaid.js ancestry behind it.
// Layout comes from OpenGrokMermaidLayout, the port of the dagre stack.
//
// The public surface is three steps, each usable on its own:
//
//   `MermaidRenderer.parse(_:)`  -> `MermaidDiagram`        (AST + config)
//   `MermaidRenderer.layout(_:)` -> `MermaidLayoutResult`   (placed geometry)
//   `MermaidRenderer.svg(_:)`    -> `String`                (SVG document)
//
// `MermaidRenderer.render(_:theme:)` runs all three. The layout result is the
// intermediate representation a terminal front end should consume — see
// `MermaidTerminalRendering` for how the Rust pager gets from here to pixels.

import Foundation

/// A parsed diagram, ready to lay out.
public struct MermaidDiagram: Equatable, Sendable {
    /// Which family the source declared.
    public enum Kind: Equatable, Sendable {
        case flowchart
        case stateDiagram
    }

    public var kind: Kind
    public var graph: FlowchartGraph
    /// Settings read from the source's frontmatter.
    public var config: RenderConfig
    /// Title read from the source's frontmatter, if any.
    public var title: String?
}

/// Parses, lays out, and renders Mermaid sources.
public enum MermaidRenderer {
    /// Parses `source`, including any frontmatter.
    ///
    /// Throws `MermaidError.unsupportedDiagramType` for families this port does
    /// not implement, and `.parse`/`.invalidDirection` for malformed sources.
    public static func parse(_ source: String) throws -> MermaidDiagram {
        let parsed = parseMermaidFrontmatter(source)
        let body = parsed.body
        let token = MermaidDiagramFamily.firstToken(of: body)

        let kind: MermaidDiagram.Kind
        let graph: FlowchartGraph
        switch token {
        case "stateDiagram", "stateDiagram-v2":
            kind = .stateDiagram
            graph = try parseStateDiagram(body)
        case "graph", "flowchart":
            kind = .flowchart
            graph = try parseFlowchart(body)
        case let other?:
            throw MermaidError.unsupportedDiagramType(other)
        case nil:
            throw MermaidError.parse(line: 1, message: "Expected graph declaration")
        }

        return MermaidDiagram(
            kind: kind,
            graph: graph,
            config: parsed.config,
            title: parsed.frontmatter?.title
        )
    }

    /// Places every node, cluster, and edge.
    public static func layout(_ diagram: MermaidDiagram) -> MermaidLayoutResult {
        // State diagrams reuse the flowchart layout; only their metrics differ,
        // and those are selected from the node shapes.
        computeFlowchartLayout(diagram.graph, config: diagram.config)
    }

    /// Draws a laid-out diagram as a self-contained SVG document.
    ///
    /// `theme` overrides whatever the source's frontmatter asked for; pass nil
    /// to honour the frontmatter, falling back to the light theme.
    public static func svg(
        _ layout: MermaidLayoutResult,
        diagram: MermaidDiagram,
        theme: MermaidTheme? = nil
    ) -> String {
        let resolvedTheme = theme ?? diagram.config.mermaidTheme() ?? .light
        return renderFlowchartSVG(layout, theme: resolvedTheme, config: diagram.config)
    }

    /// Parses, lays out, and renders `source` in one step.
    public static func render(_ source: String, theme: MermaidTheme? = nil) throws -> String {
        let diagram = try parse(source)
        return svg(layout(diagram), diagram: diagram, theme: theme)
    }
}

/// How a terminal front end turns a diagram into something it can display.
///
/// The Rust stack does not have a text-mode diagram renderer: `mermaid-to-svg`
/// emits SVG only, and the pager's diagram support lives one layer up in
/// `crates/codegen/xai-grok-mermaid`, which
///
///   1. calls `render_mermaid_to_svg`,
///   2. rasterizes that SVG to a PNG with `resvg`/`usvg`/`tiny-skia` and a
///      bundled Roboto face (no system font enumeration, so the raster is
///      deterministic too), sizing the bitmap to a terminal cell budget, and
///   3. hands the PNG to the pager, which emits it through a terminal graphics
///      protocol; where no protocol is available the pager falls back to showing
///      the diagram source as a fenced code block.
///
/// Step 1 is this target. Steps 2 and 3 belong to the pager slices: wiring them
/// up needs an SVG rasterizer and the terminal graphics negotiation in
/// OpenGrokPagerRender, neither of which this target depends on. Until then,
/// `MermaidLayoutResult` is the seam — it carries every box and polyline in
/// diagram coordinates, so a cell-grid renderer could also consume it directly
/// without going through SVG at all.
public enum MermaidTerminalRendering {
    /// Aspect ratio of the diagram, for fitting it to a cell budget.
    public static func aspectRatio(_ layout: MermaidLayoutResult) -> Double {
        guard layout.height > 0 else { return 1 }
        return layout.width / layout.height
    }
}
