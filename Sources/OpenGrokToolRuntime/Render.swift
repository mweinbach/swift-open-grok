// Render.swift
//
// Open Grok — Swift port of `xai-tool-runtime/src/render.rs`.
//
// Model-facing output extraction and chat-completion response frames.

import Foundation
import OpenGrokShared

/// Unified protocol for typed tool outputs.
public protocol ToolOutput {
    /// Model-facing content blocks. Return empty to use automatic extraction.
    func modelOutput() -> [ContentBlock]
    /// Optional chat-completion response frame.
    func chatCompletionOutput() -> ToolChatCompletionResponse?
}

extension ToolOutput {
    public func modelOutput() -> [ContentBlock] { [] }
    public func chatCompletionOutput() -> ToolChatCompletionResponse? { nil }
}

extension JSONValue: ToolOutput {}
extension String: ToolOutput {}

/// Minimal representation of a chat-completion response streamed to the frontend.
public struct ToolChatCompletionResponse: Codable, Sendable, Hashable {
    public var result: ToolChatCompletion?
    public var streamError: ToolStreamError?

    private enum CodingKeys: String, CodingKey {
        case result
        case streamError = "stream_error"
    }

    public init(result: ToolChatCompletion? = nil, streamError: ToolStreamError? = nil) {
        self.result = result
        self.streamError = streamError
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(streamError, forKey: .streamError)
    }
}

/// Minimal chat completion response for tool result.
public struct ToolChatCompletion: Codable, Sendable, Hashable {
    public var sender: String
    public var message: String
    public var messageTag: String?
    public var toolUsageCardId: String?
    public var cardAttachment: String?
    public var mediaGenType: String?
    public var codeExecutionResult: ToolCodeExecutionResult?
    public var extra: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case sender, message
        case messageTag = "message_tag"
        case toolUsageCardId = "tool_usage_card_id"
        case cardAttachment = "card_attachment"
        case mediaGenType = "media_gen_type"
        case codeExecutionResult = "code_execution_result"
    }

    public init(
        sender: String = "",
        message: String = "",
        messageTag: String? = nil,
        toolUsageCardId: String? = nil,
        cardAttachment: String? = nil,
        mediaGenType: String? = nil,
        codeExecutionResult: ToolCodeExecutionResult? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.sender = sender
        self.message = message
        self.messageTag = messageTag
        self.toolUsageCardId = toolUsageCardId
        self.cardAttachment = cardAttachment
        self.mediaGenType = mediaGenType
        self.codeExecutionResult = codeExecutionResult
        self.extra = extra
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sender = try c.decodeIfPresent(String.self, forKey: .sender) ?? ""
        self.message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        self.messageTag = try c.decodeIfPresent(String.self, forKey: .messageTag)
        self.toolUsageCardId = try c.decodeIfPresent(String.self, forKey: .toolUsageCardId)
        self.cardAttachment = try c.decodeIfPresent(String.self, forKey: .cardAttachment)
        self.mediaGenType = try c.decodeIfPresent(String.self, forKey: .mediaGenType)
        self.codeExecutionResult = try c.decodeIfPresent(ToolCodeExecutionResult.self, forKey: .codeExecutionResult)
        // Flatten unknown fields into extra.
        self.extra = [:]
        if let all = try? JSONValue(from: decoder), case .object(let obj) = all {
            let known: Set<String> = [
                "sender", "message", "message_tag", "tool_usage_card_id",
                "card_attachment", "media_gen_type", "code_execution_result",
            ]
            self.extra = obj.filter { !known.contains($0.key) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sender, forKey: .sender)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(messageTag, forKey: .messageTag)
        try c.encodeIfPresent(toolUsageCardId, forKey: .toolUsageCardId)
        try c.encodeIfPresent(cardAttachment, forKey: .cardAttachment)
        try c.encodeIfPresent(mediaGenType, forKey: .mediaGenType)
        try c.encodeIfPresent(codeExecutionResult, forKey: .codeExecutionResult)
        // Merge extra via a single-value re-encode is complex; emit known keys only.
        // Extra fields are best-effort preserved through JSONValue round-trips
        // at higher layers.
        _ = extra
    }
}

/// Code execution result attachment on a chat completion.
public struct ToolCodeExecutionResult: Codable, Sendable, Hashable {
    public var stdout: String?
    public var stderr: String?
    public var exitCode: Int?

    private enum CodingKeys: String, CodingKey {
        case stdout, stderr
        case exitCode = "exit_code"
    }

    public init(stdout: String? = nil, stderr: String? = nil, exitCode: Int? = nil) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(stdout, forKey: .stdout)
        try c.encodeIfPresent(stderr, forKey: .stderr)
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
    }
}

/// Structured stream error (rate-limit, tool failure, …).
public struct ToolStreamError: Codable, Sendable, Hashable {
    public var code: String?
    public var message: String
    public var details: JSONValue?

    public init(code: String? = nil, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(code, forKey: .code)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(details, forKey: .details)
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, details
    }
}

/// Walk a JSON value looking for embedded ContentBlock-shaped values.
/// Everything else becomes a text block.
public func extractContentBlocks(from value: JSONValue) -> [ContentBlock] {
    switch value {
    case .string(let s):
        return [.text(text: s)]
    case .array(let arr):
        var blocks: [ContentBlock] = []
        var leftover: [JSONValue] = []
        for item in arr {
            if let block = tryParseContentBlock(item) {
                blocks.append(block)
            } else {
                leftover.append(item)
            }
        }
        if !leftover.isEmpty {
            if let data = try? JSONEncoder().encode(leftover.count == 1 ? leftover[0] : .array(leftover)),
               let text = String(data: data, encoding: .utf8)
            {
                blocks.insert(.text(text: text), at: 0)
            }
        }
        if blocks.isEmpty {
            return [.text(text: compactJSONString(value))]
        }
        return blocks
    case .object(let obj):
        if let block = tryParseContentBlock(value) {
            return [block]
        }
        // Look for a "content" or "blocks" array of content blocks.
        if case .array(let arr) = obj["content"] ?? obj["blocks"] {
            let blocks = arr.compactMap { tryParseContentBlock($0) }
            if !blocks.isEmpty { return blocks }
        }
        return [.text(text: compactJSONString(value))]
    default:
        return [.text(text: compactJSONString(value))]
    }
}

private func tryParseContentBlock(_ value: JSONValue) -> ContentBlock? {
    guard case .object(let obj) = value,
          case .string(let type) = obj["type"]
    else { return nil }
    switch type {
    case "text":
        guard case .string(let text) = obj["text"] else { return nil }
        return .text(text: text)
    case "image":
        let mime = obj["mime_type"]?.stringValue ?? obj["mimeType"]?.stringValue
        guard let mime, case .string(let data) = obj["data"] else { return nil }
        var metadata: [String: String] = [:]
        if case .object(let meta) = obj["metadata"] {
            for (k, v) in meta {
                if case .string(let s) = v { metadata[k] = s }
            }
        }
        return .image(
            mimeType: mime,
            data: data,
            mediaId: obj["media_id"]?.stringValue,
            filename: obj["filename"]?.stringValue,
            path: obj["path"]?.stringValue,
            metadata: metadata
        )
    case "resource":
        guard case .string(let uri) = obj["uri"] else { return nil }
        return .resource(
            uri: uri,
            mimeType: obj["mime_type"]?.stringValue ?? obj["mimeType"]?.stringValue,
            text: obj["text"]?.stringValue
        )
    default:
        return nil
    }
}

private func compactJSONString(_ value: JSONValue) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
        return s
    }
    return "null"
}

/// Model-output extractor protocol for adapter layers.
public protocol ModelOutputExtractor: Sendable {
    func extract(from value: JSONValue) -> [ContentBlock]
}

/// Default extractor that uses `extractContentBlocks`.
public struct DefaultModelOutputExtractor: ModelOutputExtractor {
    public init() {}
    public func extract(from value: JSONValue) -> [ContentBlock] {
        extractContentBlocks(from: value)
    }
}

/// Select an extractor. Currently always the default; reserved for
/// future per-tool overrides.
public func extractorFor(toolId: String) -> any ModelOutputExtractor {
    _ = toolId
    return DefaultModelOutputExtractor()
}
