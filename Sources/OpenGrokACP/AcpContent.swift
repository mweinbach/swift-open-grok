// AcpContent.swift
//
// Content blocks and tool-call wire types for ACP prompts, updates, and
// reverse requests. Port of `agent-client-protocol-schema` content + tool_call.

import Foundation
import OpenGrokShared

// MARK: - Content blocks

/// Content blocks represent displayable information in ACP.
///
/// Wire form: tagged on `"type"` with snake_case variants. Mirrors
/// `agent_client_protocol_schema::ContentBlock`.
public enum ContentBlock: Hashable, Sendable, Codable {
    case text(TextContent)
    case image(ImageContent)
    case audio(AudioContent)
    case resourceLink(ResourceLink)
    case resource(EmbeddedResource)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try TextContent(from: decoder))
        case "image":
            self = .image(try ImageContent(from: decoder))
        case "audio":
            self = .audio(try AudioContent(from: decoder))
        case "resource_link":
            self = .resourceLink(try ResourceLink(from: decoder))
        case "resource":
            self = .resource(try EmbeddedResource(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown ContentBlock type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let value):
            try encodeTagged(type: "text", value, to: encoder)
        case .image(let value):
            try encodeTagged(type: "image", value, to: encoder)
        case .audio(let value):
            try encodeTagged(type: "audio", value, to: encoder)
        case .resourceLink(let value):
            try encodeTagged(type: "resource_link", value, to: encoder)
        case .resource(let value):
            try encodeTagged(type: "resource", value, to: encoder)
        }
    }

    public static func text(_ text: String) -> ContentBlock {
        .text(TextContent(text: text))
    }
}

/// Text provided to or from an LLM.
public struct TextContent: Hashable, Sendable, Codable {
    public var text: String
    public var annotations: Annotations?
    public var meta: AcpMeta?

    public init(text: String, annotations: Annotations? = nil, meta: AcpMeta? = nil) {
        self.text = text
        self.annotations = annotations
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case text, annotations
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(annotations, forKey: .annotations)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// An image provided to or from an LLM.
public struct ImageContent: Hashable, Sendable, Codable {
    public var data: String
    public var mimeType: String
    public var uri: String?
    public var annotations: Annotations?
    public var meta: AcpMeta?

    public init(
        data: String,
        mimeType: String,
        uri: String? = nil,
        annotations: Annotations? = nil,
        meta: AcpMeta? = nil
    ) {
        self.data = data
        self.mimeType = mimeType
        self.uri = uri
        self.annotations = annotations
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case data, mimeType, uri, annotations
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode(String.self, forKey: .data)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        uri = try container.decodeIfPresent(String.self, forKey: .uri)
        annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data, forKey: .data)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(uri, forKey: .uri)
        try container.encodeIfPresent(annotations, forKey: .annotations)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Audio provided to or from an LLM.
public struct AudioContent: Hashable, Sendable, Codable {
    public var data: String
    public var mimeType: String
    public var annotations: Annotations?
    public var meta: AcpMeta?

    public init(
        data: String,
        mimeType: String,
        annotations: Annotations? = nil,
        meta: AcpMeta? = nil
    ) {
        self.data = data
        self.mimeType = mimeType
        self.annotations = annotations
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case data, mimeType, annotations
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode(String.self, forKey: .data)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data, forKey: .data)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(annotations, forKey: .annotations)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// A resource link reference.
public struct ResourceLink: Hashable, Sendable, Codable {
    public var uri: String
    public var name: String?
    public var description: String?
    public var mimeType: String?
    public var size: Int64?
    public var annotations: Annotations?
    public var meta: AcpMeta?

    public init(
        uri: String,
        name: String? = nil,
        description: String? = nil,
        mimeType: String? = nil,
        size: Int64? = nil,
        annotations: Annotations? = nil,
        meta: AcpMeta? = nil
    ) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.size = size
        self.annotations = annotations
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case uri, name, description, mimeType, size, annotations
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uri = try container.decode(String.self, forKey: .uri)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uri, forKey: .uri)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(annotations, forKey: .annotations)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Embedded resource contents.
public struct EmbeddedResource: Hashable, Sendable, Codable {
    public var resource: EmbeddedResourceResource
    public var annotations: Annotations?
    public var meta: AcpMeta?

    public init(
        resource: EmbeddedResourceResource,
        annotations: Annotations? = nil,
        meta: AcpMeta? = nil
    ) {
        self.resource = resource
        self.annotations = annotations
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case resource, annotations
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resource = try container.decode(EmbeddedResourceResource.self, forKey: .resource)
        annotations = try container.decodeIfPresent(Annotations.self, forKey: .annotations)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resource, forKey: .resource)
        try container.encodeIfPresent(annotations, forKey: .annotations)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Resource payload embedded in a content block.
public enum EmbeddedResourceResource: Hashable, Sendable, Codable {
    case text(TextResourceContents)
    case blob(BlobResourceContents)

    private enum CodingKeys: String, CodingKey {
        case uri, text, blob, mimeType
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.text) {
            self = .text(try TextResourceContents(from: decoder))
        } else if container.contains(.blob) {
            self = .blob(try BlobResourceContents(from: decoder))
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .uri,
                in: container,
                debugDescription: "EmbeddedResourceResource requires text or blob"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let value):
            try value.encode(to: encoder)
        case .blob(let value):
            try value.encode(to: encoder)
        }
    }
}

public struct TextResourceContents: Hashable, Sendable, Codable {
    public var uri: String
    public var text: String
    public var mimeType: String?
    public var meta: AcpMeta?

    public init(uri: String, text: String, mimeType: String? = nil, meta: AcpMeta? = nil) {
        self.uri = uri
        self.text = text
        self.mimeType = mimeType
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case uri, text, mimeType
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uri = try container.decode(String.self, forKey: .uri)
        text = try container.decode(String.self, forKey: .text)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uri, forKey: .uri)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct BlobResourceContents: Hashable, Sendable, Codable {
    public var uri: String
    public var blob: String
    public var mimeType: String?
    public var meta: AcpMeta?

    public init(uri: String, blob: String, mimeType: String? = nil, meta: AcpMeta? = nil) {
        self.uri = uri
        self.blob = blob
        self.mimeType = mimeType
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case uri, blob, mimeType
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uri = try container.decode(String.self, forKey: .uri)
        blob = try container.decode(String.self, forKey: .blob)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uri, forKey: .uri)
        try container.encode(blob, forKey: .blob)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Optional content annotations.
public struct Annotations: Hashable, Sendable, Codable {
    public var audience: [Role]?
    public var priority: Double?
    public var meta: AcpMeta?

    public init(audience: [Role]? = nil, priority: Double? = nil, meta: AcpMeta? = nil) {
        self.audience = audience
        self.priority = priority
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case audience, priority
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audience = try container.decodeIfPresent([Role].self, forKey: .audience)
        priority = try container.decodeIfPresent(Double.self, forKey: .priority)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(audience, forKey: .audience)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public enum Role: String, Hashable, Sendable, Codable {
    case user
    case assistant
}

// MARK: - Tool calls

/// Categories of tools that can be invoked.
public enum ToolKind: String, Hashable, Sendable, Codable {
    case read
    case edit
    case delete
    case move
    case search
    case execute
    case think
    case fetch
    case switchMode = "switch_mode"
    case other

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = ToolKind(rawValue: raw) ?? .other
    }
}

/// Execution status of a tool call.
public enum ToolCallStatus: String, Hashable, Sendable, Codable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

/// Content produced by a tool call.
public enum ToolCallContent: Hashable, Sendable, Codable {
    case content(ContentBlock)
    case diff(Diff)
    case terminal(terminalId: TerminalId, meta: AcpMeta?)

    private enum CodingKeys: String, CodingKey {
        case type
        case content
        case path, oldText, newText
        case terminalId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "content":
            self = .content(try container.decode(ContentBlock.self, forKey: .content))
        case "diff":
            self = .diff(try Diff(from: decoder))
        case "terminal":
            let id = try container.decode(TerminalId.self, forKey: .terminalId)
            let meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
            self = .terminal(terminalId: id, meta: meta)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown ToolCallContent type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .content(let block):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("content", forKey: .type)
            try container.encode(block, forKey: .content)
        case .diff(let diff):
            try encodeTagged(type: "diff", diff, to: encoder)
        case .terminal(let id, let meta):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("terminal", forKey: .type)
            try container.encode(id, forKey: .terminalId)
            try container.encodeIfPresent(meta, forKey: .meta)
        }
    }
}

/// A file diff produced by a tool.
public struct Diff: Hashable, Sendable, Codable {
    public var path: String
    public var oldText: String?
    public var newText: String
    public var meta: AcpMeta?

    public init(path: String, oldText: String? = nil, newText: String, meta: AcpMeta? = nil) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case path, oldText, newText
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        oldText = try container.decodeIfPresent(String.self, forKey: .oldText)
        newText = try container.decode(String.self, forKey: .newText)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(oldText, forKey: .oldText)
        try container.encode(newText, forKey: .newText)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// A file location being accessed or modified by a tool.
public struct ToolCallLocation: Hashable, Sendable, Codable {
    public var path: String
    public var line: UInt32?
    public var meta: AcpMeta?

    public init(path: String, line: UInt32? = nil, meta: AcpMeta? = nil) {
        self.path = path
        self.line = line
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case path, line
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        line = try container.decodeIfPresent(UInt32.self, forKey: .line)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(line, forKey: .line)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Notification that a new tool call has been initiated.
public struct ToolCall: Hashable, Sendable, Codable {
    public var toolCallId: ToolCallId
    public var title: String
    public var kind: ToolKind
    public var status: ToolCallStatus
    public var content: [ToolCallContent]
    public var locations: [ToolCallLocation]
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?
    public var meta: AcpMeta?

    public init(
        toolCallId: ToolCallId,
        title: String,
        kind: ToolKind = .other,
        status: ToolCallStatus = .pending,
        content: [ToolCallContent] = [],
        locations: [ToolCallLocation] = [],
        rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil,
        meta: AcpMeta? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case toolCallId, title, kind, status, content, locations, rawInput, rawOutput
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try container.decode(ToolCallId.self, forKey: .toolCallId)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decodeIfPresent(ToolKind.self, forKey: .kind) ?? .other
        status = try container.decodeIfPresent(ToolCallStatus.self, forKey: .status) ?? .pending
        content = try container.decodeIfPresent([ToolCallContent].self, forKey: .content) ?? []
        locations = try container.decodeIfPresent([ToolCallLocation].self, forKey: .locations) ?? []
        rawInput = try container.decodeIfPresent(JSONValue.self, forKey: .rawInput)
        rawOutput = try container.decodeIfPresent(JSONValue.self, forKey: .rawOutput)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolCallId, forKey: .toolCallId)
        try container.encode(title, forKey: .title)
        if kind != .other {
            try container.encode(kind, forKey: .kind)
        }
        if status != .pending {
            try container.encode(status, forKey: .status)
        }
        if !content.isEmpty {
            try container.encode(content, forKey: .content)
        }
        if !locations.isEmpty {
            try container.encode(locations, forKey: .locations)
        }
        try container.encodeIfPresent(rawInput, forKey: .rawInput)
        try container.encodeIfPresent(rawOutput, forKey: .rawOutput)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// An update to an existing tool call.
public struct ToolCallUpdate: Hashable, Sendable, Codable {
    public var toolCallId: ToolCallId
    public var kind: ToolKind?
    public var status: ToolCallStatus?
    public var title: String?
    public var content: [ToolCallContent]?
    public var locations: [ToolCallLocation]?
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?
    public var meta: AcpMeta?

    public init(
        toolCallId: ToolCallId,
        kind: ToolKind? = nil,
        status: ToolCallStatus? = nil,
        title: String? = nil,
        content: [ToolCallContent]? = nil,
        locations: [ToolCallLocation]? = nil,
        rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil,
        meta: AcpMeta? = nil
    ) {
        self.toolCallId = toolCallId
        self.kind = kind
        self.status = status
        self.title = title
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case toolCallId, kind, status, title, content, locations, rawInput, rawOutput
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try container.decode(ToolCallId.self, forKey: .toolCallId)
        kind = try container.decodeIfPresent(ToolKind.self, forKey: .kind)
        status = try container.decodeIfPresent(ToolCallStatus.self, forKey: .status)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        content = try container.decodeIfPresent([ToolCallContent].self, forKey: .content)
        locations = try container.decodeIfPresent([ToolCallLocation].self, forKey: .locations)
        rawInput = try container.decodeIfPresent(JSONValue.self, forKey: .rawInput)
        rawOutput = try container.decodeIfPresent(JSONValue.self, forKey: .rawOutput)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(locations, forKey: .locations)
        try container.encodeIfPresent(rawInput, forKey: .rawInput)
        try container.encodeIfPresent(rawOutput, forKey: .rawOutput)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

// MARK: - Encoding helpers

func encodeTagged<T: Encodable>(type: String, _ value: T, to encoder: Encoder) throws {
    // Encode the value, then inject the discriminator. We re-encode through
    // JSONValue so nested `_meta`/camelCase fields stay intact.
    let encoded = try JSONValue.encode(value)
    guard case .object(var object) = encoded else {
        throw EncodingError.invalidValue(
            value,
            EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "Tagged payload must encode as an object"
            )
        )
    }
    object["type"] = .string(type)
    try JSONValue.object(object).encode(to: encoder)
}
