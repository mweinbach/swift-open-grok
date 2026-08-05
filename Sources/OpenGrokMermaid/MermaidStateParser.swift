// MermaidStateParser.swift
//
// Open Grok — Swift port of `mermaid_to_svg::state_diagram`
// (third_party/mermaid-to-svg/src/state_diagram.rs, W8-S2).
//
// State diagrams parse into the flowchart AST and reuse its layout and
// renderer; only the shapes and the text metrics differ.

import Foundation

/// Parses a `stateDiagram` / `stateDiagram-v2` source.
///
/// Supported: `state X`, the `<<choice>>` / `<<fork>>` / `<<join>>` stereotypes,
/// `A --> B`, `A --> B : label`, and `[*]` as start/end. Composite states,
/// notes, concurrency (`--`), and directions are not part of the upstream
/// grammar either and are reported as parse errors.
public func parseStateDiagram(_ input: String) throws -> FlowchartGraph {
    let lines = splitIntoLines(input)

    var index = 0
    var sawHeader = false
    while index < lines.count {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("%%") {
            index += 1
            continue
        }

        let token = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard token == "stateDiagram" || token == "stateDiagram-v2" else {
            throw MermaidError.parse(
                line: index + 1,
                message: "Expected 'stateDiagram' or 'stateDiagram-v2' declaration"
            )
        }
        sawHeader = true
        index += 1
        break
    }

    guard sawHeader else {
        throw MermaidError.parse(
            line: 1,
            message: "Expected 'stateDiagram' or 'stateDiagram-v2' declaration"
        )
    }

    var shapes: [String: NodeShape] = [:]
    var nodeOrder: [String] = []
    var edges: [(from: String, to: String, label: String?)] = []

    func ensureNode(_ id: String) {
        guard shapes[id] == nil else { return }
        nodeOrder.append(id)
        switch id {
        case "__start": shapes[id] = .startState
        case "__end": shapes[id] = .endState
        default: shapes[id] = .roundedRectangle
        }
    }

    while index < lines.count {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        let lineNumber = index + 1
        index += 1

        if line.isEmpty || line.hasPrefix("%%") { continue }

        if line.hasPrefix("state ") {
            let rest = String(line.dropFirst("state ".count)).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else {
                throw MermaidError.parse(line: lineNumber, message: "Expected state name after 'state'")
            }

            let name = rest.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let shape: NodeShape
            if rest.contains("<<choice>>") {
                shape = .diamond
            } else if rest.contains("<<fork>>") || rest.contains("<<join>>") {
                shape = .forkJoin
            } else {
                shape = .roundedRectangle
            }

            if shapes[name] == nil { nodeOrder.append(name) }
            shapes[name] = shape
            continue
        }

        if let arrow = line.range(of: "-->") {
            let fromRaw = String(line[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rhs = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)

            var toRaw = rhs
            var label: String?
            if let colon = rhs.firstIndex(of: ":") {
                toRaw = String(rhs[..<colon]).trimmingCharacters(in: .whitespaces)
                let text = String(rhs[rhs.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                label = text.isEmpty ? nil : text
            }

            let from = normalizeStateID(fromRaw, isSource: true)
            let to = normalizeStateID(toRaw, isSource: false)
            ensureNode(from)
            ensureNode(to)
            edges.append((from, to, label))
            continue
        }

        throw MermaidError.parse(
            line: lineNumber,
            message: "Unrecognized stateDiagram line: \(line)"
        )
    }

    var statements: [FlowchartStatement] = []
    for id in nodeOrder {
        guard let shape = shapes[id] else { continue }
        // The marker shapes carry no text.
        let label = shape.isStateShape ? nil : id
        statements.append(.node(FlowchartNode(id: id, label: label, shape: shape)))
    }
    for edge in edges {
        statements.append(
            .edge(FlowchartEdge(from: edge.from, to: edge.to, label: edge.label, style: .arrow))
        )
    }

    return FlowchartGraph(direction: .topToBottom, statements: statements)
}

/// `[*]` means the start marker on the left of an arrow and the end marker on
/// the right, so it maps to two distinct synthetic ids.
private func normalizeStateID(_ raw: String, isSource: Bool) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard trimmed == "[*]" else { return trimmed }
    return isSource ? "__start" : "__end"
}
