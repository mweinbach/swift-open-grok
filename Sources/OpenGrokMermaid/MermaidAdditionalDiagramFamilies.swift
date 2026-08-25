import Foundation

/// The information which ordinary flowchart nodes and edges cannot preserve.
public enum MermaidDiagramDetails: Equatable, Sendable {
    case classDiagram(MermaidClassDiagram)
    case entityRelationshipDiagram(MermaidEntityRelationshipDiagram)
    case sequenceDiagram(MermaidSequenceDiagram)
}

public enum MermaidClassRelationshipKind: Equatable, Sendable {
    case inheritance
    case realization
    case composition
    case aggregation
    case dependency
    case dashedDependency
    case association
    case dashedAssociation
}

public struct MermaidClass: Equatable, Sendable {
    public var id: String
    public var annotation: String?
    public var attributes: [String]
    public var methods: [String]
}

public struct MermaidClassRelationship: Equatable, Sendable {
    public var from: String
    public var to: String
    public var kind: MermaidClassRelationshipKind
    public var markerAtSource: Bool
    public var sourceCardinality: String?
    public var targetCardinality: String?
    public var label: String?
}

public struct MermaidClassDiagram: Equatable, Sendable {
    public var direction: GraphDirection
    public var classes: [MermaidClass]
    public var relationships: [MermaidClassRelationship]

    var flowchartGraph: FlowchartGraph {
        let nodes = classes.map { item -> FlowchartStatement in
            var rows: [String] = []
            if let annotation = item.annotation {
                rows.append("«\(annotation)»")
            }
            rows.append(displayMermaidGenerics(item.id))
            if !item.attributes.isEmpty || !item.methods.isEmpty {
                rows.append("────────")
                rows.append(contentsOf: item.attributes)
            }
            if !item.methods.isEmpty {
                rows.append("────────")
                rows.append(contentsOf: item.methods)
            }
            return .node(
                FlowchartNode(id: item.id, label: rows.joined(separator: "\n"), shape: .rectangle)
            )
        }
        let edges = relationships.map { relationship -> FlowchartStatement in
            let marker: String?
            let style: EdgeStyle
            switch relationship.kind {
            case .inheritance:
                marker = "△"
                style = .line
            case .realization:
                marker = "△"
                style = .dottedLine
            case .composition:
                marker = "◆"
                style = .line
            case .aggregation:
                marker = "◇"
                style = .line
            case .dependency:
                marker = nil
                style = .arrow
            case .dashedDependency:
                marker = nil
                style = .dottedArrow
            case .association:
                marker = nil
                style = .line
            case .dashedAssociation:
                marker = nil
                style = .dottedLine
            }
            var labelParts: [String] = []
            if relationship.markerAtSource, let marker { labelParts.append(marker) }
            if let cardinality = relationship.sourceCardinality { labelParts.append(cardinality) }
            if let label = relationship.label { labelParts.append(label) }
            if let cardinality = relationship.targetCardinality { labelParts.append(cardinality) }
            if !relationship.markerAtSource, let marker { labelParts.append(marker) }
            let label = labelParts.isEmpty ? nil : labelParts.joined(separator: " ")
            return .edge(
                FlowchartEdge(
                    from: relationship.from,
                    to: relationship.to,
                    label: label,
                    style: style
                )
            )
        }
        return FlowchartGraph(direction: direction, statements: nodes + edges)
    }
}

public enum MermaidEntityCardinality: String, Equatable, Sendable {
    case zeroOrOne = "0..1"
    case exactlyOne = "1"
    case zeroOrMore = "0..*"
    case oneOrMore = "1..*"
}

public struct MermaidEntityAttribute: Equatable, Sendable {
    public var type: String
    public var name: String
    public var key: String?
}

public struct MermaidEntity: Equatable, Sendable {
    public var id: String
    public var label: String
    public var attributes: [MermaidEntityAttribute]
    public var hasTruncatedAttributes: Bool
}

public struct MermaidEntityRelationship: Equatable, Sendable {
    public var from: String
    public var to: String
    public var sourceCardinality: MermaidEntityCardinality
    public var targetCardinality: MermaidEntityCardinality
    public var label: String?
    public var isIdentifying: Bool
}

public struct MermaidEntityRelationshipDiagram: Equatable, Sendable {
    public var entities: [MermaidEntity]
    public var relationships: [MermaidEntityRelationship]

    var flowchartGraph: FlowchartGraph {
        let nodes = entities.map { entity -> FlowchartStatement in
            var rows = [entity.label]
            if !entity.attributes.isEmpty || entity.hasTruncatedAttributes {
                rows.append("────────")
                rows.append(contentsOf: entity.attributes.map { attribute in
                    [attribute.type, attribute.name, attribute.key]
                        .compactMap { $0 }
                        .joined(separator: " ")
                })
                if entity.hasTruncatedAttributes { rows.append("…") }
            }
            return .node(
                FlowchartNode(id: entity.id, label: rows.joined(separator: "\n"), shape: .rectangle)
            )
        }
        let edges = relationships.map { relationship -> FlowchartStatement in
            let label = [
                relationship.sourceCardinality.rawValue,
                relationship.label,
                relationship.targetCardinality.rawValue,
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            return .edge(
                FlowchartEdge(
                    from: relationship.from,
                    to: relationship.to,
                    label: label,
                    style: relationship.isIdentifying ? .line : .dottedLine
                )
            )
        }
        return FlowchartGraph(direction: .topToBottom, statements: nodes + edges)
    }
}

public struct MermaidSequenceParticipant: Equatable, Sendable {
    public var id: String
    public var label: String
    public var isActor: Bool
}

public struct MermaidSequenceMessage: Equatable, Sendable {
    public var from: String
    public var to: String
    public var text: String?
    public var isDashed: Bool
    public var isCross: Bool
}

public enum MermaidSequenceNotePlacement: Equatable, Sendable {
    case over
    case left
    case right
}

public struct MermaidSequenceNote: Equatable, Sendable {
    public var participantIDs: [String]
    public var placement: MermaidSequenceNotePlacement
    public var text: String
}

public enum MermaidSequenceEvent: Equatable, Sendable {
    case message(MermaidSequenceMessage)
    case note(MermaidSequenceNote)
    case divider(String)
}

public struct MermaidSequenceDiagram: Equatable, Sendable {
    public var participants: [MermaidSequenceParticipant]
    public var events: [MermaidSequenceEvent]

    var flowchartGraph: FlowchartGraph {
        var statements = participants.map { participant -> FlowchartStatement in
            .node(
                FlowchartNode(
                    id: participant.id,
                    label: participant.label,
                    shape: .roundedRectangle
                )
            )
        }
        for event in events {
            guard case let .message(message) = event else { continue }
            let style: EdgeStyle = message.isCross
                ? (message.isDashed ? .dottedLine : .line)
                : (message.isDashed ? .dottedArrow : .arrow)
            let label = message.isCross
                ? [message.text, "×"].compactMap { $0 }.joined(separator: " ")
                : message.text
            statements.append(
                .edge(
                    FlowchartEdge(from: message.from, to: message.to, label: label, style: style)
                )
            )
        }
        return FlowchartGraph(direction: .leftToRight, statements: statements)
    }
}

private enum AdditionalDiagramLimits {
    static let sourceBytes = 1_048_576
    static let statements = 2_048
    static let nodes = 128
    static let edges = 512
    static let members = 8
}

private struct AdditionalDiagramStatement {
    var text: String
    var line: Int
}

private func additionalDiagramStatements(_ source: String) throws -> [AdditionalDiagramStatement] {
    guard source.utf8.count <= AdditionalDiagramLimits.sourceBytes else {
        throw MermaidError.parse(line: 1, message: "Diagram exceeds the maximum source size")
    }

    var statements: [AdditionalDiagramStatement] = []
    let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    for (offset, rawLine) in lines.enumerated() {
        var quoted = false
        var current = ""
        var iterator = rawLine.makeIterator()
        var previousWasPercent = false
        while let character = iterator.next() {
            if character == "\"" {
                quoted.toggle()
                previousWasPercent = false
                current.append(character)
                continue
            }
            if !quoted, character == "%" {
                if previousWasPercent {
                    current.removeLast()
                    break
                }
                previousWasPercent = true
                current.append(character)
                continue
            }
            previousWasPercent = false
            if !quoted, character == ";" {
                try appendAdditionalStatement(current, line: offset + 1, into: &statements)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
        }
        guard !quoted else {
            throw MermaidError.parse(line: offset + 1, message: "Unterminated quoted diagram text")
        }
        try appendAdditionalStatement(current, line: offset + 1, into: &statements)
    }
    return statements
}

private func appendAdditionalStatement(
    _ value: String,
    line: Int,
    into statements: inout [AdditionalDiagramStatement]
) throws {
    let text = value.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return }
    guard statements.count < AdditionalDiagramLimits.statements else {
        throw MermaidError.parse(line: line, message: "Diagram exceeds the maximum statement count")
    }
    statements.append(AdditionalDiagramStatement(text: text, line: line))
}

private func validAdditionalIdentifier(_ value: String) -> Bool {
    !value.isEmpty
        && value.utf8.count <= 512
        && !value.contains(where: { $0.isWhitespace || $0.isNewline })
}

private func displayMermaidGenerics(_ value: String) -> String {
    var result = ""
    var opened = false
    for character in value {
        if character == "~" {
            result.append(opened ? ">" : "<")
            opened.toggle()
        } else {
            result.append(character)
        }
    }
    return normalizeLabel(result)
}

/// Parses Mermaid classes, compartments, typed relationships and cardinality.
public func parseClassDiagram(_ source: String) throws -> MermaidClassDiagram {
    let statements = try additionalDiagramStatements(source)
    guard let header = statements.first,
          ["classDiagram", "classDiagram-v2"].contains(
            header.text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
          ) else {
        throw MermaidError.parse(line: 1, message: "Expected 'classDiagram' declaration")
    }

    var diagram = MermaidClassDiagram(direction: .topToBottom, classes: [], relationships: [])
    var indices: [String: Int] = [:]
    var activeClass: Int?

    func ensureClass(_ id: String, line: Int) throws -> Int {
        guard validAdditionalIdentifier(id) else {
            throw MermaidError.parse(line: line, message: "Invalid class identifier: \(id)")
        }
        if let index = indices[id] { return index }
        guard diagram.classes.count < AdditionalDiagramLimits.nodes else {
            throw MermaidError.parse(line: line, message: "Diagram exceeds the maximum node count")
        }
        let index = diagram.classes.count
        indices[id] = index
        diagram.classes.append(MermaidClass(id: id, annotation: nil, attributes: [], methods: []))
        return index
    }

    for statement in statements.dropFirst() {
        let text = statement.text
        if let index = activeClass {
            if text == "}" {
                activeClass = nil
            } else {
                appendClassMember(text, to: &diagram.classes[index])
            }
            continue
        }

        let keyword = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if keyword == "direction" {
            let direction = text.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
            guard let parsed = GraphDirection.parse(direction) else {
                throw MermaidError.invalidDirection(direction)
            }
            diagram.direction = parsed
            continue
        }
        if ["note", "callback", "click", "link", "style", "cssClass", "classDef", "namespace"]
            .contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) {
            continue
        }
        if keyword == "class" {
            var id = text.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
            let hasBlock = id.hasSuffix("{")
            if hasBlock { id = id.dropLast().trimmingCharacters(in: .whitespaces) }
            let index = try ensureClass(id, line: statement.line)
            if hasBlock { activeClass = index }
            continue
        }
        if text.hasPrefix("<<"), let close = text.range(of: ">>") {
            let annotation = text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let id = text[close.upperBound...].trimmingCharacters(in: .whitespaces)
            let index = try ensureClass(id, line: statement.line)
            diagram.classes[index].annotation = annotation
            continue
        }
        if let relationship = try parseClassRelationship(text, line: statement.line) {
            guard diagram.relationships.count < AdditionalDiagramLimits.edges else {
                throw MermaidError.parse(line: statement.line, message: "Diagram exceeds the maximum edge count")
            }
            _ = try ensureClass(relationship.from, line: statement.line)
            _ = try ensureClass(relationship.to, line: statement.line)
            diagram.relationships.append(relationship)
            continue
        }
        if let separator = text.firstIndex(of: ":") {
            let id = text[..<separator].trimmingCharacters(in: .whitespaces)
            let member = text[text.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !member.isEmpty else {
                throw MermaidError.parse(line: statement.line, message: "Expected class member")
            }
            let index = try ensureClass(id, line: statement.line)
            appendClassMember(member, to: &diagram.classes[index])
            continue
        }
        throw MermaidError.parse(line: statement.line, message: "Unrecognized classDiagram line: \(text)")
    }

    if activeClass != nil {
        throw MermaidError.parse(line: statements.last?.line ?? 1, message: "Unterminated class declaration")
    }
    guard !diagram.classes.isEmpty else {
        throw MermaidError.parse(line: header.line, message: "classDiagram contains no classes")
    }
    return diagram
}

private func appendClassMember(_ value: String, to item: inout MermaidClass) {
    if value.hasPrefix("<<"), value.hasSuffix(">>") {
        item.annotation = String(value.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
        return
    }
    let member = displayMermaidGenerics(value)
    if member.contains("(") {
        appendBoundedClassMember(member, to: &item.methods)
    } else {
        appendBoundedClassMember(member, to: &item.attributes)
    }
}

private func appendBoundedClassMember(_ member: String, to members: inout [String]) {
    if members.count < AdditionalDiagramLimits.members {
        members.append(member)
    } else if members.count == AdditionalDiagramLimits.members {
        members.append("…")
    }
}

private let classRelationshipOperators: [(String, MermaidClassRelationshipKind, Bool)] = [
    ("<|--", .inheritance, true),
    ("--|>", .inheritance, false),
    ("<|..", .realization, true),
    ("..|>", .realization, false),
    ("*--", .composition, true),
    ("--*", .composition, false),
    ("o--", .aggregation, true),
    ("--o", .aggregation, false),
    ("<--", .dependency, true),
    ("-->", .dependency, false),
    ("<..", .dashedDependency, true),
    ("..>", .dashedDependency, false),
    ("--", .association, false),
    ("..", .dashedAssociation, false),
]

private func parseClassRelationship(
    _ text: String,
    line: Int
) throws -> MermaidClassRelationship? {
    var quoted = false
    var cursor = text.startIndex
    while cursor < text.endIndex {
        let character = text[cursor]
        if character == "\"" {
            quoted.toggle()
            cursor = text.index(after: cursor)
            continue
        }
        if !quoted {
            for (token, kind, markerAtSource) in classRelationshipOperators
            where text[cursor...].hasPrefix(token) {
                if token.hasPrefix("o"), cursor > text.startIndex {
                    let previous = text[text.index(before: cursor)]
                    if previous.isLetter || previous.isNumber || previous == "_" { continue }
                }
                let end = text.index(cursor, offsetBy: token.count)
                if token.hasSuffix("o"), end < text.endIndex {
                    let next = text[end]
                    if next.isLetter || next.isNumber || next == "_" { continue }
                }
                let lhs = text[..<cursor].trimmingCharacters(in: .whitespaces)
                let rhs = text[end...].trimmingCharacters(in: .whitespaces)
                let (from, sourceCardinality) = stripCardinalitySuffix(lhs)
                let (targetAndLabel, targetCardinality) = stripCardinalityPrefix(rhs)
                let targetParts = targetAndLabel.split(separator: ":", maxSplits: 1)
                let to = targetParts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard validAdditionalIdentifier(from), validAdditionalIdentifier(to) else {
                    throw MermaidError.parse(line: line, message: "Invalid class relationship: \(text)")
                }
                let label = targetParts.count == 2
                    ? normalizeLabel(String(targetParts[1])).nilIfEmpty
                    : nil
                return MermaidClassRelationship(
                    from: from,
                    to: to,
                    kind: kind,
                    markerAtSource: markerAtSource,
                    sourceCardinality: sourceCardinality,
                    targetCardinality: targetCardinality,
                    label: label
                )
            }
        }
        cursor = text.index(after: cursor)
    }
    return nil
}

private func stripCardinalitySuffix(_ value: String) -> (String, String?) {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasSuffix("\"") else { return (trimmed, nil) }
    let content = trimmed.dropLast()
    guard let opening = content.lastIndex(of: "\"") else { return (trimmed, nil) }
    return (
        content[..<opening].trimmingCharacters(in: .whitespaces),
        String(content[content.index(after: opening)...])
    )
}

private func stripCardinalityPrefix(_ value: String) -> (String, String?) {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("\"") else { return (trimmed, nil) }
    let content = trimmed.dropFirst()
    guard let closing = content.firstIndex(of: "\"") else { return (trimmed, nil) }
    return (
        content[content.index(after: closing)...].trimmingCharacters(in: .whitespaces),
        String(content[..<closing])
    )
}

/// Parses Mermaid entities, fields, cardinalities and identifying relationships.
public func parseEntityRelationshipDiagram(_ source: String) throws -> MermaidEntityRelationshipDiagram {
    let statements = try additionalDiagramStatements(source)
    guard let header = statements.first,
          header.text.split(whereSeparator: \.isWhitespace).first == "erDiagram" else {
        throw MermaidError.parse(line: 1, message: "Expected 'erDiagram' declaration")
    }

    var diagram = MermaidEntityRelationshipDiagram(entities: [], relationships: [])
    var indices: [String: Int] = [:]
    var activeEntity: Int?

    func ensureEntity(_ token: String, line: Int) throws -> Int {
        let id: String
        let label: String
        if let opening = token.firstIndex(of: "[") {
            guard token.hasSuffix("]") else {
                throw MermaidError.parse(line: line, message: "Invalid entity declaration: \(token)")
            }
            id = String(token[..<opening])
            label = normalizeLabel(String(token[token.index(after: opening)..<token.index(before: token.endIndex)]))
        } else {
            id = token
            label = token
        }
        guard validAdditionalIdentifier(id), !label.isEmpty else {
            throw MermaidError.parse(line: line, message: "Invalid entity identifier: \(token)")
        }
        if let index = indices[id] {
            if label != id { diagram.entities[index].label = label }
            return index
        }
        guard diagram.entities.count < AdditionalDiagramLimits.nodes else {
            throw MermaidError.parse(line: line, message: "Diagram exceeds the maximum node count")
        }
        let index = diagram.entities.count
        indices[id] = index
        diagram.entities.append(
            MermaidEntity(id: id, label: label, attributes: [], hasTruncatedAttributes: false)
        )
        return index
    }

    for statement in statements.dropFirst() {
        let text = statement.text
        if let index = activeEntity {
            if text == "}" {
                activeEntity = nil
                continue
            }
            let tokens = splitOutsideQuotedText(text)
            guard tokens.count >= 2 else {
                throw MermaidError.parse(line: statement.line, message: "Invalid entity attribute: \(text)")
            }
            if diagram.entities[index].attributes.count < AdditionalDiagramLimits.members {
                let key = tokens.dropFirst(2).first { !$0.hasPrefix("\"") }
                diagram.entities[index].attributes.append(
                    MermaidEntityAttribute(
                        type: normalizeLabel(tokens[0]),
                        name: normalizeLabel(tokens[1]),
                        key: key.map(normalizeLabel)
                    )
                )
            } else {
                diagram.entities[index].hasTruncatedAttributes = true
            }
            continue
        }

        let parts = text.split(separator: ":", maxSplits: 1)
        let relation = parts.first.map(String.init) ?? ""
        let tokens = splitOutsideQuotedText(relation)
        if let operatorIndex = tokens.firstIndex(where: { parseEntityRelationshipOperator($0) != nil }) {
            guard tokens.count == 3, operatorIndex == 1,
                  let relationshipOperator = parseEntityRelationshipOperator(tokens[1]) else {
                throw MermaidError.parse(line: statement.line, message: "Invalid entity relationship: \(text)")
            }
            guard diagram.relationships.count < AdditionalDiagramLimits.edges else {
                throw MermaidError.parse(line: statement.line, message: "Diagram exceeds the maximum edge count")
            }
            let from = try ensureEntity(tokens[0], line: statement.line)
            let to = try ensureEntity(tokens[2], line: statement.line)
            let label = parts.count == 2 ? normalizeLabel(String(parts[1])).nilIfEmpty : nil
            diagram.relationships.append(
                MermaidEntityRelationship(
                    from: diagram.entities[from].id,
                    to: diagram.entities[to].id,
                    sourceCardinality: relationshipOperator.source,
                    targetCardinality: relationshipOperator.target,
                    label: label,
                    isIdentifying: relationshipOperator.identifying
                )
            )
            continue
        }

        var declaration = text
        let hasBlock = declaration.hasSuffix("{")
        if hasBlock { declaration = declaration.dropLast().trimmingCharacters(in: .whitespaces) }
        guard splitOutsideQuotedText(declaration).count == 1 else {
            throw MermaidError.parse(line: statement.line, message: "Unrecognized erDiagram line: \(text)")
        }
        let index = try ensureEntity(declaration, line: statement.line)
        if hasBlock { activeEntity = index }
    }

    if activeEntity != nil {
        throw MermaidError.parse(line: statements.last?.line ?? 1, message: "Unterminated entity declaration")
    }
    guard !diagram.entities.isEmpty else {
        throw MermaidError.parse(line: header.line, message: "erDiagram contains no entities")
    }
    return diagram
}

private func splitOutsideQuotedText(_ value: String) -> [String] {
    var values: [String] = []
    var current = ""
    var quoted = false
    for character in value {
        if character == "\"" { quoted.toggle() }
        if character.isWhitespace && !quoted {
            if !current.isEmpty { values.append(current) }
            current.removeAll(keepingCapacity: true)
        } else {
            current.append(character)
        }
    }
    if !current.isEmpty { values.append(current) }
    return values
}

private func parseEntityRelationshipOperator(
    _ value: String
) -> (source: MermaidEntityCardinality, target: MermaidEntityCardinality, identifying: Bool)? {
    let characters = Array(value)
    guard characters.count == 6 else { return nil }
    let source = String(characters[0...1])
    let line = String(characters[2...3])
    let target = String(characters[4...5])
    guard let sourceCardinality = parseEntityCardinality(source),
          let targetCardinality = parseEntityCardinality(target),
          line == "--" || line == ".." else {
        return nil
    }
    return (sourceCardinality, targetCardinality, line == "--")
}

private func parseEntityCardinality(_ value: String) -> MermaidEntityCardinality? {
    switch value {
    case "|o", "o|": return .zeroOrOne
    case "||": return .exactlyOne
    case "}o", "o{": return .zeroOrMore
    case "}|", "|{": return .oneOrMore
    default: return nil
    }
}

/// Parses message chronology, participants, aliases, notes and control blocks.
public func parseSequenceDiagram(_ source: String) throws -> MermaidSequenceDiagram {
    let statements = try additionalDiagramStatements(source)
    guard let header = statements.first,
          header.text.split(whereSeparator: \.isWhitespace).first == "sequenceDiagram" else {
        throw MermaidError.parse(line: 1, message: "Expected 'sequenceDiagram' declaration")
    }

    var diagram = MermaidSequenceDiagram(participants: [], events: [])
    var indices: [String: Int] = [:]
    var blocks: [Bool] = []
    var autonumber = false
    var messageNumber = 0

    func ensureParticipant(
        _ id: String,
        label: String? = nil,
        actor: Bool = false,
        line: Int
    ) throws {
        guard validAdditionalIdentifier(id) else {
            throw MermaidError.parse(line: line, message: "Invalid sequence participant: \(id)")
        }
        if let index = indices[id] {
            if let label { diagram.participants[index].label = label }
            if actor { diagram.participants[index].isActor = true }
            return
        }
        guard diagram.participants.count < AdditionalDiagramLimits.nodes else {
            throw MermaidError.parse(line: line, message: "Diagram exceeds the maximum participant count")
        }
        indices[id] = diagram.participants.count
        diagram.participants.append(
            MermaidSequenceParticipant(id: id, label: label ?? id, isActor: actor)
        )
    }

    func appendEvent(_ event: MermaidSequenceEvent, line: Int) throws {
        guard diagram.events.count < AdditionalDiagramLimits.edges else {
            throw MermaidError.parse(line: line, message: "Diagram exceeds the maximum event count")
        }
        diagram.events.append(event)
    }

    for statement in statements.dropFirst() {
        let text = statement.text
        let keyword = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        switch keyword.lowercased() {
        case "participant", "actor":
            let declaration = text.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
            let pieces = declaration.components(separatedBy: " as ")
            guard pieces.count <= 2, let id = pieces.first else {
                throw MermaidError.parse(line: statement.line, message: "Invalid sequence participant")
            }
            let label = pieces.count == 2 ? normalizeLabel(pieces[1]).nilIfEmpty : nil
            if pieces.count == 2, label == nil {
                throw MermaidError.parse(line: statement.line, message: "Expected participant alias")
            }
            try ensureParticipant(id, label: label, actor: keyword.lowercased() == "actor", line: statement.line)
        case "autonumber":
            autonumber = true
        case "activate", "deactivate", "create", "destroy", "title", "acctitle", "accdescr",
             "links", "link", "properties":
            continue
        case "note":
            let note = try parseSequenceNote(
                String(text.dropFirst(keyword.count)),
                line: statement.line
            )
            for id in note.participantIDs { try ensureParticipant(id, line: statement.line) }
            try appendEvent(.note(note), line: statement.line)
        case "loop", "alt", "opt", "par", "critical", "break":
            blocks.append(true)
            try appendEvent(.divider(normalizeLabel(text)), line: statement.line)
        case "else", "and", "option":
            if blocks.last == true {
                try appendEvent(.divider(normalizeLabel(text)), line: statement.line)
            }
        case "rect", "box":
            blocks.append(false)
        case "end":
            guard let visible = blocks.popLast() else {
                throw MermaidError.parse(line: statement.line, message: "Unexpected sequence block terminator")
            }
            if visible { try appendEvent(.divider("end"), line: statement.line) }
        default:
            var message = try parseSequenceMessage(text, line: statement.line)
            try ensureParticipant(message.from, line: statement.line)
            try ensureParticipant(message.to, line: statement.line)
            if autonumber {
                messageNumber += 1
                message.text = message.text.map { "\(messageNumber). \($0)" } ?? "\(messageNumber)."
            }
            try appendEvent(.message(message), line: statement.line)
        }
    }

    guard blocks.isEmpty else {
        throw MermaidError.parse(line: statements.last?.line ?? 1, message: "Unterminated sequence block")
    }
    guard !diagram.participants.isEmpty else {
        throw MermaidError.parse(line: header.line, message: "sequenceDiagram contains no participants")
    }
    return diagram
}

private func parseSequenceNote(_ value: String, line: Int) throws -> MermaidSequenceNote {
    let text = value.trimmingCharacters(in: .whitespaces)
    let lowercased = text.lowercased()
    let placement: MermaidSequenceNotePlacement
    let prefix: String
    if lowercased.hasPrefix("over ") {
        placement = .over
        prefix = "over "
    } else if lowercased.hasPrefix("left of ") {
        placement = .left
        prefix = "left of "
    } else if lowercased.hasPrefix("right of ") {
        placement = .right
        prefix = "right of "
    } else {
        throw MermaidError.parse(line: line, message: "Invalid sequence note: \(text)")
    }
    let remainder = String(text.dropFirst(prefix.count))
    guard let separator = remainder.firstIndex(of: ":") else {
        throw MermaidError.parse(line: line, message: "Expected sequence note text")
    }
    let participants = remainder[..<separator]
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard !participants.isEmpty,
          participants.allSatisfy(validAdditionalIdentifier),
          participants.count <= (placement == .over ? 2 : 1) else {
        throw MermaidError.parse(line: line, message: "Invalid sequence note participants")
    }
    let noteText = normalizeLabel(String(remainder[remainder.index(after: separator)...]))
    return MermaidSequenceNote(participantIDs: participants, placement: placement, text: noteText)
}

private let sequenceMessageOperators: [(String, Bool, Bool)] = [
    ("-->>", true, false),
    ("->>", false, false),
    ("--x", true, true),
    ("-x", false, true),
    ("--)", true, false),
    ("-)", false, false),
    ("-->", true, false),
    ("->", false, false),
]

private func parseSequenceMessage(_ text: String, line: Int) throws -> MermaidSequenceMessage {
    var cursor = text.startIndex
    while cursor < text.endIndex {
        for (token, dashed, cross) in sequenceMessageOperators where text[cursor...].hasPrefix(token) {
            let from = text[..<cursor].trimmingCharacters(in: .whitespaces)
            let end = text.index(cursor, offsetBy: token.count)
            var remaining = text[end...].trimmingCharacters(in: .whitespaces)
            if remaining.hasPrefix("+") || remaining.hasPrefix("-") {
                remaining = String(remaining.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            let pieces = remaining.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let to = pieces.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard validAdditionalIdentifier(from), validAdditionalIdentifier(to) else {
                throw MermaidError.parse(line: line, message: "Invalid sequence message: \(text)")
            }
            let message = pieces.count == 2 ? normalizeLabel(String(pieces[1])).nilIfEmpty : nil
            return MermaidSequenceMessage(from: from, to: to, text: message, isDashed: dashed, isCross: cross)
        }
        cursor = text.index(after: cursor)
    }
    throw MermaidError.parse(line: line, message: "Unrecognized sequenceDiagram line: \(text)")
}

func computeSequenceDiagramLayout(
    _ diagram: MermaidSequenceDiagram,
    config: RenderConfig
) -> MermaidLayoutResult {
    let fontSize = config.fontSizePixels() ?? MermaidTextWrap.defaultFontSize
    let characterWidth = MermaidTextWrap.scaleCharWidth(MermaidTextWrap.defaultCharWidth, fontSize: fontSize)
    let boxHeight = max(40, fontSize * 2.5)
    let margin = max(24, config.flowchart.padding.map(Double.init) ?? 24)
    let rowHeight = max(52, fontSize * 3.25)

    let boxWidths = diagram.participants.map {
        max(88, MermaidTextWrap.lineWidth($0.label, charWidth: characterWidth) + 32)
    }
    var gaps: [Double] = []
    if boxWidths.count > 1 {
        for index in 0..<(boxWidths.count - 1) {
            gaps.append(max(112, (boxWidths[index] + boxWidths[index + 1]) / 2 + 40))
        }
    }

    let participantIndices = Dictionary(
        uniqueKeysWithValues: diagram.participants.enumerated().map { ($0.element.id, $0.offset) }
    )
    var spacingRequirements: [(lower: Int, upper: Int, width: Double)] = []
    for event in diagram.events {
        switch event {
        case let .message(message):
            guard let from = participantIndices[message.from],
                  let to = participantIndices[message.to], from != to else { continue }
            let textWidth = MermaidTextWrap.lineWidth(message.text ?? "", charWidth: characterWidth)
            spacingRequirements.append((min(from, to), max(from, to), textWidth + 36))
        case let .note(note):
            guard note.placement == .over, note.participantIDs.count == 2,
                  let from = participantIndices[note.participantIDs[0]],
                  let to = participantIndices[note.participantIDs[1]], from != to else { continue }
            let textWidth = MermaidTextWrap.lineWidth(note.text, charWidth: characterWidth)
            spacingRequirements.append((min(from, to), max(from, to), textWidth + 24))
        case .divider:
            continue
        }
    }
    spacingRequirements.sort { ($0.upper - $0.lower) < ($1.upper - $1.lower) }
    for requirement in spacingRequirements {
        let existing = gaps[requirement.lower..<requirement.upper].reduce(0, +)
        if existing < requirement.width {
            gaps[requirement.upper - 1] += requirement.width - existing
        }
    }

    var centers: [Double] = [margin + (boxWidths.first ?? 88) / 2]
    for gap in gaps { centers.append((centers.last ?? margin) + gap) }
    let topCenter = margin + boxHeight / 2
    let firstEventY = topCenter + boxHeight / 2 + rowHeight
    let footerCenter = firstEventY + Double(diagram.events.count) * rowHeight + boxHeight / 2

    var nodes: [MermaidLayoutNode] = []
    var edges: [MermaidLayoutEdge] = []

    for (index, participant) in diagram.participants.enumerated() {
        let x = centers[index]
        let footerID = "__sequence_footer_\(participant.id)"
        nodes.append(
            MermaidLayoutNode(
                id: participant.id,
                x: x,
                y: topCenter,
                width: boxWidths[index],
                height: boxHeight,
                shape: .roundedRectangle,
                label: participant.label,
                fillColor: nil,
                strokeColor: nil
            )
        )
        nodes.append(
            MermaidLayoutNode(
                id: footerID,
                x: x,
                y: footerCenter,
                width: boxWidths[index],
                height: boxHeight,
                shape: .roundedRectangle,
                label: participant.label,
                fillColor: nil,
                strokeColor: nil
            )
        )
        edges.append(
            MermaidLayoutEdge(
                from: participant.id,
                to: footerID,
                label: nil,
                style: .dottedLine,
                points: [
                    MermaidPoint(x: x, y: topCenter + boxHeight / 2),
                    MermaidPoint(x: x, y: footerCenter - boxHeight / 2),
                ],
                labelPosition: nil
            )
        )
    }

    for (offset, event) in diagram.events.enumerated() {
        let y = firstEventY + Double(offset) * rowHeight
        switch event {
        case let .message(message):
            guard let from = participantIndices[message.from],
                  let to = participantIndices[message.to] else { continue }
            let sourceX = centers[from]
            let targetX = centers[to]
            let points: [MermaidPoint]
            if from == to {
                let loopWidth = max(46, MermaidTextWrap.lineWidth(message.text ?? "", charWidth: characterWidth) / 2 + 18)
                points = [
                    MermaidPoint(x: sourceX, y: y),
                    MermaidPoint(x: sourceX + loopWidth, y: y),
                    MermaidPoint(x: sourceX + loopWidth, y: y + rowHeight * 0.4),
                    MermaidPoint(x: sourceX, y: y + rowHeight * 0.4),
                ]
            } else {
                points = [MermaidPoint(x: sourceX, y: y), MermaidPoint(x: targetX, y: y)]
            }
            let style: EdgeStyle = message.isCross
                ? (message.isDashed ? .dottedLine : .line)
                : (message.isDashed ? .dottedArrow : .arrow)
            let label = message.isCross
                ? [message.text, "×"].compactMap { $0 }.joined(separator: " ")
                : message.text
            let labelX = from == to ? sourceX + (points[1].x - sourceX) / 2 : (sourceX + targetX) / 2
            edges.append(
                MermaidLayoutEdge(
                    from: message.from,
                    to: message.to,
                    label: label,
                    style: style,
                    points: points,
                    labelPosition: label.map { _ in MermaidPoint(x: labelX, y: y - fontSize * 0.8) }
                )
            )
        case let .note(note):
            guard let first = note.participantIDs.first,
                  let firstIndex = participantIndices[first] else { continue }
            let lastIndex = note.participantIDs.last.flatMap { participantIndices[$0] } ?? firstIndex
            let textWidth = MermaidTextWrap.lineWidth(note.text, charWidth: characterWidth)
            let width = max(textWidth + 28, abs(centers[lastIndex] - centers[firstIndex]) + 28, 80)
            let x: Double
            switch note.placement {
            case .over: x = (centers[firstIndex] + centers[lastIndex]) / 2
            case .left: x = centers[firstIndex] - width / 2 - 12
            case .right: x = centers[firstIndex] + width / 2 + 12
            }
            nodes.append(
                MermaidLayoutNode(
                    id: "__sequence_note_\(offset)",
                    x: x,
                    y: y,
                    width: width,
                    height: max(36, fontSize * 2.1),
                    shape: .roundedRectangle,
                    label: note.text,
                    fillColor: nil,
                    strokeColor: nil
                )
            )
        case let .divider(label):
            guard let first = centers.first, let last = centers.last,
                  let firstID = diagram.participants.first?.id,
                  let lastID = diagram.participants.last?.id else { continue }
            let left = min(first, last) - 18
            let right = max(first, last) + 18
            edges.append(
                MermaidLayoutEdge(
                    from: firstID,
                    to: lastID,
                    label: label,
                    style: .dottedLine,
                    points: [MermaidPoint(x: left, y: y), MermaidPoint(x: right, y: y)],
                    labelPosition: MermaidPoint(x: (left + right) / 2, y: y - fontSize * 0.7)
                )
            )
        }
    }

    let leftmostNode = nodes.map { $0.x - $0.width / 2 }.min() ?? margin
    let leftmostEdge = edges.flatMap(\.points).map(\.x).min() ?? margin
    let shift = max(0, margin - min(leftmostNode, leftmostEdge))
    if shift > 0 {
        for index in nodes.indices { nodes[index].x += shift }
        for index in edges.indices {
            for point in edges[index].points.indices { edges[index].points[point].x += shift }
            edges[index].labelPosition?.x += shift
        }
    }
    let rightmostNode = nodes.map { $0.x + $0.width / 2 }.max() ?? margin
    let rightmostEdge = edges.flatMap(\.points).map(\.x).max() ?? margin
    return MermaidLayoutResult(
        nodes: nodes,
        edges: edges,
        subgraphs: [],
        width: max(rightmostNode, rightmostEdge) + margin,
        height: footerCenter + boxHeight / 2 + margin
    )
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
