// Tool.swift
//
// Open Grok — Swift port of `xai-tool-runtime/src/tool.rs`.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolTypes

/// Open-ended progress payload.
public enum ToolProgress: Codable, Sendable, Hashable {
    case text(text: String)
    case content(blocks: [ContentBlock])
    case custom(subkind: String, payload: JSONValue)

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case blocks
        case subkind
        case payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "text":
            self = .text(text: try c.decode(String.self, forKey: .text))
        case "content":
            self = .content(blocks: try c.decode([ContentBlock].self, forKey: .blocks))
        case "custom":
            self = .custom(
                subkind: try c.decode(String.self, forKey: .subkind),
                payload: try c.decode(JSONValue.self, forKey: .payload)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "unknown ToolProgress kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .kind)
            try c.encode(text, forKey: .text)
        case .content(let blocks):
            try c.encode("content", forKey: .kind)
            try c.encode(blocks, forKey: .blocks)
        case .custom(let subkind, let payload):
            try c.encode("custom", forKey: .kind)
            try c.encode(subkind, forKey: .subkind)
            try c.encode(payload, forKey: .payload)
        }
    }
}

/// Rich content block for `ToolProgress.content` / model output.
public enum ContentBlock: Codable, Sendable, Hashable {
    case text(text: String)
    case image(
        mimeType: String,
        data: String,
        mediaId: String?,
        filename: String?,
        path: String?,
        metadata: [String: String]
    )
    case resource(uri: String, mimeType: String?, text: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case mimeType = "mime_type"
        case mimeTypeCamel = "mimeType"
        case data
        case mediaId = "media_id"
        case filename
        case path
        case metadata
        case uri
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(text: try c.decode(String.self, forKey: .text))
        case "image":
            let mime: String
            if let m = try c.decodeIfPresent(String.self, forKey: .mimeType) {
                mime = m
            } else {
                mime = try c.decode(String.self, forKey: .mimeTypeCamel)
            }
            self = .image(
                mimeType: mime,
                data: try c.decode(String.self, forKey: .data),
                mediaId: try c.decodeIfPresent(String.self, forKey: .mediaId),
                filename: try c.decodeIfPresent(String.self, forKey: .filename),
                path: try c.decodeIfPresent(String.self, forKey: .path),
                metadata: try c.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
            )
        case "resource":
            let mime = try c.decodeIfPresent(String.self, forKey: .mimeType)
                ?? (try c.decodeIfPresent(String.self, forKey: .mimeTypeCamel))
            self = .resource(
                uri: try c.decode(String.self, forKey: .uri),
                mimeType: mime,
                text: try c.decodeIfPresent(String.self, forKey: .text)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown ContentBlock type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .image(let mimeType, let data, let mediaId, let filename, let path, let metadata):
            try c.encode("image", forKey: .type)
            try c.encode(mimeType, forKey: .mimeType)
            try c.encode(data, forKey: .data)
            try c.encodeIfPresent(mediaId, forKey: .mediaId)
            try c.encodeIfPresent(filename, forKey: .filename)
            try c.encodeIfPresent(path, forKey: .path)
            if !metadata.isEmpty { try c.encode(metadata, forKey: .metadata) }
        case .resource(let uri, let mimeType, let text):
            try c.encode("resource", forKey: .type)
            try c.encode(uri, forKey: .uri)
            try c.encodeIfPresent(mimeType, forKey: .mimeType)
            try c.encodeIfPresent(text, forKey: .text)
        }
    }
}

/// One item in a tool stream: zero or more Progress, ending in Terminal.
public enum ToolStreamItem<T: Sendable>: Sendable {
    case progress(ToolProgress)
    case terminal(Result<T, ToolError>)

    public var isTerminal: Bool {
        if case .terminal = self { return true }
        return false
    }
}

/// Async stream of tool progress/terminal items.
public typealias ToolStream<T> = AsyncStream<ToolStreamItem<T>>

/// Build a single-item stream containing only the terminal result.
public func terminalOnly<T: Sendable>(_ result: Result<T, ToolError>) -> ToolStream<T> {
    AsyncStream { continuation in
        continuation.yield(.terminal(result))
        continuation.finish()
    }
}

/// Build a stream that emits progress items then the terminal result.
public func withProgress<T: Sendable>(
    _ progress: [ToolProgress],
    terminal: @escaping @Sendable () async -> Result<T, ToolError>
) -> ToolStream<T> {
    AsyncStream { continuation in
        let task = Task {
            for item in progress {
                continuation.yield(.progress(item))
            }
            let result = await terminal()
            continuation.yield(.terminal(result))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// Type-erased tool output bundling serialised JSON with model-facing blocks.
public struct TypedToolOutput: Codable, Sendable, Hashable {
    public var toolId: ToolId
    public var value: JSONValue
    public var modelOutput: [ContentBlock]
    public var chatCompletionOutput: ToolChatCompletionResponse?

    private enum CodingKeys: String, CodingKey {
        case toolId = "tool_id"
        case value
        case modelOutput = "model_output"
        case chatCompletionOutput = "chat_completion_output"
    }

    public init(
        toolId: ToolId,
        value: JSONValue,
        modelOutput: [ContentBlock],
        chatCompletionOutput: ToolChatCompletionResponse? = nil
    ) {
        self.toolId = toolId
        self.value = value
        self.modelOutput = modelOutput
        self.chatCompletionOutput = chatCompletionOutput
    }

    public static func fromValue(toolId: ToolId, value: JSONValue) -> TypedToolOutput {
        TypedToolOutput(
            toolId: toolId,
            value: value,
            modelOutput: extractContentBlocks(from: value),
            chatCompletionOutput: nil
        )
    }

    public func withChatCompletionOutput(
        _ chatCompletionOutput: ToolChatCompletionResponse?
    ) -> TypedToolOutput {
        var copy = self
        copy.chatCompletionOutput = chatCompletionOutput
        return copy
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolId, forKey: .toolId)
        try c.encode(value, forKey: .value)
        try c.encode(modelOutput, forKey: .modelOutput)
        try c.encodeIfPresent(chatCompletionOutput, forKey: .chatCompletionOutput)
    }
}

/// Variant identifier for tools that ship multiple implementations under one id.
public enum ToolVariant: Sendable, Hashable {
    case `default`
    case variant(String)
}

/// Object-safe tool surface. Typed tools adapt to this via wrappers.
public protocol ToolDyn: Sendable {
    func id() -> ToolId
    func description(ctx: ListToolsContext) -> ToolDescription
    func capabilities() -> ToolCapabilities
    func hasDynamicDescription() -> Bool
    func shouldList(ctx: ListToolsContext) -> Bool
    func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput>
}

extension ToolDyn {
    public func capabilities() -> ToolCapabilities { ToolCapabilities() }
    public func hasDynamicDescription() -> Bool { false }
    public func shouldList(ctx: ListToolsContext) -> Bool {
        _ = ctx
        return true
    }
}

/// Group of related tools that share one `ToolId` but route by variant.
public protocol ToolFamily: Sendable {
    func id() -> ToolId
    func getTool(variant: ToolVariant) -> (any ToolDyn)?
    func variants() -> [ToolVariant]
    func defaultVariantName() -> String?
}

extension ToolFamily {
    public func defaultVariantName() -> String? { nil }
}

/// Blocking convenience tool: implement `run` for a single terminal result.
///
/// Streaming tools implement `execute` directly on `ToolDyn` instead.
public protocol BlockingTool: Sendable {
    associatedtype Output: Codable & Sendable & ToolOutput

    func id() -> ToolId
    func description(ctx: ListToolsContext) -> ToolDescription
    func capabilities() -> ToolCapabilities
    func hasDynamicDescription() -> Bool
    func shouldList(ctx: ListToolsContext) -> Bool
    func run(ctx: ToolCallContext, args: JSONValue) async -> Result<Output, ToolError>
}

extension BlockingTool {
    public func capabilities() -> ToolCapabilities { ToolCapabilities() }
    public func hasDynamicDescription() -> Bool { false }
    public func shouldList(ctx: ListToolsContext) -> Bool {
        _ = ctx
        return true
    }

    /// Adapt this blocking tool to the object-safe `ToolDyn` surface.
    public func asDyn() -> any ToolDyn {
        BlockingToolAdapter(self)
    }
}

private struct BlockingToolAdapter<T: BlockingTool>: ToolDyn {
    let tool: T
    init(_ tool: T) { self.tool = tool }

    func id() -> ToolId { tool.id() }
    func description(ctx: ListToolsContext) -> ToolDescription { tool.description(ctx: ctx) }
    func capabilities() -> ToolCapabilities { tool.capabilities() }
    func hasDynamicDescription() -> Bool { tool.hasDynamicDescription() }
    func shouldList(ctx: ListToolsContext) -> Bool { tool.shouldList(ctx: ctx) }

    func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput> {
        let tool = self.tool
        let toolId = tool.id()
        // Return a stream immediately so dispatch can race cancellation
        // against mid-flight `run` instead of blocking until completion.
        return AsyncStream { continuation in
            let task = Task {
                let result = await tool.run(ctx: ctx, args: args)
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                switch result {
                case .success(let out):
                    do {
                        let value = try JSONValue.encode(out)
                        let custom = out.modelOutput()
                        let modelOutput = custom.isEmpty ? extractContentBlocks(from: value) : custom
                        let typed = TypedToolOutput(
                            toolId: toolId,
                            value: value,
                            modelOutput: modelOutput,
                            chatCompletionOutput: out.chatCompletionOutput()
                        )
                        continuation.yield(.terminal(.success(typed)))
                    } catch {
                        continuation.yield(.terminal(.failure(
                            .execution(toolId: toolId, detail: "serializing tool output to JSON: \(error)")
                        )))
                    }
                case .failure(let err):
                    continuation.yield(.terminal(.failure(err)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
