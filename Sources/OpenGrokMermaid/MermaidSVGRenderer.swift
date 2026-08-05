// MermaidSVGRenderer.swift
//
// Open Grok — Swift port of `mermaid_to_svg::svg_renderer`
// (third_party/mermaid-to-svg/src/svg_renderer.rs, W8-S2).
//
// Draws a laid-out diagram as self-contained SVG: a background rect, arrowhead
// markers, cluster boxes, edges, node shapes, and text. The output is a pure
// function of the layout and theme, so identical input yields byte-identical
// SVG.

import Foundation

/// Which interpolation the edge polylines are drawn with.
enum EdgeCurve {
    /// Mermaid's default: a cubic B-spline through the route points.
    case basis
    case linear

    static func parse(_ name: String) -> EdgeCurve {
        name.lowercased() == "linear" ? .linear : .basis
    }
}

struct SVGRenderOptions {
    var fontFamily = "Trebuchet MS, verdana, arial, sans-serif"
    var fontSize = MermaidTextWrap.defaultFontSize
    var wrappingWidth = MermaidTextWrap.defaultWrapWidth
    var edgeCurve = EdgeCurve.basis

    init() {}

    init(_ config: RenderConfig) {
        let defaults = SVGRenderOptions()
        fontFamily = config.fontFamily ?? defaults.fontFamily
        fontSize = config.fontSizePixels() ?? defaults.fontSize
        wrappingWidth = config.flowchart.wrappingWidth.map(Double.init) ?? defaults.wrappingWidth
        edgeCurve = config.flowchart.curve.map(EdgeCurve.parse) ?? defaults.edgeCurve
    }
}

/// Renders a laid-out flowchart or state diagram to SVG.
public func renderFlowchartSVG(
    _ layout: MermaidLayoutResult,
    theme: MermaidTheme = .light,
    config: RenderConfig = RenderConfig()
) -> String {
    var renderer = SVGRenderer(
        layout: layout,
        theme: theme,
        options: SVGRenderOptions(config)
    )
    return renderer.render()
}

private struct SVGRenderer {
    /// The arrowhead marker has refX=5 in a 0..10 viewBox at markerWidth 8, so
    /// its tip reaches (10-5)/10 * 8 = 4px past the reference point. Each arrowed
    /// edge is shortened by that much so the tip lands on the node border.
    private static let arrowheadOffset: Double = 4
    private static let arrowheadOffsetThick: Double = 5.5

    private static let edgeLabelPaddingHorizontal: Double = 2
    private static let edgeLabelPaddingVertical: Double = 2
    private static let edgeLabelBackgroundOpacity: Double = 0.8

    private let layout: MermaidLayoutResult
    private let theme: MermaidTheme
    private let options: SVGRenderOptions
    private let isStateDiagram: Bool
    private var output = ""

    init(layout: MermaidLayoutResult, theme: MermaidTheme, options: SVGRenderOptions) {
        self.layout = layout
        self.theme = theme
        self.options = options
        self.isStateDiagram = layout.nodes.contains { $0.shape.isStateShape }
    }

    mutating func render() -> String {
        writeHeader()
        writeDefs()

        for subgraph in layout.subgraphs {
            renderSubgraphBackground(subgraph)
        }
        for edge in layout.edges {
            renderEdgeLine(edge)
        }
        // Sorted by id so the draw order does not depend on declaration order.
        for node in layout.nodes.sorted(by: { $0.id < $1.id }) {
            renderNode(node)
        }
        for subgraph in layout.subgraphs {
            renderSubgraphTitle(subgraph)
        }
        renderEdgeLabels()

        output += "</svg>\n"
        return output
    }

    // MARK: - Document scaffolding

    private mutating func writeHeader() {
        let width = format(layout.width, decimals: 0)
        let height = format(layout.height, decimals: 0)
        output += """
            <?xml version="1.0" encoding="UTF-8"?>
            <svg width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)" \
            xmlns="http://www.w3.org/2000/svg" style="background-color: \(theme.background);">
            <rect x="0" y="0" width="\(width)" height="\(height)" fill="\(theme.background)" stroke="none"/>

            """
    }

    private mutating func writeDefs() {
        output += """
            <defs>
              <marker id="arrowhead" markerWidth="8" markerHeight="8" refX="5" refY="5" \
            orient="auto" markerUnits="userSpaceOnUse" viewBox="0 0 10 10">
                <path d="M 0 0 L 10 5 L 0 10 z" fill="\(theme.edgeColor)" \
            stroke="\(theme.edgeColor)" stroke-width="1"/>
              </marker>
              <marker id="arrowhead-thick" markerWidth="11" markerHeight="11" refX="5" refY="5" \
            orient="auto" markerUnits="userSpaceOnUse" viewBox="0 0 10 10">
                <path d="M 0 0 L 10 5 L 0 10 z" fill="\(theme.edgeColor)" \
            stroke="\(theme.edgeColor)" stroke-width="1"/>
              </marker>
            </defs>

            """
    }

    // MARK: - Subgraphs

    private mutating func renderSubgraphBackground(_ subgraph: MermaidLayoutSubgraph) {
        output += """
            <rect x="\(f(subgraph.x))" y="\(f(subgraph.y))" width="\(f(subgraph.width))" \
            height="\(f(subgraph.height))" fill="\(theme.subgraphFill)" \
            stroke="\(theme.subgraphStroke)" stroke-width="1"/>

            """
    }

    private mutating func renderSubgraphTitle(_ subgraph: MermaidLayoutSubgraph) {
        guard let title = subgraph.title else { return }
        let charWidth = MermaidTextWrap.scaleCharWidth(
            MermaidTextWrap.defaultCharWidth,
            fontSize: options.fontSize
        )
        let lines = MermaidTextWrap.wrapTextLines(
            title,
            maxWidth: options.wrappingWidth,
            charWidth: charWidth
        )
        guard !lines.isEmpty else { return }

        let measured = MermaidTextWrap.measure(
            lines: lines,
            charWidth: charWidth,
            fontSize: options.fontSize
        )
        renderTextLines(
            x: subgraph.x + subgraph.width / 2,
            y: subgraph.y + measured.height / 2,
            lines: lines,
            color: theme.textColor
        )
    }

    // MARK: - Nodes

    private mutating func renderNode(_ node: MermaidLayoutNode) {
        switch node.shape {
        case .rectangle: renderRectangle(node, cornerRadius: 0)
        case .roundedRectangle: renderRectangle(node, cornerRadius: 5)
        case .stadium: renderRectangle(node, cornerRadius: node.height / 2)
        case .diamond: renderDiamond(node)
        case .circle: renderCircle(node)
        case .startState: renderStartState(node)
        case .endState: renderEndState(node)
        case .forkJoin: renderForkJoin(node)
        case .hexagon: renderHexagon(node)
        case .cylinder: renderCylinder(node)
        case .subroutine: renderSubroutine(node)
        case .asymmetric: renderAsymmetric(node)
        }
    }

    private func fill(_ node: MermaidLayoutNode) -> String { node.fillColor ?? theme.nodeFill }
    private func stroke(_ node: MermaidLayoutNode) -> String { node.strokeColor ?? theme.nodeStroke }

    private mutating func renderRectangle(_ node: MermaidLayoutNode, cornerRadius: Double) {
        output += """
            <rect x="\(f(node.x - node.width / 2))" y="\(f(node.y - node.height / 2))" \
            width="\(f(node.width))" height="\(f(node.height))" rx="\(f(cornerRadius))" \
            fill="\(fill(node))" stroke="\(stroke(node))" stroke-width="1"/>

            """
        renderText(x: node.x, y: node.y, text: node.label)
    }

    private mutating func renderStartState(_ node: MermaidLayoutNode) {
        let radius = min(node.width, node.height) / 2
        output += """
            <circle cx="\(f(node.x))" cy="\(f(node.y))" r="\(f(radius))" \
            fill="\(theme.edgeColor)" stroke="\(theme.edgeColor)" stroke-width="1.5"/>

            """
    }

    private mutating func renderEndState(_ node: MermaidLayoutNode) {
        let outerRadius = min(node.width, node.height) / 2
        let innerRadius = min(max(outerRadius - 4, outerRadius * 0.55), outerRadius - 2)
        output += """
            <circle cx="\(f(node.x))" cy="\(f(node.y))" r="\(f(outerRadius))" \
            fill="\(theme.nodeStroke)" stroke="\(theme.background)" stroke-width="1"/>

            """
        output += """
            <circle cx="\(f(node.x))" cy="\(f(node.y))" r="\(f(innerRadius))" \
            fill="\(theme.background)" stroke="none"/>

            """
    }

    private mutating func renderForkJoin(_ node: MermaidLayoutNode) {
        output += """
            <rect x="\(f(node.x - node.width / 2))" y="\(f(node.y - node.height / 2))" \
            width="\(f(node.width))" height="\(f(node.height))" rx="1" \
            fill="\(theme.edgeColor)" stroke="\(theme.edgeColor)" stroke-width="1"/>

            """
    }

    private mutating func renderDiamond(_ node: MermaidLayoutNode) {
        let halfWidth = node.width / 2
        let halfHeight = node.height / 2
        let points = [
            (node.x, node.y - halfHeight),
            (node.x + halfWidth, node.y),
            (node.x, node.y + halfHeight),
            (node.x - halfWidth, node.y),
        ]
        renderPolygon(points, node: node)
        renderText(x: node.x, y: node.y, text: node.label)
    }

    private mutating func renderCircle(_ node: MermaidLayoutNode) {
        let radius = min(node.width, node.height) / 2
        output += """
            <circle cx="\(f(node.x))" cy="\(f(node.y))" r="\(f(radius))" \
            fill="\(fill(node))" stroke="\(stroke(node))" stroke-width="1"/>

            """
        renderText(x: node.x, y: node.y, text: node.label)
    }

    private mutating func renderHexagon(_ node: MermaidLayoutNode) {
        let halfWidth = node.width / 2
        let halfHeight = node.height / 2
        let inset = node.height / 3
        let points = [
            (node.x - halfWidth + inset, node.y - halfHeight),
            (node.x + halfWidth - inset, node.y - halfHeight),
            (node.x + halfWidth, node.y),
            (node.x + halfWidth - inset, node.y + halfHeight),
            (node.x - halfWidth + inset, node.y + halfHeight),
            (node.x - halfWidth, node.y),
        ]
        renderPolygon(points, node: node)
        renderText(x: node.x, y: node.y, text: node.label)
    }

    private mutating func renderCylinder(_ node: MermaidLayoutNode) {
        let halfWidth = node.width / 2
        let halfHeight = node.height / 2
        let ellipseRY = min(halfWidth / 4, halfHeight / 2)
        let left = node.x - halfWidth
        let bodyTop = node.y - halfHeight + ellipseRY
        let bodyBottom = node.y + halfHeight - ellipseRY

        output += """
            <path d="M \(f(left)) \(f(bodyTop)) L \(f(left)) \(f(bodyBottom)) \
            A \(f(halfWidth)) \(f(ellipseRY)) 0 0 0 \(f(node.x + halfWidth)) \(f(bodyBottom)) \
            L \(f(node.x + halfWidth)) \(f(bodyTop)) \
            A \(f(halfWidth)) \(f(ellipseRY)) 0 0 0 \(f(left)) \(f(bodyTop)) Z" \
            fill="\(fill(node))" stroke="\(stroke(node))" stroke-width="1"/>

            """
        output += """
            <ellipse cx="\(f(node.x))" cy="\(f(bodyTop))" rx="\(f(halfWidth))" \
            ry="\(f(ellipseRY))" fill="\(fill(node))" stroke="\(stroke(node))" stroke-width="1"/>

            """
        // Text sits in the body, clear of the top cap.
        renderText(x: node.x, y: (bodyTop + bodyBottom) / 2, text: node.label)
    }

    private mutating func renderSubroutine(_ node: MermaidLayoutNode) {
        let left = node.x - node.width / 2
        let top = node.y - node.height / 2
        let barInset: Double = 8

        output += """
            <rect x="\(f(left))" y="\(f(top))" width="\(f(node.width))" \
            height="\(f(node.height))" fill="\(fill(node))" stroke="\(stroke(node))" \
            stroke-width="1"/>

            """
        for x in [left + barInset, left + node.width - barInset] {
            output += """
                <line x1="\(f(x))" y1="\(f(top))" x2="\(f(x))" y2="\(f(top + node.height))" \
                stroke="\(stroke(node))" stroke-width="1"/>

                """
        }
        renderText(x: node.x, y: node.y, text: node.label)
    }

    private mutating func renderAsymmetric(_ node: MermaidLayoutNode) {
        let halfWidth = node.width / 2
        let halfHeight = node.height / 2
        // Mermaid's `>text]` flag: notched on the left, flat on the right.
        let pointOffset = halfHeight
        let points = [
            (node.x - halfWidth + pointOffset, node.y - halfHeight),
            (node.x + halfWidth, node.y - halfHeight),
            (node.x + halfWidth, node.y + halfHeight),
            (node.x - halfWidth + pointOffset, node.y + halfHeight),
            (node.x - halfWidth, node.y),
        ]
        renderPolygon(points, node: node)
        renderText(x: node.x + pointOffset / 4, y: node.y, text: node.label)
    }

    private mutating func renderPolygon(_ points: [(Double, Double)], node: MermaidLayoutNode) {
        let coordinates = points.map { "\(f($0.0)),\(f($0.1))" }.joined(separator: " ")
        output += """
            <polygon points="\(coordinates)" fill="\(fill(node))" stroke="\(stroke(node))" \
            stroke-width="1"/>

            """
    }

    // MARK: - Text

    private var textCharWidth: Double {
        MermaidTextWrap.scaleCharWidth(
            isStateDiagram ? MermaidTextWrap.stateCharWidth : MermaidTextWrap.defaultCharWidth,
            fontSize: options.fontSize
        )
    }

    private mutating func renderText(x: Double, y: Double, text: String) {
        let lines = MermaidTextWrap.wrapTextLines(
            text,
            maxWidth: options.wrappingWidth,
            charWidth: textCharWidth
        )
        guard !lines.isEmpty else { return }
        renderTextLines(x: x, y: y, lines: lines, color: theme.textColor)
    }

    private mutating func renderTextLines(
        x: Double,
        y: Double,
        lines: [[String]],
        color: String
    ) {
        let lineHeight = options.fontSize * MermaidTextWrap.defaultLineHeight
        // dominant-baseline="central" centres each line on its y, so the block is
        // distributed evenly around the anchor.
        let startY = y - (Double(lines.count) - 1) * lineHeight / 2

        output += """
            <text text-anchor="middle" dominant-baseline="central" \
            font-family="\(Self.escapeXML(options.fontFamily))" \
            font-size="\(format(options.fontSize, decimals: 0))" fill="\(color)">

            """
        for (index, line) in lines.enumerated() {
            let lineY = startY + Double(index) * lineHeight
            output += """
                <tspan x="\(f(x))" y="\(f(lineY))">\(Self.escapeXML(line.joined(separator: " ")))</tspan>

                """
        }
        output += "</text>\n"
    }

    // MARK: - Edges

    private mutating func renderEdgeLine(_ edge: MermaidLayoutEdge) {
        guard edge.points.count >= 2 else { return }

        let marker: String
        if edge.style.hasArrowhead {
            marker = edge.style.isThick
                ? #" marker-end="url(#arrowhead-thick)""#
                : #" marker-end="url(#arrowhead)""#
        } else {
            marker = ""
        }
        let strokeWidth = edge.style.isThick ? 3.5 : 1.0
        let dashArray = edge.style.isDotted ? #" stroke-dasharray="3 3""# : ""

        var points = edge.points
        if edge.style.hasArrowhead {
            Self.shortenEndForMarker(
                &points,
                by: edge.style.isThick ? Self.arrowheadOffsetThick : Self.arrowheadOffset
            )
        }

        output += """
            <path d="\(edgePathData(points))" fill="none" stroke="\(theme.edgeColor)" \
            stroke-width="\(f(strokeWidth))" stroke-linecap="round" stroke-linejoin="round"\
            \(dashArray)\(marker)/>

            """
    }

    /// Pulls the last point back so the marker's tip, not its reference point,
    /// lands where the route ended.
    private static func shortenEndForMarker(_ points: inout [MermaidPoint], by offset: Double) {
        guard points.count >= 2, offset > 0 else { return }
        let lastIndex = points.count - 1
        let previous = points[lastIndex - 1]
        let last = points[lastIndex]

        let dx = last.x - previous.x
        let dy = last.y - previous.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > offset else { return }

        points[lastIndex] = MermaidPoint(
            x: last.x - dx / length * offset,
            y: last.y - dy / length * offset
        )
    }

    private func edgePathData(_ points: [MermaidPoint]) -> String {
        switch options.edgeCurve {
        case .basis:
            return Self.basisSplinePath(Self.roundCorners(points))
        case .linear:
            return Self.linearPath(points)
        }
    }

    private static func linearPath(_ points: [MermaidPoint]) -> String {
        guard let first = points.first else { return "" }
        var d = "M\(fixed(first.x)),\(fixed(first.y))"
        for point in points.dropFirst() {
            d += "L\(fixed(point.x)),\(fixed(point.y))"
        }
        return d
    }

    /// A uniform cubic B-spline through `points`, matching d3's `curveBasis`
    /// (which is what mermaid.js uses for flowchart edges).
    private static func basisSplinePath(_ points: [MermaidPoint]) -> String {
        guard !points.isEmpty else { return "" }

        var d = ""
        var x0 = Double.nan
        var y0 = Double.nan
        var x1 = Double.nan
        var y1 = Double.nan
        var state = 0

        for point in points {
            switch state {
            case 0:
                state = 1
                d += "M\(fixed(point.x)),\(fixed(point.y))"
            case 1:
                state = 2
            case 2:
                state = 3
                d += "L\(fixed((5 * x0 + x1) / 6)),\(fixed((5 * y0 + y1) / 6))"
                d += basisSegment(x0, y0, x1, y1, point.x, point.y)
            default:
                d += basisSegment(x0, y0, x1, y1, point.x, point.y)
            }
            x0 = x1
            x1 = point.x
            y0 = y1
            y1 = point.y
        }

        switch state {
        case 3:
            d += basisSegment(x0, y0, x1, y1, x1, y1)
            d += "L\(fixed(x1)),\(fixed(y1))"
        case 2:
            d += "L\(fixed(x1)),\(fixed(y1))"
        default:
            break
        }

        return d
    }

    private static func basisSegment(
        _ x0: Double, _ y0: Double,
        _ x1: Double, _ y1: Double,
        _ x: Double, _ y: Double
    ) -> String {
        "C\(fixed((2 * x0 + x1) / 3)),\(fixed((2 * y0 + y1) / 3))"
            + " \(fixed((x0 + 2 * x1) / 3)),\(fixed((y0 + 2 * y1) / 3))"
            + " \(fixed((x0 + 4 * x1 + x) / 6)),\(fixed((y0 + 4 * y1 + y) / 6))"
    }

    /// Replaces each right-angle turn with three points a short way back along
    /// each leg, so the spline rounds the corner instead of cutting it.
    static func roundCorners(_ points: [MermaidPoint]) -> [MermaidPoint] {
        let corners = Set(cornerPositions(points))
        var result: [MermaidPoint] = []

        for (index, point) in points.enumerated() {
            guard corners.contains(index) else {
                result.append(point)
                continue
            }

            let previous = points[index - 1]
            let next = points[index + 1]
            let newPrevious = pointNear(previous, towards: point, distance: 5)
            let newNext = pointNear(next, towards: point, distance: 5)
            let xDiff = newNext.x - newPrevious.x
            let yDiff = newNext.y - newPrevious.y

            var newCorner = point
            let a = 2.0.squareRoot() * 2
            if abs(next.x - previous.x) > 10 && abs(next.y - previous.y) >= 10 {
                if abs(point.x - newPrevious.x) < .ulpOfOne {
                    newCorner = MermaidPoint(
                        x: xDiff < 0 ? newPrevious.x - 5 + a : newPrevious.x + 5 - a,
                        y: yDiff < 0 ? newPrevious.y - a : newPrevious.y + a
                    )
                } else {
                    newCorner = MermaidPoint(
                        x: xDiff < 0 ? newPrevious.x - a : newPrevious.x + a,
                        y: yDiff < 0 ? newPrevious.y - 5 + a : newPrevious.y + 5 - a
                    )
                }
            }

            result.append(newPrevious)
            result.append(newCorner)
            result.append(newNext)
        }

        return result
    }

    /// Indices of points where the polyline turns a clean right angle with legs
    /// long enough to round.
    private static func cornerPositions(_ points: [MermaidPoint]) -> [Int] {
        guard points.count >= 3 else { return [] }
        var positions: [Int] = []
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let current = points[index]
            let next = points[index + 1]
            let verticalThenHorizontal = abs(previous.x - current.x) < .ulpOfOne
                && abs(current.y - next.y) < .ulpOfOne
                && abs(current.x - next.x) > 5
                && abs(current.y - previous.y) > 5
            let horizontalThenVertical = abs(previous.y - current.y) < .ulpOfOne
                && abs(current.x - next.x) < .ulpOfOne
                && abs(current.x - previous.x) > 5
                && abs(current.y - next.y) > 5
            if verticalThenHorizontal || horizontalThenVertical {
                positions.append(index)
            }
        }
        return positions
    }

    private static func pointNear(
        _ a: MermaidPoint,
        towards b: MermaidPoint,
        distance: Double
    ) -> MermaidPoint {
        let xDiff = b.x - a.x
        let yDiff = b.y - a.y
        let length = (xDiff * xDiff + yDiff * yDiff).squareRoot()
        guard length != 0 else { return a }
        let ratio = distance / length
        return MermaidPoint(x: b.x - ratio * xDiff, y: b.y - ratio * yDiff)
    }

    // MARK: - Edge labels

    private struct EdgeLabelBox {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var lines: [[String]]
    }

    private mutating func renderEdgeLabels() {
        let charWidth = textCharWidth
        var labels: [EdgeLabelBox] = []

        for edge in layout.edges {
            guard let label = edge.label,
                  !label.trimmingCharacters(in: .whitespaces).isEmpty,
                  edge.labelPosition != nil || edge.points.count >= 2
            else { continue }

            let position: MermaidPoint
            if let candidate = edge.labelPosition, candidate.x > 0, candidate.y > 0 {
                position = candidate
            } else {
                position = FlowchartLayoutEngine.polylineMidpoint(Self.roundCorners(edge.points))
            }

            let lines = MermaidTextWrap.wrapTextLines(
                label,
                maxWidth: options.wrappingWidth,
                charWidth: charWidth
            )
            guard !lines.isEmpty else { continue }

            let maxLineWidth = lines
                .map { MermaidTextWrap.lineWidth(words: $0, charWidth: charWidth) }
                .max() ?? 0
            let totalHeight = MermaidTextWrap.wrappedTextHeight(
                lineCount: lines.count,
                fontSize: options.fontSize
            )
            labels.append(
                EdgeLabelBox(
                    x: position.x,
                    y: position.y,
                    width: maxLineWidth + Self.edgeLabelPaddingHorizontal * 2,
                    height: totalHeight + Self.edgeLabelPaddingVertical * 2,
                    lines: lines
                )
            )
        }

        separateOverlappingLabels(&labels)

        for label in labels {
            output += """
                <rect x="\(f(label.x - label.width / 2))" y="\(f(label.y - label.height / 2))" \
                width="\(f(label.width))" height="\(f(label.height))" \
                fill="rgba(232,232,232,\(format(Self.edgeLabelBackgroundOpacity, decimals: 1)))" rx="2"/>

                """
            renderTextLines(x: label.x, y: label.y, lines: label.lines, color: theme.textColor)
        }
    }

    /// Nudges overlapping label boxes apart along whichever axis they overlap
    /// least, a few rounds at a time.
    private func separateOverlappingLabels(_ labels: inout [EdgeLabelBox]) {
        let minimumSeparation: Double = 8
        let maximumIterations = 10

        for _ in 0..<maximumIterations {
            var anyCollision = false

            for i in labels.indices {
                for j in labels.indices where j > i {
                    let aLeft = labels[i].x - labels[i].width / 2 - minimumSeparation
                    let aRight = labels[i].x + labels[i].width / 2 + minimumSeparation
                    let aTop = labels[i].y - labels[i].height / 2 - minimumSeparation
                    let aBottom = labels[i].y + labels[i].height / 2 + minimumSeparation

                    let bLeft = labels[j].x - labels[j].width / 2 - minimumSeparation
                    let bRight = labels[j].x + labels[j].width / 2 + minimumSeparation
                    let bTop = labels[j].y - labels[j].height / 2 - minimumSeparation
                    let bBottom = labels[j].y + labels[j].height / 2 + minimumSeparation

                    guard aRight > bLeft, bRight > aLeft, aBottom > bTop, bBottom > aTop else {
                        continue
                    }
                    anyCollision = true

                    let overlapX = min(aRight - bLeft, bRight - aLeft)
                    let overlapY = min(aBottom - bTop, bBottom - aTop)

                    if overlapX < overlapY {
                        let shift = overlapX / 2
                        if labels[j].x - labels[i].x >= 0 {
                            labels[i].x -= shift
                            labels[j].x += shift
                        } else {
                            labels[i].x += shift
                            labels[j].x -= shift
                        }
                    } else {
                        let shift = overlapY / 2
                        if labels[j].y - labels[i].y >= 0 {
                            labels[i].y -= shift
                            labels[j].y += shift
                        } else {
                            labels[i].y += shift
                            labels[j].y -= shift
                        }
                    }
                }
            }

            if !anyCollision { break }
        }
    }

    // MARK: - Formatting

    private func f(_ value: Double) -> String { Self.fixed(value) }

    /// One decimal place, matching upstream's `{:.1}` coordinate formatting.
    private static func fixed(_ value: Double) -> String {
        format(value, decimals: 1)
    }

    static func escapeXML(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&#39;")
        return escaped
    }
}

/// Fixed-point formatting that never emits a locale separator or `-0`.
private func format(_ value: Double, decimals: Int) -> String {
    guard value.isFinite else { return "0" }
    let scale = pow(10.0, Double(decimals))
    // Round half away from zero, as Rust's `{:.N}` does.
    var rounded = (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    if rounded == 0 { rounded = 0 }
    return String(format: "%.\(decimals)f", rounded)
}
