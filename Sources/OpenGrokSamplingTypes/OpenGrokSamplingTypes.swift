// OpenGrokSamplingTypes.swift
//
// Open Grok — Swift port of `xai-grok-sampling-types`
// (crates/codegen/xai-grok-sampling-types). This is the public module entry
// point: it re-exports the public API surface from the per-topic files and
// hosts the few cross-file helpers (e.g. `hostedToolsForProvider`) that do
// not belong to any single file.
//
// The crate contains the API-agnostic conversation types, chat completion
// request/response types, streaming types, usage types, error types,
// provider/backend/dialect contracts, and the doom-loop wire contract used
// across the Open Grok sampling stack. It intentionally contains **no I/O**
// (no HTTP clients, no file system access) so it can be depended on by
// downstream crates (e.g. OpenGrokChatState) without pulling in the full
// sampler.

import Foundation
import OpenGrokShared

// MARK: - Re-exports
//
// Swift has no `pub use` so the per-file `public` types are already visible
// at the module boundary. This file documents the canonical surface and
// hosts the cross-file helpers.

/// Apply the first-party provider's hosted-tool contract before
/// serialization. A provider that does not accept hosted tools returns an
/// empty array.
public func hostedToolsForProvider(
    hostedTools: [HostedTool],
    provider: ModelProvider
) -> [HostedTool] {
    provider.profile.hostedTools(hostedTools)
}

extension ProviderProfile {
    /// Normalize hosted tools using this profile's provider-neutral dialect.
    public func hostedTools(_ tools: [HostedTool]) -> [HostedTool] {
        guard let dialect = hostedToolDialect else { return [] }
        return dialect.hostedTools(tools)
    }
}

extension HostedToolDialect {
    /// Normalize hosted tools for this wire dialect before serialization.
    ///
    /// In particular, `x_search` is never valid in the OpenAI schema. A
    /// missing web-search mode becomes live search, matching the pinned
    /// Codex hosted-tool setup.
    public func hostedTools(_ tools: [HostedTool]) -> [HostedTool] {
        switch self {
        case .xai:
            return tools
        case .openAi:
            return tools.compactMap { tool in
                switch tool {
                case .xSearch:
                    return nil
                case .webSearch(let mode, _, _, _, _) where mode == .disabled:
                    return nil
                case .webSearch(var mode, let allowedDomains, let userLocation,
                                let searchContextSize, let searchContentTypes):
                    if mode == nil { mode = .live }
                    return .webSearch(
                        mode: mode, allowedDomains: allowedDomains, userLocation: userLocation,
                        searchContextSize: searchContextSize, searchContentTypes: searchContentTypes
                    )
                case .clientCustom:
                    return tool
                }
            }
        }
    }
}

/// Construct a `CodexRawInputItem`-carrying `ConversationItem` from a raw
/// compact-output payload. Mirrors Rust `codex_compact_output_to_conversation_items`.
///
/// Returns the retained items or `nil` when the output contains no supported
/// replacement history.
public func codexCompactOutputToConversationItems(
    _ output: [JSONValue]
) -> [ConversationItem]? {
    var retained: [ConversationItem] = []
    for (index, raw) in output.enumerated() {
        guard case .object(let obj) = raw else { return nil }
        let itemType = obj["type"]?.stringValue
        guard let itemType, !itemType.isEmpty else { return nil }
        // Match codex-rs's post-endpoint retention boundary.
        let keep: Bool
        switch itemType {
        case "message":
            keep = obj["role"]?.stringValue == "user" || obj["role"]?.stringValue == "assistant"
        case "agent_message", "compaction", "context_compaction":
            keep = true
        default:
            keep = false
        }
        if !keep { continue }
        let providerId: String
        if let id = obj["id"]?.stringValue, !id.isEmpty {
            providerId = id
        } else {
            providerId = "codex_compact_\(index)_\(itemType)"
        }
        retained.append(.backendToolCall(BackendToolCallItem(
            kind: .codexRawInput(CodexRawInputItem(
                id: providerId, raw: raw, crossProviderFallback: nil
            ))
        )))
    }
    return retained.isEmpty ? nil : retained
}

// MARK: - JSONValue subscript helper used across this module

extension JSONValue {
    /// Subscript access into an object. Returns `nil` for non-objects or
    /// missing keys. Mirrors the `OpenGrokShared.JSONValue` subscript.
    /// (OpenGrokShared already provides this; this extension exists so the
    /// sampling-types module's subscript calls resolve without a qualified
    /// import at every call site.)
}


// MARK: - Chat-completions content-block helpers (mirror types.rs)

/// A chat-completions content block. Mirrors Rust `ChatContentBlock`.
public enum ChatContentBlock: Codable, Sendable, Equatable, Hashable {
    case text(text: String)
    case imageUrl(url: ImageUrl)

    public enum CodingKeys: String, CodingKey { case type, text, imageUrl }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(text: try c.decode(String.self, forKey: .text))
        case "image_url":
            self = .imageUrl(url: try c.decode(ImageUrl.self, forKey: .imageUrl))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown ChatContentBlock: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .imageUrl(let url):
            try c.encode("image_url", forKey: .type)
            try c.encode(url, forKey: .imageUrl)
        }
    }
}

public struct ImageUrl: Codable, Sendable, Equatable, Hashable {
    public var url: String
    public init(url: String) { self.url = url }
}

/// Chat-completions message content: either a plain string or an array of
/// content blocks. Mirrors Rust `MessageContent` (`#[serde(untagged)]`).
public enum MessageContent: Codable, Sendable, Equatable, Hashable {
    case text(String)
    case blocks([ChatContentBlock])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s)
        } else if let blocks = try? container.decode([ChatContentBlock].self) {
            self = .blocks(blocks)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "MessageContent: expected string or array")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .blocks(let blocks): try container.encode(blocks)
        }
    }

    public var isEmpty: Bool {
        switch self {
        case .text(let s): return s.isEmpty
        case .blocks(let b): return b.isEmpty
        }
    }

    public func blocks() -> [ChatContentBlock] {
        switch self {
        case .blocks(let b): return b
        case .text(let s): return [.text(text: s)]
        }
    }
}
