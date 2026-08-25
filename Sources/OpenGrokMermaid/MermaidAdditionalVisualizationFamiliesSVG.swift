import Foundation

func renderMermaidVisualizationSVG(
    _ visualization: MermaidVisualizationDiagram,
    layout: MermaidLayoutResult,
    theme: MermaidTheme,
    config: RenderConfig
) -> String {
    switch visualization {
    case let .pie(chart):
        return renderPieVisualizationSVG(chart, theme: theme)
    case let .gantt(chart):
        return renderGanttVisualizationSVG(chart, theme: theme)
    case let .quadrantChart(chart):
        return renderQuadrantVisualizationSVG(chart, theme: theme)
    case let .xyChart(chart):
        return renderXYVisualizationSVG(chart, theme: theme)
    case let .radar(chart):
        return renderRadarVisualizationSVG(chart, theme: theme)
    case let .packet(diagram):
        return renderPacketVisualizationSVG(diagram, theme: theme)
    case let .sankey(diagram):
        return renderSankeyVisualizationSVG(diagram, layout: layout, theme: theme)
    case let .information(version):
        var svg = MermaidVisualizationSVG(width: 400, height: 150, role: "info", theme: theme)
        svg.text("Mermaid v\(version)", x: 200, y: 77, size: 30, anchor: "middle")
        return svg.finish()
    case let .requirementDiagram(requirements):
        var svg = renderFlowchartSVG(layout, theme: theme, config: config)
        let description = requirements.nodes.map { node in
            ([node.category, node.id] + node.properties.map { "\($0.name): \($0.value)" })
                .joined(separator: "; ")
        }.joined(separator: "\n")
        if let opening = svg.range(of: "<svg "),
           let ending = svg[opening.upperBound...].firstIndex(of: ">") {
            svg.insert(
                contentsOf: "\n<desc>\(MermaidVisualizationSVG.escape(description))</desc>",
                at: svg.index(after: ending)
            )
        }
        return svg
    case .mindmap, .timeline, .journey, .gitGraph, .kanban, .blockDiagram, .c4Diagram:
        return renderFlowchartSVG(layout, theme: theme, config: config)
    }
}

private let visualizationPalette = [
    "#ECECFF", "#ffffde", "#b8e986", "#c4b5fd", "#86efac", "#93c5fd",
    "#f9a8d4", "#67e8f9", "#fca5a5", "#fde68a", "#a7f3d0", "#d8b4fe",
]

private struct MermaidVisualizationSVG {
    let width: Double
    let height: Double
    let theme: MermaidTheme
    private(set) var output: String

    init(width: Double, height: Double, role: String, theme: MermaidTheme) {
        self.width = width
        self.height = height
        self.theme = theme
        let escapedRole = Self.escape(role)
        let w = visualizationNumber(width)
        let h = visualizationNumber(height)
        output = """
            <?xml version="1.0" encoding="UTF-8"?>
            <svg width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)" xmlns="http://www.w3.org/2000/svg" aria-roledescription="\(escapedRole)" style="background-color: \(theme.background);">
            <rect x="0" y="0" width="\(w)" height="\(h)" fill="\(theme.background)" stroke="none"/>

            """
    }

    mutating func text(
        _ value: String,
        x: Double,
        y: Double,
        size: Double = 14,
        anchor: String = "start",
        color: String? = nil
    ) {
        output += "<text x=\"\(visualizationNumber(x))\" y=\"\(visualizationNumber(y))\" "
        output += "font-family=\"Trebuchet MS, verdana, arial, sans-serif\" "
        output += "font-size=\"\(visualizationNumber(size))\" text-anchor=\"\(anchor)\" "
        output += "fill=\"\(color ?? theme.textColor)\">\(Self.escape(value))</text>\n"
    }

    mutating func rectangle(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        fill: String? = nil,
        stroke: String? = nil,
        radius: Double = 0,
        opacity: Double? = nil
    ) {
        output += "<rect x=\"\(visualizationNumber(x))\" y=\"\(visualizationNumber(y))\" "
        output += "width=\"\(visualizationNumber(width))\" height=\"\(visualizationNumber(height))\" "
        output += "rx=\"\(visualizationNumber(radius))\" fill=\"\(fill ?? theme.nodeFill)\" "
        output += "stroke=\"\(stroke ?? theme.nodeStroke)\""
        if let opacity { output += " fill-opacity=\"\(visualizationNumber(opacity))\"" }
        output += "/>\n"
    }

    mutating func line(
        x1: Double,
        y1: Double,
        x2: Double,
        y2: Double,
        color: String? = nil,
        width: Double = 1,
        dashed: Bool = false
    ) {
        output += "<line x1=\"\(visualizationNumber(x1))\" y1=\"\(visualizationNumber(y1))\" "
        output += "x2=\"\(visualizationNumber(x2))\" y2=\"\(visualizationNumber(y2))\" "
        output += "stroke=\"\(color ?? theme.edgeColor)\" stroke-width=\"\(visualizationNumber(width))\""
        if dashed { output += " stroke-dasharray=\"4 4\"" }
        output += "/>\n"
    }

    mutating func circle(x: Double, y: Double, radius: Double, fill: String, stroke: String? = nil) {
        output += "<circle cx=\"\(visualizationNumber(x))\" cy=\"\(visualizationNumber(y))\" "
        output += "r=\"\(visualizationNumber(radius))\" fill=\"\(fill)\" "
        output += "stroke=\"\(stroke ?? theme.nodeStroke)\"/>\n"
    }

    mutating func path(_ data: String, fill: String = "none", stroke: String? = nil, width: Double = 1, opacity: Double? = nil) {
        output += "<path d=\"\(data)\" fill=\"\(fill)\" stroke=\"\(stroke ?? theme.edgeColor)\" "
        output += "stroke-width=\"\(visualizationNumber(width))\""
        if let opacity { output += " opacity=\"\(visualizationNumber(opacity))\"" }
        output += "/>\n"
    }

    mutating func polygon(_ points: [(Double, Double)], fill: String, stroke: String, opacity: Double = 0.35) {
        let coordinates = points.map { "\(visualizationNumber($0.0)),\(visualizationNumber($0.1))" }
            .joined(separator: " ")
        output += "<polygon points=\"\(coordinates)\" fill=\"\(fill)\" stroke=\"\(stroke)\" "
        output += "fill-opacity=\"\(visualizationNumber(opacity))\" stroke-width=\"2\"/>\n"
    }

    mutating func finish() -> String {
        output += "</svg>\n"
        return output
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private func renderPieVisualizationSVG(_ chart: MermaidPieChart, theme: MermaidTheme) -> String {
    let total = chart.slices.reduce(0) { $0 + $1.value }
    let legendWidth = chart.slices.map {
        MermaidTextWrap.lineWidth($0.label, charWidth: 8) + (chart.showData ? 80 : 0)
    }.max() ?? 120
    let width = max(520, 350 + legendWidth)
    let height = max(400, 100 + Double(chart.slices.count) * 28)
    var svg = MermaidVisualizationSVG(width: width, height: height, role: "pie", theme: theme)
    if let title = chart.title { svg.text(title, x: 170, y: 30, size: 20, anchor: "middle") }
    let centerX = 170.0
    let centerY = 205.0
    let radius = 138.0
    var angle = -Double.pi / 2
    let sorted = chart.slices.enumerated().sorted {
        $0.element.value == $1.element.value ? $0.offset < $1.offset : $0.element.value > $1.element.value
    }
    for (index, item) in sorted.enumerated() where item.element.value > 0 {
        let fraction = item.element.value / total
        guard fraction * 100 >= 1 else { continue }
        let color = visualizationPalette[index % visualizationPalette.count]
        if fraction >= 0.999_999 {
            svg.circle(x: centerX, y: centerY, radius: radius, fill: color)
        } else {
            let end = angle + fraction * Double.pi * 2
            let startX = centerX + radius * cos(angle)
            let startY = centerY + radius * sin(angle)
            let endX = centerX + radius * cos(end)
            let endY = centerY + radius * sin(end)
            let largeArc = fraction > 0.5 ? 1 : 0
            let path = "M \(visualizationNumber(centerX)) \(visualizationNumber(centerY)) "
                + "L \(visualizationNumber(startX)) \(visualizationNumber(startY)) "
                + "A \(visualizationNumber(radius)) \(visualizationNumber(radius)) 0 \(largeArc) 1 "
                + "\(visualizationNumber(endX)) \(visualizationNumber(endY)) Z"
            svg.path(path, fill: color, stroke: theme.background)
            let middle = (angle + end) / 2
            svg.text(
                "\(Int((fraction * 100).rounded()))%",
                x: centerX + radius * 0.67 * cos(middle),
                y: centerY + radius * 0.67 * sin(middle) + 5,
                size: 13,
                anchor: "middle"
            )
            angle = end
        }
    }
    for (index, slice) in chart.slices.enumerated() {
        let y = 80 + Double(index) * 28
        let sortedIndex = sorted.firstIndex { $0.offset == index } ?? index
        svg.rectangle(x: 335, y: y - 13, width: 16, height: 16, fill: visualizationPalette[sortedIndex % visualizationPalette.count])
        let label = chart.showData ? "\(slice.label) [\(visualizationNumber(slice.value))]" : slice.label
        svg.text(label, x: 361, y: y)
    }
    return svg.finish()
}

private func renderGanttVisualizationSVG(_ chart: MermaidGanttDiagram, theme: MermaidTheme) -> String {
    let minimum = chart.tasks.map(\.startDay).min() ?? 0
    let maximum = chart.tasks.map { $0.startDay + $0.durationDays }.max() ?? minimum + 1
    let range = max(maximum - minimum, 1)
    let unit = max(8.0, min(34.0, 480.0 / Double(range)))
    let left = 190.0
    let width = left + Double(range) * unit + 60
    let height = 100 + Double(chart.tasks.count) * 52
    var svg = MermaidVisualizationSVG(width: width, height: height, role: "gantt", theme: theme)
    if let title = chart.title { svg.text(title, x: width / 2, y: 30, size: 20, anchor: "middle") }
    svg.line(x1: left, y1: 54, x2: width - 35, y2: 54)
    for (index, task) in chart.tasks.enumerated() {
        let y = 74 + Double(index) * 52
        let x = left + Double(task.startDay - minimum) * unit
        let barWidth = max(Double(task.durationDays) * unit, 8)
        svg.text(task.title, x: 12, y: y + 16)
        if let section = task.section { svg.text(section, x: 12, y: y + 32, size: 11) }
        svg.rectangle(x: x, y: y, width: barWidth, height: 25, fill: visualizationPalette[index % visualizationPalette.count], radius: 4)
        svg.text("\(task.durationDays)d", x: x + barWidth / 2, y: y + 17, size: 11, anchor: "middle")
        if let dependency = task.dependencyID,
           let parentIndex = chart.tasks.firstIndex(where: { $0.id == dependency }) {
            let parent = chart.tasks[parentIndex]
            let parentX = left + Double(parent.startDay + parent.durationDays - minimum) * unit
            let parentY = 74 + Double(parentIndex) * 52 + 12
            svg.line(x1: parentX, y1: parentY, x2: x, y2: y + 12, dashed: true)
        }
    }
    return svg.finish()
}

private func renderQuadrantVisualizationSVG(_ chart: MermaidQuadrantChart, theme: MermaidTheme) -> String {
    let left = 90.0
    let top = 70.0
    let side = 380.0
    var svg = MermaidVisualizationSVG(width: 580, height: 525, role: "quadrantChart", theme: theme)
    if let title = chart.title { svg.text(title, x: left + side / 2, y: 30, size: 19, anchor: "middle") }
    svg.rectangle(x: left, y: top, width: side / 2, height: side / 2, fill: visualizationPalette[0], opacity: 0.55)
    svg.rectangle(x: left + side / 2, y: top, width: side / 2, height: side / 2, fill: visualizationPalette[1], opacity: 0.55)
    svg.rectangle(x: left, y: top + side / 2, width: side / 2, height: side / 2, fill: visualizationPalette[2], opacity: 0.38)
    svg.rectangle(x: left + side / 2, y: top + side / 2, width: side / 2, height: side / 2, fill: visualizationPalette[3], opacity: 0.4)
    svg.line(x1: left + side / 2, y1: top, x2: left + side / 2, y2: top + side, width: 1.5)
    svg.line(x1: left, y1: top + side / 2, x2: left + side, y2: top + side / 2, width: 1.5)
    for (number, location) in [(1, (0.75, 0.2)), (2, (0.25, 0.2)), (3, (0.25, 0.83)), (4, (0.75, 0.83))] {
        if let label = chart.quadrantLabels[number] {
            svg.text(label, x: left + side * location.0, y: top + side * location.1, size: 12, anchor: "middle")
        }
    }
    if let axis = chart.xAxis {
        svg.text(axis.low, x: left, y: top + side + 27)
        svg.text(axis.high, x: left + side, y: top + side + 27, anchor: "end")
    }
    if let axis = chart.yAxis {
        svg.text(axis.high, x: left - 8, y: top + 8, size: 11, anchor: "end")
        svg.text(axis.low, x: left - 8, y: top + side, size: 11, anchor: "end")
    }
    for (index, point) in chart.points.enumerated() {
        let x = left + point.x * side
        let y = top + (1 - point.y) * side
        svg.circle(x: x, y: y, radius: 6, fill: visualizationPalette[(index + 4) % visualizationPalette.count])
        svg.text(point.label, x: x + 9, y: y - 7, size: 12)
    }
    return svg.finish()
}

private func renderXYVisualizationSVG(_ chart: MermaidXYChart, theme: MermaidTheme) -> String {
    let width = 720.0
    let height = 440.0
    let left = 80.0
    let top = 65.0
    let plotWidth = 580.0
    let plotHeight = 300.0
    let values = chart.series.flatMap(\.values)
    let low = chart.yMinimum ?? min(values.min() ?? 0, 0)
    let high = chart.yMaximum ?? max(values.max() ?? 1, low + 1)
    let range = max(high - low, 1)
    let count = chart.series.map { $0.values.count }.max() ?? 1
    let spacing = plotWidth / Double(max(count, 1))
    var svg = MermaidVisualizationSVG(width: width, height: height, role: "xychart", theme: theme)
    if let title = chart.title { svg.text(title, x: width / 2, y: 30, size: 19, anchor: "middle") }
    svg.line(x1: left, y1: top, x2: left, y2: top + plotHeight, width: 1.5)
    svg.line(x1: left, y1: top + plotHeight, x2: left + plotWidth, y2: top + plotHeight, width: 1.5)
    for index in 0...5 {
        let fraction = Double(index) / 5
        let y = top + plotHeight * (1 - fraction)
        svg.line(x1: left, y1: y, x2: left + plotWidth, y2: y, color: theme.subgraphStroke, dashed: true)
        svg.text(visualizationNumber(low + range * fraction), x: left - 8, y: y + 4, size: 11, anchor: "end")
    }
    for (seriesIndex, series) in chart.series.enumerated() {
        let color = visualizationPalette[(seriesIndex + 3) % visualizationPalette.count]
        var points: [(Double, Double)] = []
        for (index, value) in series.values.enumerated() {
            let x = left + (Double(index) + 0.5) * spacing
            let y = top + plotHeight * (1 - (value - low) / range)
            if series.isBar {
                let barWidth = max(8, spacing * 0.55 / Double(max(chart.series.count, 1)))
                let adjustedX = x - spacing * 0.28 + Double(seriesIndex) * barWidth
                svg.rectangle(x: adjustedX, y: min(y, top + plotHeight), width: barWidth, height: abs(top + plotHeight - y), fill: color, radius: 2)
            } else {
                points.append((x, y))
            }
            if seriesIndex == 0 {
                let label = chart.categories.indices.contains(index) ? chart.categories[index] : String(index + 1)
                svg.text(label, x: x, y: top + plotHeight + 18, size: 11, anchor: "middle")
            }
        }
        if !series.isBar, let first = points.first {
            let segments = points.dropFirst().map { "L \(visualizationNumber($0.0)) \(visualizationNumber($0.1))" }.joined(separator: " ")
            svg.path("M \(visualizationNumber(first.0)) \(visualizationNumber(first.1)) \(segments)", stroke: color, width: 2.5)
            for point in points { svg.circle(x: point.0, y: point.1, radius: 4, fill: color) }
        }
    }
    if let title = chart.xTitle { svg.text(title, x: left + plotWidth / 2, y: height - 14, anchor: "middle") }
    if let title = chart.yTitle { svg.text(title, x: 12, y: top - 12, size: 12) }
    return svg.finish()
}

private func renderRadarVisualizationSVG(_ chart: MermaidRadarChart, theme: MermaidTheme) -> String {
    let centerX = 255.0
    let centerY = 245.0
    let radius = 150.0
    let maximum = max(chart.curves.flatMap(\.values).max() ?? 1, 1)
    var svg = MermaidVisualizationSVG(width: 620, height: 500, role: "radar", theme: theme)
    for ring in 1...4 {
        let fraction = Double(ring) / 4
        let points = chart.axes.indices.map { index -> (Double, Double) in
            let angle = -Double.pi / 2 + Double(index) / Double(chart.axes.count) * Double.pi * 2
            return (centerX + cos(angle) * radius * fraction, centerY + sin(angle) * radius * fraction)
        }
        svg.polygon(points, fill: "none", stroke: theme.subgraphStroke, opacity: 0)
    }
    for (index, axis) in chart.axes.enumerated() {
        let angle = -Double.pi / 2 + Double(index) / Double(chart.axes.count) * Double.pi * 2
        let x = centerX + cos(angle) * radius
        let y = centerY + sin(angle) * radius
        svg.line(x1: centerX, y1: centerY, x2: x, y2: y, dashed: true)
        svg.text(axis, x: centerX + cos(angle) * (radius + 20), y: centerY + sin(angle) * (radius + 20) + 4, size: 12, anchor: "middle")
    }
    for (curveIndex, curve) in chart.curves.enumerated() {
        let color = visualizationPalette[(curveIndex + 3) % visualizationPalette.count]
        let points = curve.values.enumerated().map { index, value -> (Double, Double) in
            let angle = -Double.pi / 2 + Double(index) / Double(chart.axes.count) * Double.pi * 2
            let distance = radius * value / maximum
            return (centerX + cos(angle) * distance, centerY + sin(angle) * distance)
        }
        svg.polygon(points, fill: color, stroke: color)
        let y = 85 + Double(curveIndex) * 25
        svg.rectangle(x: 465, y: y - 12, width: 14, height: 14, fill: color)
        svg.text(curve.label, x: 486, y: y, size: 12)
    }
    return svg.finish()
}

private func renderPacketVisualizationSVG(_ diagram: MermaidPacketDiagram, theme: MermaidTheme) -> String {
    let bitsPerRow = 32
    let bitWidth = 21.0
    let rowHeight = 66.0
    let left = 35.0
    let top = diagram.title == nil ? 35.0 : 60.0
    let highest = diagram.fields.map(\.lastBit).max() ?? 0
    let rows = highest / bitsPerRow + 1
    let height = top + Double(rows) * rowHeight + 30
    var svg = MermaidVisualizationSVG(width: left * 2 + Double(bitsPerRow) * bitWidth, height: height, role: "packet", theme: theme)
    if let title = diagram.title { svg.text(title, x: svg.width / 2, y: 28, size: 19, anchor: "middle") }
    for (index, field) in diagram.fields.enumerated() {
        var first = field.firstBit
        while first <= field.lastBit {
            let row = first / bitsPerRow
            let rowEnd = min(field.lastBit, (row + 1) * bitsPerRow - 1)
            let x = left + Double(first % bitsPerRow) * bitWidth
            let y = top + Double(row) * rowHeight
            let width = Double(rowEnd - first + 1) * bitWidth
            svg.rectangle(x: x, y: y + 16, width: width, height: 34, fill: visualizationPalette[index % visualizationPalette.count])
            svg.text(String(first), x: x + 3, y: y + 11, size: 10)
            svg.text(String(rowEnd), x: x + width - 3, y: y + 11, size: 10, anchor: "end")
            svg.text(field.label, x: x + width / 2, y: y + 38, size: 11, anchor: "middle")
            first = rowEnd + 1
        }
    }
    return svg.finish()
}

private func renderSankeyVisualizationSVG(
    _ diagram: MermaidSankeyDiagram,
    layout: MermaidLayoutResult,
    theme: MermaidTheme
) -> String {
    let padding = 25.0
    var svg = MermaidVisualizationSVG(width: layout.width + padding * 2, height: layout.height + padding * 2, role: "sankey", theme: theme)
    let ids = Dictionary(uniqueKeysWithValues: diagram.nodes.enumerated().map { ($0.element, "__sankey_\($0.offset)") })
    let largest = diagram.links.map(\.value).max() ?? 1
    for (index, link) in diagram.links.enumerated() {
        guard let sourceID = ids[link.source], let targetID = ids[link.target],
              let source = layout.node(id: sourceID), let target = layout.node(id: targetID) else { continue }
        let startX = source.x + source.width / 2 + padding
        let startY = source.y + padding
        let endX = target.x - target.width / 2 + padding
        let endY = target.y + padding
        let control = (startX + endX) / 2
        let data = "M \(visualizationNumber(startX)) \(visualizationNumber(startY)) "
            + "C \(visualizationNumber(control)) \(visualizationNumber(startY)) "
            + "\(visualizationNumber(control)) \(visualizationNumber(endY)) "
            + "\(visualizationNumber(endX)) \(visualizationNumber(endY))"
        svg.path(data, stroke: visualizationPalette[(index + 4) % visualizationPalette.count], width: max(3, link.value / largest * 25), opacity: 0.65)
        svg.text(visualizationNumber(link.value), x: control, y: (startY + endY) / 2 - 5, size: 11, anchor: "middle")
    }
    for (index, name) in diagram.nodes.enumerated() {
        guard let id = ids[name], let node = layout.node(id: id) else { continue }
        let x = node.x - node.width / 2 + padding
        let y = node.y - node.height / 2 + padding
        svg.rectangle(x: x, y: y, width: node.width, height: node.height, fill: visualizationPalette[index % visualizationPalette.count], radius: 3)
        svg.text(name, x: node.x + padding, y: node.y + padding + 5, size: 12, anchor: "middle")
    }
    return svg.finish()
}
