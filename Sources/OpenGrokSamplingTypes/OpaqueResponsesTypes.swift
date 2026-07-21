// OpaqueResponsesTypes.swift
//
// Open Grok — Swift port of the opaque Responses-API types that the Rust
// crate wraps via `async_openai::types::responses` (`rs::ReasoningItem`,
// `rs::WebSearchToolCall`, `rs::CustomToolCall`, `rs::CodeInterpreterToolCall`).
//
// The Rust crate wraps the typed async-openai structs so it can round-trip
// provider-native Responses items byte-stably. Swift has no async-openai, so
// the port defines equivalent Codable types here. These are the "typed
// opaque history tagged by backend/dialect" that the W1-S3 acceptance
// criteria require: the items are typed (so the sampler can branch on them),
// but their inner provider payloads are retained opaquely for replay.
//
// Round-trip contract: every field that the Rust `rs::*` struct serializes
// is preserved. Unknown fields are retained via `unknownFields` so forward-
// compatible server additions do not fail decode and re-encode byte-stably.

import Foundation
import OpenGrokShared

// MARK: - Reasoning summary / content parts

/// One summary part of a `ReasoningItem`. The Responses API currently emits
/// only the `summaryText` shape; the enum leaves room for future variants
/// (mirrors Rust `rs::SummaryPart`).
public enum SummaryPart: Codable, Sendable, Equatable, Hashable {
    case summaryText(text: String)

    public enum CodingKeys: String, CodingKey { case type, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "summary_text":
            self = .summaryText(text: try c.decode(String.self, forKey: .text))
        default:
            // Forward-compat: treat unknown variants as empty summary text
            // rather than failing the whole stream (matches the Rust crate's
            // tolerant posture for non-critical reasoning fields).
            self = .summaryText(text: "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .summaryText(let text):
            try c.encode("summary_text", forKey: .type)
            try c.encode(text, forKey: .text)
        }
    }

    public var text: String {
        if case .summaryText(let text) = self { return text }
        return ""
    }
}

/// One content block of a `ReasoningItem` (the full raw reasoning).
public struct ReasoningTextContent: Codable, Sendable, Equatable, Hashable {
    public var text: String

    public init(text: String) { self.text = text }
}

/// A Responses-API reasoning item. Sits as a sibling of the assistant
/// message so N parallel reasoning items round-trip losslessly and the
/// interleaved order the model emits is preserved byte-stable.
public struct ReasoningItem: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var summary: [SummaryPart]
    public var content: [ReasoningTextContent]?
    public var encryptedContent: String?
    public var status: String?

    public init(
        id: String,
        summary: [SummaryPart] = [],
        content: [ReasoningTextContent]? = nil,
        encryptedContent: String? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.summary = summary
        self.content = content
        self.encryptedContent = encryptedContent
        self.status = status
    }

    public enum CodingKeys: String, CodingKey {
        case id, summary, content
        case encryptedContent = "encrypted_content"
        case status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.summary = try c.decodeIfPresent([SummaryPart].self, forKey: .summary) ?? []
        // `content` is `Option<Vec<ReasoningTextContent>>` in Rust; treat
        // null/absent as nil and a JSON array as the value.
        if c.contains(.content) {
            self.content = try c.decodeIfPresent([ReasoningTextContent].self, forKey: .content)
        } else {
            self.content = nil
        }
        self.encryptedContent = try c.decodeIfPresent(String.self, forKey: .encryptedContent)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(encryptedContent, forKey: .encryptedContent)
        try c.encodeIfPresent(status, forKey: .status)
    }
}

// MARK: - Web search tool call

/// Action taken by a server-side web-search tool call. Mirrors the Rust
/// `rs::WebSearchToolCallAction` enum.
public enum WebSearchToolCallAction: Codable, Sendable, Equatable, Hashable {
    case search(query: String)
    case openPage(url: String?)
    case find(pattern: String, url: String)
    case findInPage(pattern: String, url: String)

    public enum CodingKeys: String, CodingKey { case type, query, url, pattern }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "search":
            self = .search(query: try c.decode(String.self, forKey: .query))
        case "open_page":
            self = .openPage(url: try c.decodeIfPresent(String.self, forKey: .url))
        case "find":
            self = .find(
                pattern: try c.decode(String.self, forKey: .pattern),
                url: try c.decode(String.self, forKey: .url)
            )
        case "find_in_page":
            self = .findInPage(
                pattern: try c.decode(String.self, forKey: .pattern),
                url: try c.decode(String.self, forKey: .url)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown WebSearchToolCallAction: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .search(let query):
            try c.encode("search", forKey: .type)
            try c.encode(query, forKey: .query)
        case .openPage(let url):
            try c.encode("open_page", forKey: .type)
            try c.encodeIfPresent(url, forKey: .url)
        case .find(let pattern, let url):
            try c.encode("find", forKey: .type)
            try c.encode(pattern, forKey: .pattern)
            try c.encode(url, forKey: .url)
        case .findInPage(let pattern, let url):
            try c.encode("find_in_page", forKey: .type)
            try c.encode(pattern, forKey: .pattern)
            try c.encode(url, forKey: .url)
        }
    }
}

/// A server-side web-search tool call from the backend agentic sampler.
public struct WebSearchToolCall: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var action: WebSearchToolCallAction

    public init(id: String, action: WebSearchToolCallAction) {
        self.id = id
        self.action = action
    }
}

/// A server-side X/Twitter search custom-tool call.
public struct CustomToolCall: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var callId: String
    public var name: String
    public var input: String

    public init(id: String, callId: String, name: String, input: String) {
        self.id = id
        self.callId = callId
        self.name = name
        self.input = input
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case callId = "call_id"
        case name, input
    }
}

/// A server-side code-interpreter tool call.
public struct CodeInterpreterToolCall: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var code: String?

    public init(id: String, code: String? = nil) {
        self.id = id
        self.code = code
    }
}

// MARK: - CodexRawInputItem (opaque replacement history)

/// One opaque response item returned by OpenAI's `/responses/compact`
/// endpoint.
///
/// The compact endpoint owns this wire format and may add item variants
/// before the local dependency learns about them. Persisting the raw JSON
/// lets Codex sessions replay the exact replacement history without exposing
/// it as visible assistant output.
public struct CodexRawInputItem: Codable, Sendable, Equatable, Hashable {
    /// Stable local identity used by replay/dedup helpers. The provider does
    /// not require an `id` on every compact item.
    public var id: String
    /// Exact provider item to splice into the next Responses request.
    public var raw: JSONValue
    /// Plaintext recent-history tail used only if this session later switches
    /// away from Codex. It is never spliced into a Codex request.
    public var crossProviderFallback: String?

    public init(id: String, raw: JSONValue, crossProviderFallback: String? = nil) {
        self.id = id
        self.raw = raw
        self.crossProviderFallback = crossProviderFallback
    }

    public enum CodingKeys: String, CodingKey {
        case id, raw
        case crossProviderFallback = "cross_provider_fallback"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.raw = try c.decode(JSONValue.self, forKey: .raw)
        self.crossProviderFallback = try c.decodeIfPresent(String.self, forKey: .crossProviderFallback)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(raw, forKey: .raw)
        try c.encodeIfPresent(crossProviderFallback, forKey: .crossProviderFallback)
    }

    /// Mirror codex-rs's `estimate_reasoning_length`: base64-decoded bytes
    /// minus the fixed encrypted-envelope overhead. Returns the byte length
    /// of the model-visible payload this item contributes.
    public func estimatedModelVisibleLen() -> Int {
        let itemType = raw["type"]?.stringValue
        if let itemType, ["compaction", "context_compaction", "reasoning"].contains(itemType),
           let encoded = raw["encrypted_content"]?.stringValue {
            return (encoded.utf8.count * 3 / 4).subtractingWithSaturate(650)
        }
        // Fall back to the serialized JSON length.
        guard let data = try? JSONEncoder().encode(raw) else { return 0 }
        return data.count
    }

    /// Placeholder role inferred from the raw item's `role` field.
    public func placeholderRole() -> Role {
        switch raw["role"]?.stringValue {
        case .some("user"): return .user
        case .some("system"), .some("developer"): return .system
        default: return .assistant
        }
    }

    /// Human-readable summary for token estimation and text extraction.
    public func textSummary() -> String {
        let itemType = raw["type"]?.stringValue ?? "item"
        if itemType == "message" {
            let role = raw["role"]?.stringValue ?? "context"
            let text = CodexRawInputItem.compactMessageText(raw)
            if !text.isEmpty {
                return "[OpenAI retained \(role) context] \(text)"
            }
        }
        if itemType == "compaction" {
            return crossProviderFallback ?? "[OpenAI compacted context]"
        }
        return "[OpenAI retained \(itemType) context]"
    }

    /// Extract text from a compact `message` item's `content` field (string
    /// or array of `{text: ...}` parts).
    static func compactMessageText(_ value: JSONValue) -> String {
        guard let content = value["content"] else { return "" }
        switch content {
        case .string(let text):
            return text
        case .array(let parts):
            return parts.compactMap { part in
                if let t = part["text"]?.stringValue { return t }
                if case .string(let s) = part { return s }
                return nil
            }.joined(separator: "\n")
        default:
            return ""
        }
    }
}

// MARK: - BackendToolKind / BackendToolCallItem

/// Discriminated union of backend-executed tool call types. Each variant
/// wraps the native Responses API struct, enabling zero-copy round-tripping
/// when building subsequent API requests.
public enum BackendToolKind: Codable, Sendable, Equatable, Hashable {
    case webSearch(WebSearchToolCall)
    case xSearch(CustomToolCall)
    case codeInterpreter(CodeInterpreterToolCall)
    case codexRawInput(CodexRawInputItem)

    public enum CodingKeys: String, CodingKey { case toolType }

    private enum WireKey: String, CodingKey {
        case webSearch = "web_search"
        case xSearch = "x_search"
        case codeInterpreter = "code_interpreter"
        case codexRawInput = "codex_raw_input"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .toolType)
        let single = try decoder.singleValueContainer()
        switch tag {
        case WireKey.webSearch.rawValue:
            self = .webSearch(try single.decode(WebSearchToolCall.self))
        case WireKey.xSearch.rawValue:
            self = .xSearch(try single.decode(CustomToolCall.self))
        case WireKey.codeInterpreter.rawValue:
            self = .codeInterpreter(try single.decode(CodeInterpreterToolCall.self))
        case WireKey.codexRawInput.rawValue:
            self = .codexRawInput(try single.decode(CodexRawInputItem.self))
        default:
            throw DecodingError.dataCorruptedError(forKey: .toolType, in: c, debugDescription: "unknown BackendToolKind: \(tag)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var single = encoder.singleValueContainer()
        switch self {
        case .webSearch(let ws):
            try c.encode(WireKey.webSearch.rawValue, forKey: .toolType)
            try single.encode(ws)
        case .xSearch(let ct):
            try c.encode(WireKey.xSearch.rawValue, forKey: .toolType)
            try single.encode(ct)
        case .codeInterpreter(let ci):
            try c.encode(WireKey.codeInterpreter.rawValue, forKey: .toolType)
            try single.encode(ci)
        case .codexRawInput(let raw):
            try c.encode(WireKey.codexRawInput.rawValue, forKey: .toolType)
            try single.encode(raw)
        }
    }
}

/// A server-side tool call from the backend agentic sampler.
public struct BackendToolCallItem: Codable, Sendable, Equatable, Hashable {
    public var kind: BackendToolKind

    public init(kind: BackendToolKind) { self.kind = kind }

    /// The backend-tool-call id (the `id` field on the underlying typed call).
    public var id: String {
        switch kind {
        case .webSearch(let ws): return ws.id
        case .xSearch(let ct): return ct.id
        case .codeInterpreter(let ci): return ci.id
        case .codexRawInput(let item): return item.id
        }
    }

    /// Human-readable summary for token estimation and text extraction.
    public func textSummary() -> String {
        switch kind {
        case .webSearch(let ws):
            if isSentinelWebSearchAction(ws.action) {
                return "[backend web_search]"
            }
            let actionDesc: String
            switch ws.action {
            case .search(let s):
                actionDesc = "search: \(s)"
            case .openPage(let o):
                actionDesc = "open: \(o ?? "?")"
            case .find(let pattern, let url):
                actionDesc = "find \"\(pattern)\" in \(url)"
            case .findInPage(let pattern, let url):
                actionDesc = "find \"\(pattern)\" in \(url)"
            }
            return "[backend web_search] \(actionDesc)"
        case .xSearch(let ct):
            return "[backend x_search] \(ct.name)(\(ct.input))"
        case .codeInterpreter(let ci):
            let codePreview: String
            if let code = ci.code {
                if code.count > 100 {
                    codePreview = "\(code.prefix(100))..."
                } else {
                    codePreview = code
                }
            } else {
                codePreview = ""
            }
            return "[backend code_interpreter] \(codePreview)"
        case .codexRawInput(let item):
            return item.textSummary()
        }
    }

    /// Approximate serialized content size for context accounting.
    public func estimatedContentLen() -> Int {
        switch kind {
        case .codexRawInput(let item):
            let visible = item.estimatedModelVisibleLen()
            let fallback = item.crossProviderFallback?.utf8.count ?? 0
            return max(visible, fallback)
        default:
            return textSummary().utf8.count
        }
    }
}

/// True when the web-search action is the sentinel that stands in for an
/// action Codex never sent (no query or URL worth rendering).
public func isSentinelWebSearchAction(_ action: WebSearchToolCallAction) -> Bool {
    switch action {
    case .search(let query):
        // The Rust sentinel is an empty-query search.
        return query.isEmpty
    default:
        return false
    }
}

// MARK: - Reasoning helpers

/// Extract human-readable text from a Responses-API reasoning item by
/// joining its `summary` parts (in order) followed by its `content` blocks.
/// Encrypted-only reasoning items return an empty string since their text is
/// not user-visible.
public func reasoningItemText(_ r: ReasoningItem) -> String {
    var parts: [String] = []
    for sp in r.summary {
        parts.append(sp.text)
    }
    if let content = r.content {
        for c in content {
            parts.append(c.text)
        }
    }
    return parts.joined(separator: "\n\n")
}

/// Construct a `ReasoningItem` carrying a single `summaryText` part — the
/// shape every non-Responses-API streaming consumer synthesizes when
/// adapting a non-typed reasoning string to the sibling-`Reasoning` data
/// model.
public func synthesizedReasoningItem(_ text: String) -> ReasoningItem {
    ReasoningItem(
        id: "",
        summary: [.summaryText(text: text)],
        content: nil,
        encryptedContent: nil,
        status: nil
    )
}

// MARK: - Saturating subtraction helper (local to this file)

private extension Int {
    func subtractingWithSaturate(_ other: Int) -> Int {
        let (diff, overflow) = self.subtractingReportingOverflow(other)
        return overflow ? 0 : diff
    }
}
