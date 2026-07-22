// OutputWire.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/output_wire.rs`.
//
// Wire-friendly tool-call output. Adjacent-tagged on `"kind"` with
// content in `"value"`.

import Foundation
import OpenGrokShared

/// Stable wire representation of a tool-call output.
///
/// Mirrors Rust `ToolOutputWire`. Wire form:
/// ```json
/// {"kind":"text","value":"..."}
/// {"kind":"json","value":{...}}
/// {"kind":"mcp","value":{"blocks":[...]}}
/// ```
public enum ToolOutputWire: Codable, Sendable, Hashable {
    /// Pre-formatted prompt text.
    case text(String)
    /// Opaque JSON escape hatch.
    case json(JSONValue)
    /// MCP-style structured blocks.
    case mcp(blocks: [McpBlock])

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum McpKeys: String, CodingKey {
        case blocks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "text":
            self = .text(try c.decode(String.self, forKey: .value))
        case "json":
            self = .json(try c.decode(JSONValue.self, forKey: .value))
        case "mcp":
            let nested = try c.nestedContainer(keyedBy: McpKeys.self, forKey: .value)
            self = .mcp(blocks: try nested.decode([McpBlock].self, forKey: .blocks))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown ToolOutputWire kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .kind)
            try c.encode(s, forKey: .value)
        case .json(let v):
            try c.encode("json", forKey: .kind)
            try c.encode(v, forKey: .value)
        case .mcp(let blocks):
            try c.encode("mcp", forKey: .kind)
            var nested = c.nestedContainer(keyedBy: McpKeys.self, forKey: .value)
            try nested.encode(blocks, forKey: .blocks)
        }
    }
}

/// One block in `ToolOutputWire.mcp`'s `blocks` list.
///
/// Internally tagged on `"type"` with snake_case discriminators.
public enum McpBlock: Codable, Sendable, Hashable {
    case text(text: String)
    case image(mimeType: String, data: String)
    case resource(uri: String, mimeType: String?, text: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case mimeType = "mime_type"
        case data
        case uri
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(text: try c.decode(String.self, forKey: .text))
        case "image":
            self = .image(
                mimeType: try c.decode(String.self, forKey: .mimeType),
                data: try c.decode(String.self, forKey: .data)
            )
        case "resource":
            self = .resource(
                uri: try c.decode(String.self, forKey: .uri),
                mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType),
                text: try c.decodeIfPresent(String.self, forKey: .text)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown McpBlock type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .image(let mimeType, let data):
            try c.encode("image", forKey: .type)
            try c.encode(mimeType, forKey: .mimeType)
            try c.encode(data, forKey: .data)
        case .resource(let uri, let mimeType, let text):
            try c.encode("resource", forKey: .type)
            try c.encode(uri, forKey: .uri)
            try c.encodeIfPresent(mimeType, forKey: .mimeType)
            try c.encodeIfPresent(text, forKey: .text)
        }
    }
}
