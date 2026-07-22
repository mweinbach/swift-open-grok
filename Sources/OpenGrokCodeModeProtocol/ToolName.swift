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
// Wire form is a JSON object `{ "name": "...", "namespace": "..." | null }`
// matching Rust's derive(Serialize, Deserialize) on the struct fields —
// not a flattened string. `Display` still concatenates `namespace + name`
// for human-readable / JS-identifier surfaces.

import Foundation

public struct ToolName: Hashable, Sendable, Codable, Equatable, Comparable, CustomStringConvertible {
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

    // MARK: Codable — keyed object matching Rust struct serde.

    enum CodingKeys: String, CodingKey {
        case name
        case namespace
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        // Option without `default`: absent key becomes nil only when the
        // key is present-as-null or we accept decodeIfPresent for
        // forward-compatible partial objects. Rust emits `null` for
        // `None`; accept both null and missing.
        namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        // Match Rust default Option encoding: always emit the key, with
        // `null` when namespace is absent.
        try c.encode(namespace, forKey: .namespace)
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
    // Mirrors the Rust `Ord` impl: sort by `(namespace, Some(name))` when
    // namespaced, else by `(name, None)`. Plain names sort before
    // namespaced names with the same prefix because the `None` name
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
        case let (l?, r?): return l < r
        }
    }
}
