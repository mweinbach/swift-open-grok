import Foundation

public struct MermaidPieSlice: Equatable, Sendable {
    public var label: String
    public var value: Double
}

public struct MermaidPieChart: Equatable, Sendable {
    public var title: String?
    public var showData: Bool
    public var slices: [MermaidPieSlice]
}

public struct MermaidMindmapNode: Equatable, Sendable {
    public var id: String
    public var label: String
    public var shape: NodeShape
    public var parentID: String?
    public var depth: Int
}

public struct MermaidMindmapDiagram: Equatable, Sendable {
    public var nodes: [MermaidMindmapNode]
}

public struct MermaidTimelineEvent: Equatable, Sendable {
    public var period: String
    public var events: [String]
    public var section: String?
}

public struct MermaidTimelineDiagram: Equatable, Sendable {
    public var title: String?
    public var events: [MermaidTimelineEvent]
}

public struct MermaidJourneyTask: Equatable, Sendable {
    public var title: String
    public var score: Int
    public var actors: [String]
    public var section: String?
}

public struct MermaidJourneyDiagram: Equatable, Sendable {
    public var title: String?
    public var tasks: [MermaidJourneyTask]
}

public struct MermaidGanttTask: Equatable, Sendable {
    public var id: String
    public var title: String
    public var section: String?
    public var startDay: Int
    public var durationDays: Int
    public var dependencyID: String?
}

public struct MermaidGanttDiagram: Equatable, Sendable {
    public var title: String?
    public var tasks: [MermaidGanttTask]
}

public struct MermaidGitCommit: Equatable, Sendable {
    public var id: String
    public var branch: String
    public var parentIDs: [String]
    public var isMerge: Bool
    public var tag: String?
}

public struct MermaidGitGraphDiagram: Equatable, Sendable {
    public var branches: [String]
    public var commits: [MermaidGitCommit]
}

public struct MermaidKanbanTask: Equatable, Sendable {
    public var label: String
    public var assigned: String?
    public var priority: String?
    public var ticket: String?
}

public struct MermaidKanbanColumn: Equatable, Sendable {
    public var title: String
    public var tasks: [MermaidKanbanTask]
}

public struct MermaidKanbanDiagram: Equatable, Sendable {
    public var columns: [MermaidKanbanColumn]
}

public struct MermaidQuadrantPoint: Equatable, Sendable {
    public var label: String
    public var x: Double
    public var y: Double
}

public struct MermaidQuadrantChart: Equatable, Sendable {
    public var title: String?
    public var xAxis: (low: String, high: String)?
    public var yAxis: (low: String, high: String)?
    public var quadrantLabels: [Int: String]
    public var points: [MermaidQuadrantPoint]

    public static func == (lhs: MermaidQuadrantChart, rhs: MermaidQuadrantChart) -> Bool {
        lhs.title == rhs.title
            && lhs.xAxis?.low == rhs.xAxis?.low
            && lhs.xAxis?.high == rhs.xAxis?.high
            && lhs.yAxis?.low == rhs.yAxis?.low
            && lhs.yAxis?.high == rhs.yAxis?.high
            && lhs.quadrantLabels == rhs.quadrantLabels
            && lhs.points == rhs.points
    }
}

public struct MermaidXYSeries: Equatable, Sendable {
    public var isBar: Bool
    public var values: [Double]
}

public struct MermaidXYChart: Equatable, Sendable {
    public var title: String?
    public var xTitle: String?
    public var yTitle: String?
    public var categories: [String]
    public var yMinimum: Double?
    public var yMaximum: Double?
    public var series: [MermaidXYSeries]
}

public struct MermaidRadarCurve: Equatable, Sendable {
    public var label: String
    public var values: [Double]
}

public struct MermaidRadarChart: Equatable, Sendable {
    public var axes: [String]
    public var curves: [MermaidRadarCurve]
}

public struct MermaidSankeyLink: Equatable, Sendable {
    public var source: String
    public var target: String
    public var value: Double
}

public struct MermaidSankeyDiagram: Equatable, Sendable {
    public var nodes: [String]
    public var links: [MermaidSankeyLink]
}

public struct MermaidPacketField: Equatable, Sendable {
    public var firstBit: Int
    public var lastBit: Int
    public var label: String
}

public struct MermaidPacketDiagram: Equatable, Sendable {
    public var title: String?
    public var fields: [MermaidPacketField]
}

public struct MermaidRequirementNode: Equatable, Sendable {
    public var id: String
    public var category: String
    public var properties: [(name: String, value: String)]

    public static func == (lhs: MermaidRequirementNode, rhs: MermaidRequirementNode) -> Bool {
        lhs.id == rhs.id
            && lhs.category == rhs.category
            && lhs.properties.count == rhs.properties.count
            && zip(lhs.properties, rhs.properties).allSatisfy { $0 == $1 }
    }
}

public struct MermaidRequirementRelationship: Equatable, Sendable {
    public var source: String
    public var target: String
    public var kind: String
}

public struct MermaidRequirementDiagram: Equatable, Sendable {
    public var direction: GraphDirection
    public var nodes: [MermaidRequirementNode]
    public var relationships: [MermaidRequirementRelationship]
}

public struct MermaidBlockDiagram: Equatable, Sendable {
    public var columns: Int?
    public var nodes: [FlowchartNode]
    public var edges: [FlowchartEdge]
}

public struct MermaidC4Node: Equatable, Sendable {
    public var id: String
    public var category: String
    public var label: String
    public var technology: String?
    public var description: String?
    public var boundary: String?
}

public struct MermaidC4Relationship: Equatable, Sendable {
    public var source: String
    public var target: String
    public var label: String
}

public struct MermaidC4Diagram: Equatable, Sendable {
    public var family: String
    public var title: String?
    public var nodes: [MermaidC4Node]
    public var relationships: [MermaidC4Relationship]
}

public enum MermaidVisualizationDiagram: Equatable, Sendable {
    case pie(MermaidPieChart)
    case mindmap(MermaidMindmapDiagram)
    case timeline(MermaidTimelineDiagram)
    case journey(MermaidJourneyDiagram)
    case gantt(MermaidGanttDiagram)
    case gitGraph(MermaidGitGraphDiagram)
    case kanban(MermaidKanbanDiagram)
    case quadrantChart(MermaidQuadrantChart)
    case xyChart(MermaidXYChart)
    case radar(MermaidRadarChart)
    case sankey(MermaidSankeyDiagram)
    case packet(MermaidPacketDiagram)
    case requirementDiagram(MermaidRequirementDiagram)
    case blockDiagram(MermaidBlockDiagram)
    case c4Diagram(MermaidC4Diagram)
    case information(version: String)

    public var title: String? {
        switch self {
        case let .pie(chart): chart.title
        case let .timeline(chart): chart.title
        case let .journey(chart): chart.title
        case let .gantt(chart): chart.title
        case let .quadrantChart(chart): chart.title
        case let .xyChart(chart): chart.title
        case let .packet(chart): chart.title
        case let .c4Diagram(chart): chart.title
        default: nil
        }
    }
}

struct MermaidVisualizationResult {
    var kind: MermaidDiagram.Kind
    var graph: FlowchartGraph
    var diagram: MermaidVisualizationDiagram
}

enum MermaidVisualizationLimits {
    static let maximumSourceBytes = 1_048_576
    static let maximumStatements = 2_048
    static let maximumNodes = 128
    static let maximumEdges = 512
    static let maximumLabelBytes = 4_096
}

struct MermaidVisualizationStatement {
    var text: String
    var line: Int
    var indentation: Int
}

func mermaidVisualizationStatements(_ source: String) throws -> [MermaidVisualizationStatement] {
    guard source.utf8.count <= MermaidVisualizationLimits.maximumSourceBytes else {
        throw MermaidError.parse(line: 1, message: "Diagram exceeds the maximum source size")
    }
    var statements: [MermaidVisualizationStatement] = []
    for (offset, rawLine) in splitIntoLines(source).enumerated() {
        let indentation = rawLine.prefix { $0 == " " || $0 == "\t" }.reduce(0) {
            $0 + ($1 == "\t" ? 4 : 1)
        }
        var current = ""
        var quote: Character?
        var iterator = rawLine.makeIterator()
        while let character = iterator.next() {
            if character == "\"" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                current.append(character)
                continue
            }
            if quote == nil, character == "%", current.last == "%" {
                current.removeLast()
                break
            }
            if quote == nil, character == ";" {
                try appendVisualizationStatement(current, line: offset + 1, indentation: indentation, into: &statements)
                current.removeAll(keepingCapacity: true)
                continue
            }
            if character.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) && $0 != "\t"
            }) {
                throw MermaidError.parse(line: offset + 1, message: "Diagram contains a terminal control character")
            }
            current.append(character)
        }
        guard quote == nil else {
            throw MermaidError.parse(line: offset + 1, message: "Unterminated quoted diagram text")
        }
        try appendVisualizationStatement(current, line: offset + 1, indentation: indentation, into: &statements)
    }
    return statements
}

private func appendVisualizationStatement(
    _ raw: String,
    line: Int,
    indentation: Int,
    into statements: inout [MermaidVisualizationStatement]
) throws {
    let value = raw.trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty else { return }
    guard statements.count < MermaidVisualizationLimits.maximumStatements else {
        throw MermaidError.parse(line: line, message: "Diagram exceeds the maximum statement count")
    }
    guard value.utf8.count <= MermaidVisualizationLimits.maximumLabelBytes else {
        throw MermaidError.parse(line: line, message: "Diagram statement exceeds the maximum size")
    }
    statements.append(MermaidVisualizationStatement(text: value, line: line, indentation: indentation))
}

func parseMermaidVisualization(_ source: String, token: String) throws -> MermaidVisualizationResult {
    let statements = try mermaidVisualizationStatements(source)
    guard let header = statements.first,
          header.text.split(whereSeparator: \.isWhitespace).first == Substring(token) else {
        throw MermaidError.parse(line: 1, message: "Expected '\(token)' declaration")
    }
    let body = Array(statements.dropFirst())
    switch token {
    case "pie":
        return try parsePieVisualization(header: header, statements: body)
    case "mindmap":
        return try parseMindmapVisualization(statements: body)
    case "timeline":
        return try parseTimelineVisualization(statements: body)
    case "journey":
        return try parseJourneyVisualization(statements: body)
    case "gantt":
        return try parseGanttVisualization(statements: body)
    case "gitGraph":
        return try parseGitGraphVisualization(statements: body)
    case "kanban":
        return try parseKanbanVisualization(statements: body)
    case "quadrantChart":
        return try parseQuadrantVisualization(statements: body)
    case "xychart-beta":
        return try parseXYChartVisualization(statements: body)
    case "radar-beta":
        return try parseRadarVisualization(statements: body)
    case "sankey-beta":
        return try parseSankeyVisualization(statements: body)
    case "packet-beta":
        return try parsePacketVisualization(statements: body)
    case "requirementDiagram":
        return try parseRequirementVisualization(statements: body)
    case "block-beta":
        return try parseBlockVisualization(statements: body)
    case "C4Context", "C4Container", "C4Component", "C4Dynamic", "C4Deployment":
        return try parseC4Visualization(statements: body, family: token)
    case "info":
        guard body.isEmpty else {
            throw MermaidError.parse(line: body[0].line, message: "Unexpected info diagram statement")
        }
        let node = FlowchartNode(id: "mermaid_version", label: "Mermaid v11.12.2", shape: .roundedRectangle)
        return MermaidVisualizationResult(
            kind: .information,
            graph: FlowchartGraph(direction: .topToBottom, statements: [.node(node)]),
            diagram: .information(version: "11.12.2")
        )
    default:
        throw MermaidError.unsupportedDiagramType(token)
    }
}

func requireVisualizationCapacity(_ count: Int, maximum: Int, line: Int, noun: String) throws {
    guard count < maximum else {
        throw MermaidError.parse(line: line, message: "Diagram exceeds the maximum \(noun) count")
    }
}

func visualizationLabel(_ raw: String, line: Int) throws -> String {
    let label = normalizeLabel(raw)
    guard !label.isEmpty,
          label.utf8.count <= MermaidVisualizationLimits.maximumLabelBytes,
          !label.unicodeScalars.contains(where: {
              CharacterSet.controlCharacters.contains($0) && $0 != "\n"
          }) else {
        throw MermaidError.parse(line: line, message: "Invalid or unsafe diagram label")
    }
    return label
}

func finiteVisualizationNumber(_ raw: String, line: Int, description: String) throws -> Double {
    guard let value = Double(raw.trimmingCharacters(in: .whitespaces)), value.isFinite else {
        throw MermaidError.parse(line: line, message: "Invalid \(description): \(raw)")
    }
    return value
}

func parsePieVisualization(
    header: MermaidVisualizationStatement,
    statements: [MermaidVisualizationStatement]
) throws -> MermaidVisualizationResult {
    let showData = header.text.split(whereSeparator: \.isWhitespace).dropFirst().contains("showData")
    var title: String?
    var slices: [MermaidPieSlice] = []
    var seen: Set<String> = []
    for statement in statements {
        if statement.text.hasPrefix("title ") {
            title = try visualizationLabel(String(statement.text.dropFirst(6)), line: statement.line)
            continue
        }
        guard let colon = statement.text.lastIndex(of: ":") else {
            throw MermaidError.parse(line: statement.line, message: "Invalid pie slice: \(statement.text)")
        }
        let label = try visualizationLabel(String(statement.text[..<colon]), line: statement.line)
        let value = try finiteVisualizationNumber(
            String(statement.text[statement.text.index(after: colon)...]),
            line: statement.line,
            description: "pie value"
        )
        guard value >= 0 else {
            throw MermaidError.parse(line: statement.line, message: "Pie values cannot be negative")
        }
        guard seen.insert(label).inserted else {
            throw MermaidError.parse(line: statement.line, message: "Duplicate pie slice: \(label)")
        }
        try requireVisualizationCapacity(slices.count, maximum: MermaidVisualizationLimits.maximumNodes, line: statement.line, noun: "slice")
        slices.append(MermaidPieSlice(label: label, value: value))
    }
    let total = slices.reduce(0) { $0 + $1.value }
    guard !slices.isEmpty, total.isFinite, total > 0 else {
        throw MermaidError.parse(line: 1, message: "Pie diagram requires a positive total")
    }
    let root = FlowchartNode(id: "__pie_total", label: title ?? "Pie chart", shape: .circle)
    var graph: [FlowchartStatement] = [.node(root)]
    for (index, slice) in slices.enumerated() {
        let id = "__pie_slice_\(index)"
        graph.append(.node(FlowchartNode(id: id, label: "\(slice.label): \(visualizationNumber(slice.value))", shape: .roundedRectangle)))
        graph.append(.edge(FlowchartEdge(from: root.id, to: id, label: visualizationNumber(slice.value), style: .line)))
    }
    return MermaidVisualizationResult(
        kind: .pie,
        graph: FlowchartGraph(direction: .leftToRight, statements: graph),
        diagram: .pie(MermaidPieChart(title: title, showData: showData, slices: slices))
    )
}

func parseMindmapVisualization(
    statements: [MermaidVisualizationStatement]
) throws -> MermaidVisualizationResult {
    var nodes: [MermaidMindmapNode] = []
    var stack: [(indentation: Int, id: String, depth: Int)] = []
    for statement in statements {
        if statement.text.hasPrefix("::") { continue }
        try requireVisualizationCapacity(nodes.count, maximum: MermaidVisualizationLimits.maximumNodes, line: statement.line, noun: "node")
        while let last = stack.last, last.indentation >= statement.indentation {
            stack.removeLast()
        }
        if !nodes.isEmpty, stack.isEmpty {
            throw MermaidError.parse(line: statement.line, message: "Mindmap cannot contain multiple roots")
        }
        let (label, shape) = try parseMindmapNode(statement.text, line: statement.line, isRoot: nodes.isEmpty)
        let id = "__mindmap_\(nodes.count)"
        let depth = stack.last.map { $0.depth + 1 } ?? 0
        nodes.append(MermaidMindmapNode(id: id, label: label, shape: shape, parentID: stack.last?.id, depth: depth))
        stack.append((statement.indentation, id, depth))
    }
    guard !nodes.isEmpty else {
        throw MermaidError.parse(line: 1, message: "Mindmap requires at least one node")
    }
    var graph: [FlowchartStatement] = []
    for node in nodes {
        graph.append(.node(FlowchartNode(id: node.id, label: node.label, shape: node.shape)))
        if let parent = node.parentID {
            graph.append(.edge(FlowchartEdge(from: parent, to: node.id, style: .line)))
        }
    }
    return MermaidVisualizationResult(
        kind: .mindmap,
        graph: FlowchartGraph(direction: .leftToRight, statements: graph),
        diagram: .mindmap(MermaidMindmapDiagram(nodes: nodes))
    )
}

private func parseMindmapNode(_ value: String, line: Int, isRoot: Bool) throws -> (String, NodeShape) {
    for (opening, closing, shape): (String, String, NodeShape) in [
        ("((", "))", .circle),
        ("{{", "}}", .hexagon),
        ("))", "((", .stadium),
        ("[", "]", .rectangle),
        ("(", ")", .roundedRectangle),
    ] {
        if let range = value.range(of: opening), value.hasSuffix(closing) {
            let end = value.index(value.endIndex, offsetBy: -closing.count)
            guard range.upperBound < end else {
                throw MermaidError.parse(line: line, message: "Empty mindmap node")
            }
            return (try visualizationLabel(String(value[range.upperBound..<end]), line: line), shape)
        }
    }
    return (try visualizationLabel(value, line: line), isRoot ? .circle : .roundedRectangle)
}

func parseTimelineVisualization(
    statements: [MermaidVisualizationStatement]
) throws -> MermaidVisualizationResult {
    var title: String?
    var currentSection: String?
    var events: [MermaidTimelineEvent] = []
    for statement in statements {
        let value = statement.text
        if value.hasPrefix("#") { continue }
        if value.hasPrefix("title ") {
            title = try visualizationLabel(String(value.dropFirst(6)), line: statement.line)
        } else if value.hasPrefix("section ") {
            currentSection = try visualizationLabel(String(value.dropFirst(8)), line: statement.line)
        } else if value.hasPrefix(":") {
            guard !events.isEmpty else {
                throw MermaidError.parse(line: statement.line, message: "Timeline event has no period")
            }
            let event = try visualizationLabel(String(value.dropFirst()), line: statement.line)
            events[events.count - 1].events.append(event)
        } else {
            let pieces = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let period = try visualizationLabel(String(pieces[0]), line: statement.line)
            let description = pieces.count == 2 ? String(pieces[1]).trimmingCharacters(in: .whitespaces) : ""
            try requireVisualizationCapacity(events.count, maximum: MermaidVisualizationLimits.maximumNodes, line: statement.line, noun: "period")
            events.append(
                MermaidTimelineEvent(
                    period: period,
                    events: description.isEmpty ? [] : [try visualizationLabel(description, line: statement.line)],
                    section: currentSection
                )
            )
        }
    }
    guard !events.isEmpty else {
        throw MermaidError.parse(line: 1, message: "Timeline requires at least one period")
    }
    var graph: [FlowchartStatement] = []
    for (index, event) in events.enumerated() {
        let id = "__timeline_\(index)"
        var labels: [String] = []
        if index == 0, let title { labels.append(title) }
        if let section = event.section { labels.append(section) }
        labels.append(event.period)
        labels.append(contentsOf: event.events)
        graph.append(.node(FlowchartNode(id: id, label: labels.joined(separator: "\n"), shape: .rectangle)))
        if index > 0 {
            graph.append(.edge(FlowchartEdge(from: "__timeline_\(index - 1)", to: id, style: .arrow)))
        }
    }
    return MermaidVisualizationResult(
        kind: .timeline,
        graph: FlowchartGraph(direction: .leftToRight, statements: graph),
        diagram: .timeline(MermaidTimelineDiagram(title: title, events: events))
    )
}

func parseJourneyVisualization(
    statements: [MermaidVisualizationStatement]
) throws -> MermaidVisualizationResult {
    var title: String?
    var section: String?
    var tasks: [MermaidJourneyTask] = []
    for statement in statements {
        let value = statement.text
        if value.hasPrefix("title ") {
            title = try visualizationLabel(String(value.dropFirst(6)), line: statement.line)
            continue
        }
        if value.hasPrefix("section ") {
            section = try visualizationLabel(String(value.dropFirst(8)), line: statement.line)
            continue
        }
        let parts = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let score = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              (1...5).contains(score) else {
            throw MermaidError.parse(line: statement.line, message: "Invalid journey task or score: \(value)")
        }
        let name = try visualizationLabel(String(parts[0]), line: statement.line)
        let actors: [String]
        if parts.count == 3 {
            actors = try parts[2].split(separator: ",").map {
                try visualizationLabel(String($0), line: statement.line)
            }
        } else {
            actors = []
        }
        try requireVisualizationCapacity(tasks.count, maximum: MermaidVisualizationLimits.maximumNodes, line: statement.line, noun: "task")
        tasks.append(MermaidJourneyTask(title: name, score: score, actors: actors, section: section))
    }
    guard !tasks.isEmpty else {
        throw MermaidError.parse(line: 1, message: "Journey requires at least one task")
    }
    var graph: [FlowchartStatement] = []
    for (index, task) in tasks.enumerated() {
        var rows: [String] = []
        if index == 0, let title { rows.append(title) }
        rows.append(contentsOf: [task.section, task.title, "Score: \(task.score)/5"].compactMap { $0 })
        if !task.actors.isEmpty { rows.append(task.actors.joined(separator: ", ")) }
        let id = "__journey_\(index)"
        graph.append(.node(FlowchartNode(id: id, label: rows.joined(separator: "\n"), shape: .roundedRectangle)))
        if index > 0 {
            graph.append(.edge(FlowchartEdge(from: "__journey_\(index - 1)", to: id, style: .arrow)))
        }
    }
    return MermaidVisualizationResult(
        kind: .journey,
        graph: FlowchartGraph(direction: .leftToRight, statements: graph),
        diagram: .journey(MermaidJourneyDiagram(title: title, tasks: tasks))
    )
}

func parseGanttVisualization(
    statements: [MermaidVisualizationStatement]
) throws -> MermaidVisualizationResult {
    var title: String?
    var section: String?
    var tasks: [MermaidGanttTask] = []
    var tasksByID: [String: MermaidGanttTask] = [:]
    for statement in statements {
        let value = statement.text
        if value.hasPrefix("title ") {
            title = try visualizationLabel(String(value.dropFirst(6)), line: statement.line)
            continue
        }
        if value.hasPrefix("dateFormat ") || value.hasPrefix("axisFormat ") || value.hasPrefix("excludes ") {
            continue
        }
        if value.hasPrefix("section ") {
            section = try visualizationLabel(String(value.dropFirst(8)), line: statement.line)
            continue
        }
        guard let colon = value.firstIndex(of: ":") else {
            throw MermaidError.parse(line: statement.line, message: "Invalid gantt task: \(value)")
        }
        let name = try visualizationLabel(String(value[..<colon]), line: statement.line)
        var specs = value[value.index(after: colon)...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        while let first = specs.first, ["done", "active", "crit", "milestone"].contains(first) {
            specs.removeFirst()
        }
        guard specs.count == 3 else {
            throw MermaidError.parse(line: statement.line, message: "Invalid gantt task spec: \(value)")
        }
        let id = try visualizationLabel(specs[0], line: statement.line)
        guard tasksByID[id] == nil else {
            throw MermaidError.parse(line: statement.line, message: "Duplicate gantt task id: \(id)")
        }
        let duration = try parseGanttDuration(specs[2], line: statement.line)
        let dependency: String?
        let startDay: Int
        if specs[1].hasPrefix("after ") {
            dependency = String(specs[1].dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard let previous = dependency.flatMap({ tasksByID[$0] }) else {
                throw MermaidError.parse(line: statement.line, message: "Unknown gantt dependency: \(dependency ?? "")")
            }
            startDay = previous.startDay + previous.durationDays
        } else {
            dependency = nil
            startDay = try parseGanttDate(specs[1], line: statement.line)
        }
        try requireVisualizationCapacity(tasks.count, maximum: MermaidVisualizationLimits.maximumNodes, line: statement.line, noun: "task")
        let task = MermaidGanttTask(id: id, title: name, section: section, startDay: startDay, durationDays: duration, dependencyID: dependency)
        tasks.append(task)
        tasksByID[id] = task
    }
    guard !tasks.isEmpty else {
        throw MermaidError.parse(line: 1, message: "Gantt diagram requires at least one task")
    }
    let minimumDay = tasks.map(\.startDay).min() ?? 0
    let maximumDay = tasks.map { $0.startDay + $0.durationDays }.max() ?? minimumDay
    guard maximumDay - minimumDay <= 36_500 else {
        throw MermaidError.parse(line: 1, message: "Gantt diagram exceeds the maximum supported date range")
    }
    var graph: [FlowchartStatement] = []
    for task in tasks {
        let label = [task.section, task.title, "\(task.durationDays)d"].compactMap { $0 }.joined(separator: "\n")
        graph.append(.node(FlowchartNode(id: task.id, label: label, shape: .roundedRectangle)))
        if let dependency = task.dependencyID {
            graph.append(.edge(FlowchartEdge(from: dependency, to: task.id, label: "after", style: .arrow)))
        }
    }
    return MermaidVisualizationResult(
        kind: .gantt,
        graph: FlowchartGraph(direction: .leftToRight, statements: graph),
        diagram: .gantt(MermaidGanttDiagram(title: title, tasks: tasks))
    )
}

private func parseGanttDuration(_ value: String, line: Int) throws -> Int {
    guard let unit = value.last,
          let amount = Int(value.dropLast()), (1...36_500).contains(amount) else {
        throw MermaidError.parse(line: line, message: "Invalid gantt duration: \(value)")
    }
    switch unit.lowercased() {
    case "d": return amount
    case "w":
        let (days, overflow) = amount.multipliedReportingOverflow(by: 7)
        guard !overflow else {
            throw MermaidError.parse(line: line, message: "Gantt duration exceeds the supported range")
        }
        return days
    default:
        throw MermaidError.parse(line: line, message: "Unsupported gantt duration: \(value)")
    }
}

private func parseGanttDate(_ value: String, line: Int) throws -> Int {
    let pieces = value.split(separator: "-").compactMap { Int($0) }
    guard pieces.count == 3, (1...9999).contains(pieces[0]), (1...12).contains(pieces[1]), (1...31).contains(pieces[2]) else {
        throw MermaidError.parse(line: line, message: "Invalid gantt date: \(value)")
    }
    var calendar = Calendar(identifier: .gregorian)
    if let timeZone = TimeZone(secondsFromGMT: 0) {
        calendar.timeZone = timeZone
    }
    let components = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
    guard let date = calendar.date(from: components),
          calendar.component(.year, from: date) == pieces[0],
          calendar.component(.month, from: date) == pieces[1],
          calendar.component(.day, from: date) == pieces[2] else {
        throw MermaidError.parse(line: line, message: "Invalid gantt date: \(value)")
    }
    return Int(date.timeIntervalSince1970 / 86_400)
}

func parseGitGraphVisualization(
    statements: [MermaidVisualizationStatement]
) throws -> MermaidVisualizationResult {
    var branches = ["main"]
    var heads: [String: String] = [:]
    var current = "main"
    var commits: [MermaidGitCommit] = []
    var seenIDs: Set<String> = []
    for statement in statements {
        let parts = statement.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let command = parts.first else { continue }
        switch command {
        case "branch":
            guard parts.count == 2 else {
                throw MermaidError.parse(line: statement.line, message: "Expected git branch name")
            }
            let name = try visualizationLabel(parts[1], line: statement.line)
            guard !branches.contains(name) else {
                throw MermaidError.parse(line: statement.line, message: "Duplicate git branch: \(name)")
            }
            branches.append(name)
            heads[name] = heads[current]
        case "checkout", "switch":
            guard parts.count == 2, branches.contains(parts[1]) else {
                throw MermaidError.parse(line: statement.line, message: "Unknown git branch")
            }
            current = parts[1]
        case "commit":
            var id = "commit_\(commits.count)"
            var tag: String?
            let arguments = String(statement.text.dropFirst(command.count)).trimmingCharacters(in: .whitespaces)
            if let explicitID = gitGraphArgument("id", in: arguments) { id = try visualizationLabel(explicitID, line: statement.line) }
            if let explicitTag = gitGraphArgument("tag", in: arguments) { tag = try visualizationLabel(explicitTag, line: statement.line) }
            guard seenIDs.insert(id).inserted else {
                throw MermaidError.parse(line: statement.line, message: "Duplicate git commit id: \(id)")
            }
            try requireVisualizationCapacity(commits.count, maximum: MermaidVisualizationLimits.maximumNodes, line: statement.line, noun: "commit")
            let commit = MermaidGitCommit(id: id, branch: current, parentIDs: heads[current].map { [$0] } ?? [], isMerge: false, tag: tag)
            commits.append(commit)
            heads[current] = id
        case "merge":
            guard parts.count >= 2, branches.contains(parts[1]), let merged = heads[parts[1]] else {
                throw MermaidError.parse(line: statement.line, message: "Unknown or empty git merge branch")
            }
            let id = "merge_\(commits.count)"
            let parents = [heads[current], merged].compactMap { $0 }
            try requireVisualizationCapacity(commits.count, maximum: MermaidVisualizationLimits.maximumNodes, line: statement.line, noun: "commit")
            commits.append(MermaidGitCommit(id: id, branch: current, parentIDs: parents, isMerge: true, tag: nil))
            heads[current] = id
        default:
            throw MermaidError.parse(line: statement.line, message: "Unrecognized gitGraph command: \(command)")
        }
    }
    guard !commits.isEmpty else {
        throw MermaidError.parse(line: 1, message: "gitGraph requires at least one commit")
    }
    var graph: [FlowchartStatement] = []
    for commit in commits {
        let title = [commit.branch, commit.tag ?? commit.id].joined(separator: "\n")
        graph.append(.node(FlowchartNode(id: commit.id, label: title, shape: commit.isMerge ? .diamond : .circle)))
        for parent in commit.parentIDs {
            graph.append(.edge(FlowchartEdge(from: parent, to: commit.id, style: .line)))
        }
    }
    return MermaidVisualizationResult(
        kind: .gitGraph,
        graph: FlowchartGraph(direction: .leftToRight, statements: graph),
        diagram: .gitGraph(MermaidGitGraphDiagram(branches: branches, commits: commits))
    )
}

private func gitGraphArgument(_ key: String, in value: String) -> String? {
    guard let range = value.range(of: "\(key):") else { return nil }
    let remainder = value[range.upperBound...].trimmingCharacters(in: .whitespaces)
    guard !remainder.isEmpty else { return nil }
    if remainder.hasPrefix("\"") {
        let body = remainder.dropFirst()
        guard let end = body.firstIndex(of: "\"") else { return nil }
        return String(body[..<end])
    }
    return remainder.split(whereSeparator: \.isWhitespace).first.map(String.init)
}

func parseKanbanVisualization(
    statements: [MermaidVisualizationStatement]
) throws -> MermaidVisualizationResult {
    var columns: [MermaidKanbanColumn] = []
    var titles: Set<String> = []
    for statement in statements {
        if statement.indentation == 0 {
            let title = try visualizationLabel(statement.text, line: statement.line)
            guard titles.insert(title).inserted else {
                throw MermaidError.parse(line: statement.line, message: "Duplicate kanban column: \(title)")
            }
            try requireVisualizationCapacity(columns.count, maximum: MermaidVisualizationLimits.maximumNodes, line: statement.line, noun: "column")
            columns.append(MermaidKanbanColumn(title: title, tasks: []))
            continue
        }
        guard !columns.isEmpty else {
            throw MermaidError.parse(line: statement.line, message: "Task found before any kanban column")
        }
        let task = try parseKanbanTask(statement.text, line: statement.line)
        let totalTasks = columns.reduce(0) { $0 + $1.tasks.count }
        try requireVisualizationCapacity(totalTasks, maximum: MermaidVisualizationLimits.maximumNodes, line: statement.line, noun: "task")
        columns[columns.count - 1].tasks.append(task)
    }
    guard !columns.isEmpty, columns.contains(where: { !$0.tasks.isEmpty }) else {
        throw MermaidError.parse(line: 1, message: "Kanban requires a column containing at least one task")
    }
    var statements: [FlowchartStatement] = []
    for (columnIndex, column) in columns.enumerated() {
        var children: [FlowchartStatement] = []
        for (taskIndex, task) in column.tasks.enumerated() {
            let id = "__kanban_\(columnIndex)_\(taskIndex)"
            let rows = [task.label, task.assigned.map { "@\($0)" }, task.priority, task.ticket]
                .compactMap { $0 }
                .joined(separator: "\n")
            children.append(.node(FlowchartNode(id: id, label: rows, shape: .roundedRectangle)))
            if taskIndex > 0 {
                children.append(.edge(FlowchartEdge(from: "__kanban_\(columnIndex)_\(taskIndex - 1)", to: id, style: .dottedLine)))
            }
        }
        statements.append(
            .subgraph(FlowchartSubgraph(id: "__kanban_column_\(columnIndex)", title: column.title, statements: children))
        )
    }
    return MermaidVisualizationResult(
        kind: .kanban,
        graph: FlowchartGraph(direction: .topToBottom, statements: statements),
        diagram: .kanban(MermaidKanbanDiagram(columns: columns))
    )
}

private func parseKanbanTask(_ value: String, line: Int) throws -> MermaidKanbanTask {
    guard let marker = value.range(of: "@{") else {
        return MermaidKanbanTask(label: try visualizationLabel(value, line: line), assigned: nil, priority: nil, ticket: nil)
    }
    guard value.hasSuffix("}") else {
        throw MermaidError.parse(line: line, message: "Unterminated kanban task metadata")
    }
    var label = try visualizationLabel(String(value[..<marker.lowerBound]), line: line)
    let metadata = value[marker.upperBound..<value.index(before: value.endIndex)]
    var entries: [String: String] = [:]
    for entry in splitVisualizationCSV(String(metadata)) {
        guard let colon = entry.firstIndex(of: ":") else {
            throw MermaidError.parse(line: line, message: "Invalid kanban task metadata: \(entry)")
        }
        let key = entry[..<colon].trimmingCharacters(in: .whitespaces)
        let value = try visualizationLabel(String(entry[entry.index(after: colon)...]), line: line)
        entries[key] = value
    }
    if let explicitLabel = entries["label"] { label = explicitLabel }
    return MermaidKanbanTask(label: label, assigned: entries["assigned"], priority: entries["priority"], ticket: entries["ticket"])
}

func parseQuadrantVisualization(
    statements: [MermaidVisualizationStatement]
) throws -> MermaidVisualizationResult {
    var chart = MermaidQuadrantChart(title: nil, xAxis: nil, yAxis: nil, quadrantLabels: [:], points: [])
    var seen: Set<String> = []
    for statement in statements {
        let value = statement.text
        if value.hasPrefix("title ") {
            chart.title = try visualizationLabel(String(value.dropFirst(6)), line: statement.line)
            continue
        }
        if value.hasPrefix("x-axis ") {
            chart.xAxis = try parseQuadrantAxis(String(value.dropFirst(7)), line: statement.line)
            continue
        }
        if value.hasPrefix("y-axis ") {
            chart.yAxis = try parseQuadrantAxis(String(value.dropFirst(7)), line: statement.line)
            continue
        }
        if value.hasPrefix("quadrant-") {
            let parts = value.dropFirst(9).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let index = Int(parts[0]), (1...4).contains(index), chart.quadrantLabels[index] == nil else {
                throw MermaidError.parse(line: statement.line, message: "Invalid or duplicate quadrant label: \(value)")
            }
            chart.quadrantLabels[index] = try visualizationLabel(String(parts[1]), line: statement.line)
            continue
        }
        guard let separator = value.firstIndex(of: ":") else {
            throw MermaidError.parse(line: statement.line, message: "Invalid quadrant point: \(value)")
        }
        let label = try visualizationLabel(String(value[..<separator]), line: statement.line)
        guard seen.insert(label).inserted else {
            throw MermaidError.parse(line: statement.line, message: "Duplicate quadrant point: \(label)")
        }
        let coordinates = try parseVisualizationNumbers(
            String(value[value.index(after: separator)...]),
            line: statement.line,
            noun: "quadrant coordinates"
        )
        guard coordinates.count == 2,
              (0...1).contains(coordinates[0]),
              (0...1).contains(coordinates[1]) else {
            throw MermaidError.parse(line: statement.line, message: "Quadrant points require two coordinates from 0 to 1")
        }
        try requireVisualizationCapacity(chart.points.count, maximum: MermaidVisualizationLimits.maximumNodes, line: statement.line, noun: "point")
        chart.points.append(MermaidQuadrantPoint(label: label, x: coordinates[0], y: coordinates[1]))
    }
    guard !chart.points.isEmpty else {
        throw MermaidError.parse(line: 1, message: "Quadrant chart requires at least one point")
    }
    let graph = chart.points.enumerated().map { index, point -> FlowchartStatement in
        .node(FlowchartNode(id: "__quadrant_\(index)", label: "\(point.label)\n(\(visualizationNumber(point.x)), \(visualizationNumber(point.y)))", shape: .circle))
    }
    return MermaidVisualizationResult(
        kind: .quadrantChart,
        graph: FlowchartGraph(direction: .leftToRight, statements: graph),
        diagram: .quadrantChart(chart)
    )
}

private func parseQuadrantAxis(_ value: String, line: Int) throws -> (low: String, high: String) {
    guard let arrow = value.range(of: "-->") else {
        throw MermaidError.parse(line: line, message: "Invalid quadrant axis: \(value)")
    }
    return (
        try visualizationLabel(String(value[..<arrow.lowerBound]), line: line),
        try visualizationLabel(String(value[arrow.upperBound...]), line: line)
    )
}

func parseVisualizationNumbers(_ value: String, line: Int, noun: String) throws -> [Double] {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
        throw MermaidError.parse(line: line, message: "Invalid \(noun): \(value)")
    }
    let values = trimmed.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
    guard !values.isEmpty else {
        throw MermaidError.parse(line: line, message: "Missing \(noun)")
    }
    return try values.map {
        try finiteVisualizationNumber(String($0), line: line, description: noun)
    }
}

func splitVisualizationCSV(_ value: String) -> [String] {
    var results: [String] = []
    var current = ""
    var quote: Character?
    for character in value {
        if character == "\"" || character == "'" {
            if quote == character {
                quote = nil
            } else if quote == nil {
                quote = character
            }
            current.append(character)
        } else if character == ",", quote == nil {
            results.append(current.trimmingCharacters(in: .whitespaces))
            current.removeAll(keepingCapacity: true)
        } else {
            current.append(character)
        }
    }
    results.append(current.trimmingCharacters(in: .whitespaces))
    return results
}

func visualizationNumber(_ value: Double) -> String {
    if value.rounded() == value, abs(value) < Double(Int.max) {
        return String(Int(value))
    }
    return String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
}
