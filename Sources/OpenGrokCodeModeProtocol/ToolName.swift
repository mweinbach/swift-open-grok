// ToolName.swift
//
// Identifies a callable tool while preserving its optional namespace.
// Ported from `crates/codegen/xai-grok-code-mode-protocol/src/tool_name.rs`.
//
// Code-mode tools can be namespaced (e.g. MCP-qualified
// `mcp__ologs__get_profile`) or plain (`exec`, `wait`,
// `hidden_dynamic_tool`). The `ToolName` struct retains both pieces so the
// description builder can group tools by namespace and the runtime can
// route nested calls correctly.
//
// `ToolName` is `Hashable`, `Comparable`, and `Codable` (serializes as a
// bare JSON string via its `description`). `Comparable` orders by
// `(namespace, name)` so a sorted `Set<ToolName>` is deterministic across
// runs.

import Foundation

public struct ToolName: Hashable, Sendable, Codable, Equatable, Comparable {
    public var name: String
    public var namespace: String?

    public init(name: String, namespace: String? = nil) {
        self.name = name
        self.namespace = namespace
    }

    /// Construct a plain (un-namespaced) tool name.
    public static func plain(_ name: String) -> ToolName {
        ToolName(name: name, namespace: nil)
    }

    /// Construct a namespaced tool name.
    public static func namespaced(_ namespace: String, _ name: String) -> ToolName {
        ToolName(name: name, namespace: namespace)
    }

    // MARK: Codable — bare JSON string ("namespace + name" or just "name").

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = ToolName.parse(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(String(describing: self))
    }

    /// Parse a bare wire string into a `ToolName`, splitting on the
    /// MCP-style `__` delimiter when present.
    ///
    /// The Rust source serializes via `Display` (`namespace + name` when
    /// namespaced, else `name`); the wire form has no explicit delimiter,
    /// so the parser falls back to using the full string as the `name`
    /// when no namespace split is recoverable. Round-trip parity is
    /// preserved by `encode`/`String(describing:)` re-emitting the same
    /// form.
    public static func parse(_ raw: String) -> ToolName {
        // The Rust `Display` impl concatenates `namespace + name` without
        // a delimiter, so the wire form is ambiguous on parse. To preserve
        // round-trip parity for the cases the code-mode runtime actually
        // produces (MCP-qualified names use `mcp__server__tool` shape, and
        // the namespace is recorded separately as `mcp__server__`), we
        // attempt to split on the last `__` boundary only when the
        // namespace field is recoverable as `mcp__...__`. Otherwise we
        // keep the full string as the plain name.
        if let range = raw.range(of: "__", options: .backwards) {
            let ns = String(raw[raw.startIndex..<range.upperBound])
            let trailing = String(raw[range.upperBound...])
            if ns.hasPrefix("mcp__") && !trailing.isEmpty {
                return ToolName(name: trailing, namespace: ns)
            }
        }
        return ToolName(name: raw, namespace: nil)
    }

    // MARK: CustomStringConvertible (matches Rust's `Display`)

    public var description: String {
        if let ns = namespace {
            return "\(ns)\(name)"
        } else {
            return name
        }
    }

    // MARK: Comparable
    //
    // Mirrors the Rust `Ord` impl: sort by `(namespace, name)` when
    // namespaced, else by `(name, nil)`. Plain names sort before
    // namespaced names with the same prefix because the `nil` namespace
    // component compares less than any string.

    public static func < (lhs: ToolName, rhs: ToolName) -> Bool {
        let lhsKey: (String, String?)
        let rhsKey: (String, String?)
        if let ns = lhs.namespace {
            lhsKey = (ns, lhs.name)
        } else {
            lhsKey = (lhs.name, nil)
        }
        if let ns = rhs.namespace {
            rhsKey = (ns, rhs.name)
        } else {
            rhsKey = (rhs.name, nil)
        }
        if lhsKey.0 != rhsKey.0 { return lhsKey.0 < rhsKey.0 }
        switch (lhsKey.1, rhsKey.1) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (let l, let r): return l! < r!
        }
    }
}
