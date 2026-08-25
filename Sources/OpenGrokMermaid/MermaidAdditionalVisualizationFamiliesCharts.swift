import Foundation

func parseXYChartVisualization(
    statements: [MermaidVisualizationStatement]
) throws -> MermaidVisualizationResult {
    var chart = MermaidXYChart(
        title: nil,
        xTitle: nil,
        yTitle: nil,
        categories: [],
        yMinimum: nil,
        yMaximum: nil,
        series: []
    )
    for statement in statements {
        let text = statement.text
        if text.hasPrefix("title ") {
            chart.title = try visualizationLabel(String(text.dropFirst(6)), line: statement.line)
            continue
        }
        if text.hasPrefix("x-axis ") {
            let axis = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            if let opening = axis.firstIndex(of: "[") {
                guard axis.hasSuffix("]") else {
                    throw MermaidError.parse(line: statement.line, message: "Invalid x-axis categories")
                }
                let title = axis[..<opening].trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { chart.xTitle = try visualizationLabel(title, line: statement.line) }
                let values = axis[axis.index(after: opening)..<axis.index(before: axis.endIndex)]
                chart.categories = try splitVisualizationCSV(String(values)).map {
                    try visualizationLabel($0, line: statement.line)
                }
            } else if let arrow = axis.range(of: "-->") {
                let left = axis[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let right = axis[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                let leftParts = left.split(whereSeparator: \.isWhitespace)
                guard let minimum = leftParts.last else {
                    throw MermaidError.parse(line: statement.line, message: "Invalid x-axis range")
                }
                _ = try finiteVisualizationNumber(String(minimum), line: statement.line, description: "x-axis minimum")
                _ = try finiteVisualizationNumber(right, line: statement.line, description: "x-axis maximum")
                if leftParts.count > 1 {
                    chart.xTitle = try visualizationLabel(leftParts.dropLast().joined(separator: " "), line: statement.line)
                }
            } else if !axis.isEmpty {
                chart.xTitle = try visualizationLabel(axis, line: statement.line)
            }
            continue
        }
        if text.hasPrefix("y-axis ") {
            let axis = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            if let arrow = axis.range(of: "-->") {
                let left = axis[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let right = axis[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                let pieces = left.split(whereSeparator: \.isWhitespace)
                guard let minimum = pieces.last else {
                    throw MermaidError.parse(line: statement.line, message: "Invalid y-axis range")
                }
                chart.yMinimum = try finiteVisualizationNumber(String(minimum), line: statement.line, description: "y-axis minimum")
                chart.yMaximum = try finiteVisualizationNumber(right, line: statement.line, description: "y-axis maximum")
                guard let low = chart.yMinimum, let high = chart.yMaximum, high > low else {
                    throw MermaidError.parse(line: statement.line, message: "The y-axis maximum must exceed its minimum")
                }
                if pieces.count > 1 {
                    chart.yTitle = try visualizationLabel(pieces.dropLast().joined(separator: " "), line: statement.line)
                }
            } else if !axis.isEmpty {
                chart.yTitle = try visualizationLabel(axis, line: statement.line)
            }
            continue
        }
        // The pinned upstream parser intentionally ignores bar declarations;
        // a chart containing only ignored series still fails the nonempty gate.
        guard text.hasPrefix("line ") || text.hasPrefix("line[") else {
            if text.hasPrefix("bar ") || text.hasPrefix("bar[") { continue }
            throw MermaidError.parse(line: statement.line, message: "Unrecognized xychart series: \(text)")
        }
        let values = try parseVisualizationNumbers(
            String(text.dropFirst("line".count)),
            line: statement.line,
            noun: "xychart series"
        )
        guard !values.isEmpty else {
            throw MermaidError.parse(line: statement.line, message: "Empty xychart series")
        }
        if !chart.categories.isEmpty, chart.categories.count != values.count {
            throw MermaidError.parse(line: statement.line, message: "Series length does not match x-axis categories")
        }
        try requireVisualizationCapacity(chart.series.count, maximum: 32, line: statement.line, noun: "series")
        chart.series.append(MermaidXYSeries(isBar: false, values: values))
    }
    guard !chart.series.isEmpty else {
        throw MermaidError.parse(line: 1, message: "xychart requires at least one plot")
    }
    let values = chart.series.flatMap(\.values)
    let low = chart.yMinimum ?? min(values.min() ?? 0, 0)
    let high = chart.yMaximum ?? max(values.max() ?? 1, low + 1)
    guard (high - low).isFinite else {
        throw MermaidError.parse(line: 1, message: "xychart values exceed the supported numeric range")
    }
    let graph = chart.series.enumerated().flatMap { seriesIndex, series in
        series.values.enumerated().map { valueIndex, value -> FlowchartStatement in
            let category = chart.categories.indices.contains(valueIndex) ? chart.categories[valueIndex] : String(valueIndex + 1)
            return .node(
                FlowchartNode(
                    id: "__xy_\(seriesIndex)_\(valueIndex)",
                    label: "\(category): \(visualizationNumber(value))",
                    shape: series.isBar ? .rectangle : .circle
                )
            )
        }
    }
    guard graph.count <= MermaidVisualizationLimits.maximumNodes else {
        throw MermaidError.parse(line: 1, message: "xychart exceeds the maximum point count")
    }
    return MermaidVisualizationResult(
        kind: .xyChart,
        graph: FlowchartGraph(direction: .leftToRight, statements: graph),
        diagram: .xyChart(chart)
    )
}

func parseRadarVisualization(
    statements: [MermaidVisualizationStatement]
) throws -> MermaidVisualizationResult {
    var axes: [String] = []
    var curves: [MermaidRadarCurve] = []
    var seen: Set<String> = []
    for statement in statements {
        let text = statement.text
        if text.hasPrefix("axis ") {
            guard axes.isEmpty else {
                throw MermaidError.parse(line: statement.line, message: "Duplicate radar axis declaration")
            }
            axes = try splitVisualizationCSV(String(text.dropFirst(5))).map {
                try visualizationLabel($0, line: statement.line)
            }
            guard axes.count >= 3,
                  axes.count < MermaidVisualizationLimits.maximumNodes,
                  Set(axes).count == axes.count else {
                throw MermaidError.parse(line: statement.line, message: "Radar charts require at least three unique axes")
            }
            continue
        }
        guard text.hasPrefix("curve "),
              let opening = text.firstIndex(of: "{"), text.hasSuffix("}") else {
            throw MermaidError.parse(line: statement.line, message: "Invalid radar curve: \(text)")
        }
        let label = try visualizationLabel(String(text[text.index(text.startIndex, offsetBy: 6)..<opening]), line: statement.line)
        guard seen.insert(label).inserted else {
            throw MermaidError.parse(line: statement.line, message: "Duplicate radar curve: \(label)")
        }
        let inner = text[text.index(after: opening)..<text.index(before: text.endIndex)]
        let values = try splitVisualizationCSV(String(inner)).map {
            try finiteVisualizationNumber($0, line: statement.line, description: "radar value")
        }
        guard !axes.isEmpty, values.count == axes.count, values.allSatisfy({ $0 >= 0 }) else {
            throw MermaidError.parse(line: statement.line, message: "Radar curves require one nonnegative value per axis")
        }
        try requireVisualizationCapacity(curves.count, maximum: 32, line: statement.line, noun: "curve")
        curves.append(MermaidRadarCurve(label: label, values: values))
    }
    guard !axes.isEmpty, !curves.isEmpty else {
        throw MermaidError.parse(line: 1, message: "Radar charts require axes and at least one curve")
    }
    var graph: [FlowchartStatement] = []
    let root = FlowchartNode(id: "__radar_center", label: "Radar", shape: .circle)
    graph.append(.node(root))
    for (index, axis) in axes.enumerated() {
        let id = "__radar_axis_\(index)"
        graph.append(.node(FlowchartNode(id: id, label: axis, shape: .roundedRectangle)))
        graph.append(.edge(FlowchartEdge(from: root.id, to: id, style: .line)))
    }
    return MermaidVisualizationResult(
        kind: .radar,
        graph: FlowchartGraph(direction: .leftToRight, statements: graph),
        diagram: .radar(MermaidRadarChart(axes: axes, curves: curves))
    )
}

func parseSankeyVisualization(
    statements: [MermaidVisualizationStatement]
) throws -> MermaidVisualizationResult {
    var nodes: [String] = []
    var seen: Set<String> = []
    var links: [MermaidSankeyLink] = []
    for statement in statements {
        let values = splitVisualizationCSV(statement.text)
        guard values.count == 3 else {
            throw MermaidError.parse(line: statement.line, message: "Invalid sankey link: \(statement.text)")
        }
        let source = try visualizationLabel(values[0], line: statement.line)
        let target = try visualizationLabel(values[1], line: statement.line)
        let weight = try finiteVisualizationNumber(values[2], line: statement.line, description: "sankey value")
        guard source != target, weight > 0 else {
            throw MermaidError.parse(line: statement.line, message: "Sankey links require distinct nodes and a positive value")
        }
        for node in [source, target] where seen.insert(node).inserted {
            try requireVisualizationCapacity(nodes.count, maximum: MermaidVisualizationLimits.maximumNodes, line: statement.line, noun: "node")
            nodes.append(node)
        }
        try requireVisualizationCapacity(links.count, maximum: MermaidVisualizationLimits.maximumEdges, line: statement.line, noun: "link")
        links.append(MermaidSankeyLink(source: source, target: target, value: weight))
    }
    guard !links.isEmpty else {
        throw MermaidError.parse(line: 1, message: "Sankey diagrams require at least one flow")
    }
    let ids = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element, "__sankey_\($0.offset)") })
    var graph = nodes.map { node -> FlowchartStatement in
        .node(FlowchartNode(id: ids[node] ?? node, label: node, shape: .rectangle))
    }
    graph.append(contentsOf: links.map {
        .edge(
            FlowchartEdge(
                from: ids[$0.source] ?? $0.source,
                to: ids[$0.target] ?? $0.target,
                label: visualizationNumber($0.value),
                style: .thickLine
            )
        )
    })
    return MermaidVisualizationResult(
        kind: .sankey,
        graph: FlowchartGraph(direction: .leftToRight, statements: graph),
        diagram: .sankey(MermaidSankeyDiagram(nodes: nodes, links: links))
    )
}

func parsePacketVisualization(
    statements: [MermaidVisualizationStatement]
) throws -> MermaidVisualizationResult {
    var title: String?
    var fields: [MermaidPacketField] = []
    for statement in statements {
        let text = statement.text
        if text.hasPrefix("title ") {
            title = try visualizationLabel(String(text.dropFirst(6)), line: statement.line)
            continue
        }
        guard let colon = text.firstIndex(of: ":") else {
            throw MermaidError.parse(line: statement.line, message: "Invalid packet field: \(text)")
        }
        let range = text[..<colon].trimmingCharacters(in: .whitespaces)
        let bounds = range.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(bounds.count),
              let first = Int(bounds[0].trimmingCharacters(in: .whitespaces)) else {
            throw MermaidError.parse(line: statement.line, message: "Invalid packet bit range: \(range)")
        }
        let last: Int
        if bounds.count == 2 {
            guard let parsed = Int(bounds[1].trimmingCharacters(in: .whitespaces)) else {
                throw MermaidError.parse(line: statement.line, message: "Invalid packet bit range: \(range)")
            }
            last = parsed
        } else {
            last = first
        }
        guard first >= 0, last >= first, last < 4_096 else {
            throw MermaidError.parse(line: statement.line, message: "Invalid packet bit range: \(range)")
        }
        if let previous = fields.last, first != previous.lastBit + 1 {
            throw MermaidError.parse(line: statement.line, message: "Packet fields must be contiguous and nonoverlapping")
        }
        let label = try visualizationLabel(String(text[text.index(after: colon)...]), line: statement.line)
        try requireVisualizationCapacity(fields.count, maximum: MermaidVisualizationLimits.maximumNodes, line: statement.line, noun: "field")
        fields.append(MermaidPacketField(firstBit: first, lastBit: last, label: label))
    }
    guard !fields.isEmpty else {
        throw MermaidError.parse(line: 1, message: "Packet diagrams require at least one field")
    }
    let graph = fields.enumerated().map { index, field -> FlowchartStatement in
        let range = field.firstBit == field.lastBit ? String(field.firstBit) : "\(field.firstBit)-\(field.lastBit)"
        return .node(FlowchartNode(id: "__packet_\(index)", label: "\(range)\n\(field.label)", shape: .rectangle))
    }
    return MermaidVisualizationResult(
        kind: .packet,
        graph: FlowchartGraph(direction: .leftToRight, statements: graph),
        diagram: .packet(MermaidPacketDiagram(title: title, fields: fields))
    )
}

func parseRequirementVisualization(
    statements: [MermaidVisualizationStatement]
) throws -> MermaidVisualizationResult {
    let categories: Set<String> = [
        "element", "requirement", "functionalrequirement", "interfacerequirement",
        "performancerequirement", "physicalrequirement", "designconstraint",
    ]
    var direction = GraphDirection.topToBottom
    var nodes: [MermaidRequirementNode] = []
    var relationships: [MermaidRequirementRelationship] = []
    var known: Set<String> = []
    var active: Int?
    for statement in statements {
        let text = statement.text
        if let index = active {
            if text == "}" {
                active = nil
                continue
            }
            guard let colon = text.firstIndex(of: ":") else {
                throw MermaidError.parse(line: statement.line, message: "Invalid requirement property: \(text)")
            }
            let name = try visualizationLabel(String(text[..<colon]), line: statement.line)
            let value = try visualizationLabel(String(text[text.index(after: colon)...]), line: statement.line)
            guard !nodes[index].properties.contains(where: { $0.name == name }) else {
                throw MermaidError.parse(line: statement.line, message: "Duplicate requirement property: \(name)")
            }
            nodes[index].properties.append((name, value))
            continue
        }
        if text.hasPrefix("direction ") {
            let raw = String(text.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            guard let value = GraphDirection.parse(raw) else { throw MermaidError.invalidDirection(raw) }
            direction = value
            continue
        }
        let parts = text.split(whereSeparator: \.isWhitespace)
        if let category = parts.first, categories.contains(category.lowercased()) {
            guard parts.count >= 2, text.hasSuffix("{") else {
                throw MermaidError.parse(line: statement.line, message: "Expected a braced requirement declaration")
            }
            let id = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "{"))
            let normalized = try visualizationLabel(id, line: statement.line)
            guard known.insert(normalized).inserted else {
                throw MermaidError.parse(line: statement.line, message: "Duplicate requirement: \(normalized)")
            }
            try requireVisualizationCapacity(nodes.count, maximum: MermaidVisualizationLimits.maximumNodes, line: statement.line, noun: "node")
            nodes.append(MermaidRequirementNode(id: normalized, category: String(category), properties: []))
            active = nodes.count - 1
            continue
        }
        if let arrow = text.range(of: "->") {
            let before = text[..<arrow.lowerBound].split(whereSeparator: \.isWhitespace).filter { $0 != "-" }
            let target = text[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            guard before.count >= 2, !target.isEmpty else {
                throw MermaidError.parse(line: statement.line, message: "Invalid requirement relationship: \(text)")
            }
            relationships.append(
                MermaidRequirementRelationship(
                    source: String(before[0]),
                    target: target,
                    kind: String(before[1])
                )
            )
            continue
        }
        if let arrow = text.range(of: "<-") {
            let target = text[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let after = text[arrow.upperBound...].split(whereSeparator: \.isWhitespace).filter { $0 != "-" }
            guard after.count >= 2, !target.isEmpty else {
                throw MermaidError.parse(line: statement.line, message: "Invalid requirement relationship: \(text)")
            }
            relationships.append(MermaidRequirementRelationship(source: String(after[1]), target: target, kind: String(after[0])))
            continue
        }
        throw MermaidError.parse(line: statement.line, message: "Unrecognized requirement diagram line: \(text)")
    }
    guard active == nil else {
        throw MermaidError.parse(line: statements.last?.line ?? 1, message: "Unterminated requirement declaration")
    }
    guard !nodes.isEmpty else {
        throw MermaidError.parse(line: 1, message: "Requirement diagrams require at least one node")
    }
    for relationship in relationships {
        guard known.contains(relationship.source), known.contains(relationship.target) else {
            throw MermaidError.parse(line: 1, message: "Requirement relationship references an undeclared node")
        }
    }
    var graph = nodes.map { node -> FlowchartStatement in
        var lines = ["«\(node.category)»", node.id]
        lines.append(contentsOf: node.properties.map { "\($0.name): \($0.value)" })
        return .node(FlowchartNode(id: node.id, label: lines.joined(separator: "\n"), shape: .rectangle))
    }
    graph.append(contentsOf: relationships.map {
        .edge(FlowchartEdge(from: $0.source, to: $0.target, label: $0.kind, style: .dottedArrow))
    })
    return MermaidVisualizationResult(
        kind: .requirementDiagram,
        graph: FlowchartGraph(direction: direction, statements: graph),
        diagram: .requirementDiagram(MermaidRequirementDiagram(direction: direction, nodes: nodes, relationships: relationships))
    )
}

func parseBlockVisualization(
    statements: [MermaidVisualizationStatement]
) throws -> MermaidVisualizationResult {
    var columns: Int?
    var nodes: [FlowchartNode] = []
    var indices: [String: Int] = [:]
    var edges: [FlowchartEdge] = []

    func addNode(_ raw: String, line: Int) throws -> FlowchartNode {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let id: String
        let label: String
        if let opening = value.firstIndex(of: "[") {
            guard value.hasSuffix("]") else {
                throw MermaidError.parse(line: line, message: "Invalid block node: \(value)")
            }
            id = try visualizationLabel(String(value[..<opening]), line: line)
            label = try visualizationLabel(String(value[value.index(after: opening)..<value.index(before: value.endIndex)]), line: line)
        } else {
            id = try visualizationLabel(value, line: line)
            label = id
        }
        guard !id.contains(where: \.isWhitespace) else {
            throw MermaidError.parse(line: line, message: "Invalid block node identifier: \(id)")
        }
        if let index = indices[id] {
            if label != id { nodes[index].label = label }
            return nodes[index]
        }
        try requireVisualizationCapacity(nodes.count, maximum: MermaidVisualizationLimits.maximumNodes, line: line, noun: "node")
        let node = FlowchartNode(id: id, label: label, shape: .rectangle)
        indices[id] = nodes.count
        nodes.append(node)
        return node
    }

    for statement in statements {
        let text = statement.text
        if text.hasPrefix("columns ") {
            let value = text.dropFirst(8).trimmingCharacters(in: .whitespaces)
            if value == "auto" {
                columns = nil
            } else if let count = Int(value), (1...32).contains(count) {
                columns = count
            } else {
                throw MermaidError.parse(line: statement.line, message: "Invalid block column count: \(value)")
            }
            continue
        }
        if text == "end" || text == "space" || text.hasPrefix("space:")
            || text.hasPrefix("block:") || text.hasPrefix("block ")
            || text.hasPrefix("style ") || text.hasPrefix("classDef ")
            || text.hasPrefix("class ") || text.hasPrefix("linkStyle ") {
            continue
        }
        if let arrow = text.range(of: "-->") {
            let from = try addNode(String(text[..<arrow.lowerBound]), line: statement.line)
            let to = try addNode(String(text[arrow.upperBound...]), line: statement.line)
            try requireVisualizationCapacity(edges.count, maximum: MermaidVisualizationLimits.maximumEdges, line: statement.line, noun: "edge")
            edges.append(FlowchartEdge(from: from.id, to: to.id, style: .arrow))
            continue
        }
        _ = try addNode(text, line: statement.line)
    }
    guard !nodes.isEmpty else {
        throw MermaidError.parse(line: 1, message: "Block diagrams require at least one node")
    }
    var graph = nodes.map(FlowchartStatement.node)
    graph.append(contentsOf: edges.map(FlowchartStatement.edge))
    return MermaidVisualizationResult(
        kind: .blockDiagram,
        graph: FlowchartGraph(direction: columns == 1 ? .topToBottom : .leftToRight, statements: graph),
        diagram: .blockDiagram(MermaidBlockDiagram(columns: columns, nodes: nodes, edges: edges))
    )
}

func parseC4Visualization(
    statements: [MermaidVisualizationStatement],
    family: String
) throws -> MermaidVisualizationResult {
    var title: String?
    var nodes: [MermaidC4Node] = []
    var relationships: [MermaidC4Relationship] = []
    var known: Set<String> = []
    var boundaryStack: [String] = []
    for statement in statements {
        let text = statement.text
        if text.hasPrefix("title ") {
            title = try visualizationLabel(String(text.dropFirst(6)), line: statement.line)
            continue
        }
        if text == "}" || text == "end" {
            guard !boundaryStack.isEmpty else {
                throw MermaidError.parse(line: statement.line, message: "Unexpected C4 boundary terminator")
            }
            boundaryStack.removeLast()
            continue
        }
        guard let opening = text.firstIndex(of: "("),
              let closing = text.lastIndex(of: ")"), opening < closing else {
            throw MermaidError.parse(line: statement.line, message: "Invalid C4 declaration: \(text)")
        }
        let function = text[..<opening].trimmingCharacters(in: .whitespaces)
        let arguments = try splitVisualizationCSV(String(text[text.index(after: opening)..<closing])).map {
            try visualizationLabel($0, line: statement.line)
        }
        if function.contains("Boundary") {
            guard arguments.count >= 2, text[closing...].contains("{") else {
                throw MermaidError.parse(line: statement.line, message: "Invalid C4 boundary: \(text)")
            }
            boundaryStack.append(arguments[1])
            continue
        }
        if function.hasPrefix("Rel") || function.hasPrefix("BiRel") {
            guard arguments.count >= 3 else {
                throw MermaidError.parse(line: statement.line, message: "Invalid C4 relationship: \(text)")
            }
            try requireVisualizationCapacity(relationships.count, maximum: MermaidVisualizationLimits.maximumEdges, line: statement.line, noun: "relationship")
            relationships.append(MermaidC4Relationship(source: arguments[0], target: arguments[1], label: arguments[2]))
            continue
        }
        guard ["Person", "System", "Container", "Component", "Deployment", "Node"].contains(where: { function.hasPrefix($0) }),
              arguments.count >= 2 else {
            throw MermaidError.parse(line: statement.line, message: "Unsupported C4 declaration: \(text)")
        }
        let id = arguments[0]
        guard known.insert(id).inserted else {
            throw MermaidError.parse(line: statement.line, message: "Duplicate C4 identifier: \(id)")
        }
        try requireVisualizationCapacity(nodes.count, maximum: MermaidVisualizationLimits.maximumNodes, line: statement.line, noun: "node")
        let hasTechnology = function.hasPrefix("Container") || function.hasPrefix("Component")
        let technology = hasTechnology && arguments.count >= 3 ? arguments[2] : nil
        let descriptionIndex = hasTechnology ? 3 : 2
        let description = arguments.indices.contains(descriptionIndex) ? arguments[descriptionIndex] : nil
        nodes.append(
            MermaidC4Node(
                id: id,
                category: function,
                label: arguments[1],
                technology: technology,
                description: description,
                boundary: boundaryStack.last
            )
        )
    }
    guard boundaryStack.isEmpty else {
        throw MermaidError.parse(line: statements.last?.line ?? 1, message: "Unterminated C4 boundary")
    }
    guard !nodes.isEmpty else {
        throw MermaidError.parse(line: 1, message: "C4 diagrams require at least one declared element")
    }
    for relationship in relationships {
        guard known.contains(relationship.source), known.contains(relationship.target) else {
            throw MermaidError.parse(line: 1, message: "C4 relationship references an undeclared element")
        }
    }
    var graph = nodes.enumerated().map { index, node -> FlowchartStatement in
        let label = [index == 0 ? title : nil, node.boundary, node.label, "[\(node.category)]", node.technology, node.description]
            .compactMap { $0 }
            .joined(separator: "\n")
        let shape: NodeShape = node.category.contains("Db") ? .cylinder : .roundedRectangle
        return .node(FlowchartNode(id: node.id, label: label, shape: shape))
    }
    graph.append(contentsOf: relationships.map {
        .edge(FlowchartEdge(from: $0.source, to: $0.target, label: $0.label, style: .arrow))
    })
    return MermaidVisualizationResult(
        kind: .c4Diagram,
        graph: FlowchartGraph(direction: .leftToRight, statements: graph),
        diagram: .c4Diagram(MermaidC4Diagram(family: family, title: title, nodes: nodes, relationships: relationships))
    )
}
