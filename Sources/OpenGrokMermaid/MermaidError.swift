// MermaidError.swift
//
// Open Grok — Swift port of `mermaid_to_svg::error`
// (third_party/mermaid-to-svg/src/error.rs, W8-S2 / CRATE_MAP.md row 3).

/// Why a diagram could not be rendered.
///
/// Parse failures are values, never traps: the renderer is fed untrusted model
/// output, so every malformed input must come back as one of these cases.
public enum MermaidError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The source did not match the grammar. `line` is 1-based.
    case parse(line: Int, message: String)
    /// A `graph`/`flowchart` declaration named a direction other than
    /// TD/TB/BT/LR/RL.
    case invalidDirection(String)
    /// The leading token names a Mermaid diagram family this port does not
    /// implement. See `MermaidDiagramFamily.supported`.
    case unsupportedDiagramType(String)

    public var description: String {
        switch self {
        case let .parse(line, message):
            return "Parse error at line \(line): \(message)"
        case let .invalidDirection(direction):
            return "Invalid graph direction: \(direction)"
        case let .unsupportedDiagramType(type):
            return "Unsupported diagram type: \(type)"
        }
    }
}
