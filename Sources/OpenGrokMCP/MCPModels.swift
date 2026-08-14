import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolTypes

public struct MCPProtocolVersion: RawRepresentable, Codable, Sendable, Hashable, Equatable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ value: String) {
        self.init(rawValue: value)
    }

    public static let latest = MCPProtocolVersion("2025-06-18")
    public static let june2025 = latest
    public static let march2025 = MCPProtocolVersion("2025-03-26")
    public static let november2024 = MCPProtocolVersion("2024-11-05")

    public var description: String { rawValue }
}

public struct MCPImplementation: Codable, Sendable, Hashable, Equatable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct MCPToolsCapability: Codable, Sendable, Hashable, Equatable {
    public var listChanged: Bool
    public var meta: JSONValue?

    public init(listChanged: Bool = false, meta: JSONValue? = nil) {
        self.listChanged = listChanged
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case listChanged
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listChanged = try container.decodeIfPresent(Bool.self, forKey: .listChanged) ?? false
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if listChanged { try container.encode(true, forKey: .listChanged) }
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct MCPResourcesCapability: Codable, Sendable, Hashable, Equatable {
    public var subscribe: Bool
    public var listChanged: Bool
    public var meta: JSONValue?

    public init(subscribe: Bool = false, listChanged: Bool = false, meta: JSONValue? = nil) {
        self.subscribe = subscribe
        self.listChanged = listChanged
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case subscribe
        case listChanged
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscribe = try container.decodeIfPresent(Bool.self, forKey: .subscribe) ?? false
        listChanged = try container.decodeIfPresent(Bool.self, forKey: .listChanged) ?? false
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if subscribe { try container.encode(true, forKey: .subscribe) }
        if listChanged { try container.encode(true, forKey: .listChanged) }
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct MCPPromptsCapability: Codable, Sendable, Hashable, Equatable {
    public var listChanged: Bool
    public var meta: JSONValue?

    public init(listChanged: Bool = false, meta: JSONValue? = nil) {
        self.listChanged = listChanged
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case listChanged
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listChanged = try container.decodeIfPresent(Bool.self, forKey: .listChanged) ?? false
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if listChanged { try container.encode(true, forKey: .listChanged) }
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct MCPLoggingCapability: Codable, Sendable, Hashable, Equatable {
    public var meta: JSONValue?

    public init(meta: JSONValue? = nil) {
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct MCPCapabilities: Codable, Sendable, Hashable, Equatable {
    public var experimental: [String: JSONValue]
    public var logging: MCPLoggingCapability?
    public var prompts: MCPPromptsCapability?
    public var resources: MCPResourcesCapability?
    public var tools: MCPToolsCapability?
    public var meta: JSONValue?

    public init(
        experimental: [String: JSONValue] = [:],
        logging: MCPLoggingCapability? = nil,
        prompts: MCPPromptsCapability? = nil,
        resources: MCPResourcesCapability? = nil,
        tools: MCPToolsCapability? = nil,
        meta: JSONValue? = nil
    ) {
        self.experimental = experimental
        self.logging = logging
        self.prompts = prompts
        self.resources = resources
        self.tools = tools
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case experimental
        case logging
        case prompts
        case resources
        case tools
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        experimental = try container.decodeIfPresent([String: JSONValue].self, forKey: .experimental) ?? [:]
        logging = try container.decodeIfPresent(MCPLoggingCapability.self, forKey: .logging)
        prompts = try container.decodeIfPresent(MCPPromptsCapability.self, forKey: .prompts)
        resources = try container.decodeIfPresent(MCPResourcesCapability.self, forKey: .resources)
        tools = try container.decodeIfPresent(MCPToolsCapability.self, forKey: .tools)
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !experimental.isEmpty { try container.encode(experimental, forKey: .experimental) }
        try container.encodeIfPresent(logging, forKey: .logging)
        try container.encodeIfPresent(prompts, forKey: .prompts)
        try container.encodeIfPresent(resources, forKey: .resources)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct MCPInitializeParams: Codable, Sendable, Hashable, Equatable {
    public var protocolVersion: MCPProtocolVersion
    public var capabilities: MCPCapabilities
    public var clientInfo: MCPImplementation
    public var meta: JSONValue?

    public init(
        protocolVersion: MCPProtocolVersion = .latest,
        capabilities: MCPCapabilities = MCPCapabilities(),
        clientInfo: MCPImplementation,
        meta: JSONValue? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.clientInfo = clientInfo
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case capabilities
        case clientInfo
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(MCPProtocolVersion.self, forKey: .protocolVersion)
        capabilities = try container.decode(MCPCapabilities.self, forKey: .capabilities)
        clientInfo = try container.decode(MCPImplementation.self, forKey: .clientInfo)
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(clientInfo, forKey: .clientInfo)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct MCPInitializeResult: Codable, Sendable, Hashable, Equatable {
    public var protocolVersion: MCPProtocolVersion
    public var capabilities: MCPCapabilities
    public var serverInfo: MCPImplementation
    public var instructions: String?
    public var meta: JSONValue?

    public init(
        protocolVersion: MCPProtocolVersion,
        capabilities: MCPCapabilities,
        serverInfo: MCPImplementation,
        instructions: String? = nil,
        meta: JSONValue? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case capabilities
        case serverInfo
        case instructions
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(MCPProtocolVersion.self, forKey: .protocolVersion)
        capabilities = try container.decode(MCPCapabilities.self, forKey: .capabilities)
        serverInfo = try container.decode(MCPImplementation.self, forKey: .serverInfo)
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(serverInfo, forKey: .serverInfo)
        try container.encodeIfPresent(instructions, forKey: .instructions)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct MCPListToolsParams: Codable, Sendable, Hashable, Equatable {
    public var cursor: String?
    public var meta: JSONValue?

    public init(cursor: String? = nil, meta: JSONValue? = nil) {
        self.cursor = cursor
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case cursor
        case meta = "_meta"
    }
}

public struct MCPListToolsResult: Codable, Sendable, Hashable, Equatable {
    public var tools: [MCPTool]
    public var nextCursor: String?
    public var meta: JSONValue?

    public init(tools: [MCPTool] = [], nextCursor: String? = nil, meta: JSONValue? = nil) {
        self.tools = tools
        self.nextCursor = nextCursor
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case tools
        case nextCursor
        case meta = "_meta"
    }
}

public struct MCPTool: Codable, Sendable, Hashable, Equatable {
    public var name: String
    public var title: String?
    public var description: String?
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue?
    public var annotations: JSONValue?
    public var meta: JSONValue?

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: JSONValue = .object(["type": .string("object")]),
        outputSchema: JSONValue? = nil,
        annotations: JSONValue? = nil,
        meta: JSONValue? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case title
        case description
        case inputSchema
        case outputSchema
        case annotations
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try container.decode(JSONValue.self, forKey: .inputSchema)
        outputSchema = try container.decodeIfPresent(JSONValue.self, forKey: .outputSchema)
        annotations = try container.decodeIfPresent(JSONValue.self, forKey: .annotations)
        meta = try container.decodeIfPresent(JSONValue.self, forKey: .meta)
    }

    public func asToolDescription() throws -> ToolDescription {
        guard !name.isEmpty else { throw MCPError.invalidParams("tool name cannot be empty") }
        return ToolDescription(name: name, description: description ?? "")
            .withTitleIfPresent(title)
            .withArgumentsSchema(inputSchema)
    }
}

private extension ToolDescription {
    func withTitleIfPresent(_ value: String?) -> ToolDescription {
        guard let value else { return self }
        return withTitle(value)
    }
}

public struct MCPCallToolParams: Codable, Sendable, Hashable, Equatable {
    public var name: String
    public var arguments: JSONValue?
    public var meta: JSONValue?

    public init(name: String, arguments: JSONValue? = nil, meta: JSONValue? = nil) {
        self.name = name
        self.arguments = arguments
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case arguments
        case meta = "_meta"
    }
}

public struct MCPCallToolResult: Codable, Sendable, Hashable, Equatable {
    public var content: [MCPContent]
    public var isError: Bool
    public var structuredContent: JSONValue?
    public var meta: JSONValue?

    public init(
        content: [MCPContent] = [],
        isError: Bool = false,
        structuredContent: JSONValue? = nil,
        meta: JSONValue? = nil
    ) {
        self.content = content
        self.isError = isError
        self.structuredContent = structuredContent
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case content
        case isError
        case structuredContent
        case meta = "_meta"
    }
}

public struct MCPListResourcesParams: Codable, Sendable, Hashable, Equatable {
    public var cursor: String?
    public var meta: JSONValue?

    public init(cursor: String? = nil, meta: JSONValue? = nil) {
        self.cursor = cursor
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case cursor
        case meta = "_meta"
    }
}

public struct MCPListResourcesResult: Codable, Sendable, Hashable, Equatable {
    public var resources: [MCPResource]
    public var nextCursor: String?
    public var meta: JSONValue?

    public init(resources: [MCPResource] = [], nextCursor: String? = nil, meta: JSONValue? = nil) {
        self.resources = resources
        self.nextCursor = nextCursor
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case resources
        case nextCursor
        case meta = "_meta"
    }
}

public struct MCPListResourceTemplatesParams: Codable, Sendable, Hashable, Equatable {
    public var cursor: String?
    public var meta: JSONValue?

    public init(cursor: String? = nil, meta: JSONValue? = nil) {
        self.cursor = cursor
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case cursor
        case meta = "_meta"
    }
}

public struct MCPListResourceTemplatesResult: Codable, Sendable, Hashable, Equatable {
    public var resourceTemplates: [MCPResourceTemplate]
    public var nextCursor: String?
    public var meta: JSONValue?

    public init(resourceTemplates: [MCPResourceTemplate] = [], nextCursor: String? = nil, meta: JSONValue? = nil) {
        self.resourceTemplates = resourceTemplates
        self.nextCursor = nextCursor
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case resourceTemplates
        case nextCursor
        case meta = "_meta"
    }
}

public struct MCPReadResourceParams: Codable, Sendable, Hashable, Equatable {
    public var uri: String
    public var meta: JSONValue?

    public init(uri: String, meta: JSONValue? = nil) {
        self.uri = uri
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case uri
        case meta = "_meta"
    }
}

public struct MCPReadResourceResult: Codable, Sendable, Hashable, Equatable {
    public var contents: [MCPResourceContents]
    public var meta: JSONValue?

    public init(contents: [MCPResourceContents] = [], meta: JSONValue? = nil) {
        self.contents = contents
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case contents
        case meta = "_meta"
    }
}

public struct MCPSubscribeResourceParams: Codable, Sendable, Hashable, Equatable {
    public var uri: String
    public var meta: JSONValue?

    public init(uri: String, meta: JSONValue? = nil) {
        self.uri = uri
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case uri
        case meta = "_meta"
    }
}

public typealias MCPUnsubscribeResourceParams = MCPSubscribeResourceParams

public struct MCPResource: Codable, Sendable, Hashable, Equatable {
    public var uri: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?
    public var size: UInt64?
    public var annotations: JSONValue?
    public var meta: JSONValue?

    public init(
        uri: String,
        name: String,
        title: String? = nil,
        description: String? = nil,
        mimeType: String? = nil,
        size: UInt64? = nil,
        annotations: JSONValue? = nil,
        meta: JSONValue? = nil
    ) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.size = size
        self.annotations = annotations
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case uri
        case name
        case title
        case description
        case mimeType
        case size
        case annotations
        case meta = "_meta"
    }
}

public struct MCPResourceTemplate: Codable, Sendable, Hashable, Equatable {
    public var uriTemplate: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?
    public var annotations: JSONValue?
    public var meta: JSONValue?

    public init(
        uriTemplate: String,
        name: String,
        title: String? = nil,
        description: String? = nil,
        mimeType: String? = nil,
        annotations: JSONValue? = nil,
        meta: JSONValue? = nil
    ) {
        self.uriTemplate = uriTemplate
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.annotations = annotations
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case uriTemplate
        case name
        case title
        case description
        case mimeType
        case annotations
        case meta = "_meta"
    }
}

public struct MCPResourceContents: Codable, Sendable, Hashable, Equatable {
    public var uri: String
    public var mimeType: String?
    public var text: String?
    public var blob: String?

    public init(uri: String, mimeType: String? = nil, text: String? = nil, blob: String? = nil) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
    }

    public func validate() throws {
        guard !uri.isEmpty else { throw MCPError.invalidParams("resource URI cannot be empty") }
        guard (text == nil) != (blob == nil) else {
            throw MCPError.invalidParams("resource contents must contain exactly one of text or blob")
        }
    }
}

public struct MCPListPromptsParams: Codable, Sendable, Hashable, Equatable {
    public var cursor: String?
    public var meta: JSONValue?

    public init(cursor: String? = nil, meta: JSONValue? = nil) {
        self.cursor = cursor
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case cursor
        case meta = "_meta"
    }
}

public struct MCPListPromptsResult: Codable, Sendable, Hashable, Equatable {
    public var prompts: [MCPPrompt]
    public var nextCursor: String?
    public var meta: JSONValue?

    public init(prompts: [MCPPrompt] = [], nextCursor: String? = nil, meta: JSONValue? = nil) {
        self.prompts = prompts
        self.nextCursor = nextCursor
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case prompts
        case nextCursor
        case meta = "_meta"
    }
}

public struct MCPPrompt: Codable, Sendable, Hashable, Equatable {
    public var name: String
    public var title: String?
    public var description: String?
    public var arguments: [MCPPromptArgument]?
    public var meta: JSONValue?

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        arguments: [MCPPromptArgument]? = nil,
        meta: JSONValue? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case title
        case description
        case arguments
        case meta = "_meta"
    }
}

public struct MCPPromptArgument: Codable, Sendable, Hashable, Equatable {
    public var name: String
    public var description: String?
    public var required: Bool?

    public init(name: String, description: String? = nil, required: Bool? = nil) {
        self.name = name
        self.description = description
        self.required = required
    }
}

public struct MCPGetPromptParams: Codable, Sendable, Hashable, Equatable {
    public var name: String
    public var arguments: [String: String]?
    public var meta: JSONValue?

    public init(name: String, arguments: [String: String]? = nil, meta: JSONValue? = nil) {
        self.name = name
        self.arguments = arguments
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case arguments
        case meta = "_meta"
    }
}

public struct MCPGetPromptResult: Codable, Sendable, Hashable, Equatable {
    public var description: String?
    public var messages: [MCPPromptMessage]
    public var meta: JSONValue?

    public init(description: String? = nil, messages: [MCPPromptMessage] = [], meta: JSONValue? = nil) {
        self.description = description
        self.messages = messages
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case description
        case messages
        case meta = "_meta"
    }
}

public enum MCPPromptRole: String, Codable, Sendable, Hashable, Equatable {
    case user
    case assistant
}

public struct MCPPromptMessage: Codable, Sendable, Hashable, Equatable {
    public var role: MCPPromptRole
    public var content: MCPContent

    public init(role: MCPPromptRole, content: MCPContent) {
        self.role = role
        self.content = content
    }
}

public enum MCPContent: Codable, Sendable, Hashable, Equatable {
    case text(text: String, annotations: JSONValue? = nil)
    case image(data: String, mimeType: String, annotations: JSONValue? = nil)
    case audio(data: String, mimeType: String, annotations: JSONValue? = nil)
    case resource(MCPEmbeddedResource)
    case resourceLink(MCPResourceLink)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case data
        case mimeType
        case annotations
        case resource
        case uri
        case name
        case title
        case description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(
                text: try container.decode(String.self, forKey: .text),
                annotations: try container.decodeIfPresent(JSONValue.self, forKey: .annotations)
            )
        case "image":
            self = .image(
                data: try container.decode(String.self, forKey: .data),
                mimeType: try container.decode(String.self, forKey: .mimeType),
                annotations: try container.decodeIfPresent(JSONValue.self, forKey: .annotations)
            )
        case "audio":
            self = .audio(
                data: try container.decode(String.self, forKey: .data),
                mimeType: try container.decode(String.self, forKey: .mimeType),
                annotations: try container.decodeIfPresent(JSONValue.self, forKey: .annotations)
            )
        case "resource":
            self = .resource(try container.decode(MCPEmbeddedResource.self, forKey: .resource))
        case "resource_link":
            self = .resourceLink(MCPResourceLink(
                uri: try container.decode(String.self, forKey: .uri),
                name: try container.decode(String.self, forKey: .name),
                title: try container.decodeIfPresent(String.self, forKey: .title),
                description: try container.decodeIfPresent(String.self, forKey: .description),
                mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType),
                annotations: try container.decodeIfPresent(JSONValue.self, forKey: .annotations)
            ))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown MCP content type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let annotations):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(annotations, forKey: .annotations)
        case .image(let data, let mimeType, let annotations):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(annotations, forKey: .annotations)
        case .audio(let data, let mimeType, let annotations):
            try container.encode("audio", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(annotations, forKey: .annotations)
        case .resource(let resource):
            try container.encode("resource", forKey: .type)
            try container.encode(resource, forKey: .resource)
        case .resourceLink(let link):
            try container.encode("resource_link", forKey: .type)
            try container.encode(link.uri, forKey: .uri)
            try container.encode(link.name, forKey: .name)
            try container.encodeIfPresent(link.title, forKey: .title)
            try container.encodeIfPresent(link.description, forKey: .description)
            try container.encodeIfPresent(link.mimeType, forKey: .mimeType)
            try container.encodeIfPresent(link.annotations, forKey: .annotations)
        }
    }
}

public struct MCPEmbeddedResource: Codable, Sendable, Hashable, Equatable {
    public var resource: MCPResourceContents
    public var annotations: JSONValue?

    public init(resource: MCPResourceContents, annotations: JSONValue? = nil) {
        self.resource = resource
        self.annotations = annotations
    }
}

public struct MCPResourceLink: Codable, Sendable, Hashable, Equatable {
    public var uri: String
    public var name: String
    public var title: String?
    public var description: String?
    public var mimeType: String?
    public var annotations: JSONValue?

    public init(
        uri: String,
        name: String,
        title: String? = nil,
        description: String? = nil,
        mimeType: String? = nil,
        annotations: JSONValue? = nil
    ) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
        self.annotations = annotations
    }
}

public struct MCPCancelledParams: Codable, Sendable, Hashable, Equatable {
    public var requestId: JsonRpcId
    public var reason: String?

    public init(requestId: JsonRpcId, reason: String? = nil) {
        self.requestId = requestId
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case requestId
        case reason
    }
}

public struct MCPProgressParams: Codable, Sendable, Hashable, Equatable {
    public var progressToken: JsonRpcId
    public var progress: Double
    public var total: Double?
    public var message: String?

    public init(progressToken: JsonRpcId, progress: Double, total: Double? = nil, message: String? = nil) {
        self.progressToken = progressToken
        self.progress = progress
        self.total = total
        self.message = message
    }
}

public struct MCPNotification: Codable, Sendable, Hashable, Equatable {
    public var jsonrpc: JsonRpcVersion
    public var method: String
    public var params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.jsonrpc = JsonRpcVersion()
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case method
        case params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(JsonRpcVersion.self, forKey: .jsonrpc)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

public struct MCPRequest: Codable, Sendable, Hashable, Equatable {
    public var jsonrpc: JsonRpcVersion
    public var id: JsonRpcId
    public var method: String
    public var params: JSONValue?

    public init(id: JsonRpcId = .newUUID(), method: String, params: JSONValue? = nil) {
        self.jsonrpc = JsonRpcVersion()
        self.id = id
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(JsonRpcVersion.self, forKey: .jsonrpc)
        id = try container.decode(JsonRpcId.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

public struct MCPResponse: Codable, Sendable, Hashable, Equatable {
    public var jsonrpc: JsonRpcVersion
    public var id: JsonRpcId
    public var result: JSONValue?
    public var error: JsonRpcError?

    public init(id: JsonRpcId, result: JSONValue) {
        self.jsonrpc = JsonRpcVersion()
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JsonRpcId, error: JsonRpcError) {
        self.jsonrpc = JsonRpcVersion()
        self.id = id
        self.result = nil
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(JsonRpcVersion.self, forKey: .jsonrpc)
        id = try container.decode(JsonRpcId.self, forKey: .id)
        let hasResult = container.contains(.result)
        let hasError = container.contains(.error)
        guard hasResult != hasError else {
            throw DecodingError.dataCorruptedError(
                forKey: .result,
                in: container,
                debugDescription: "MCP response must contain exactly one of result or error"
            )
        }
        if hasResult {
            result = try container.decode(JSONValue.self, forKey: .result)
            error = nil
        } else {
            result = nil
            error = try container.decode(JsonRpcError.self, forKey: .error)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        if let error {
            try container.encode(error, forKey: .error)
        } else {
            try container.encode(result ?? .null, forKey: .result)
        }
    }
}

public enum MCPWireMessage: Codable, Sendable, Hashable, Equatable {
    case request(MCPRequest)
    case notification(MCPNotification)
    case response(MCPResponse)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let hasMethod = container.contains(DynamicCodingKey("method"))
        let hasID = container.contains(DynamicCodingKey("id"))
        let hasResult = container.contains(DynamicCodingKey("result"))
        let hasError = container.contains(DynamicCodingKey("error"))
        if hasMethod && hasID {
            self = .request(try MCPRequest(from: decoder))
        } else if hasMethod {
            self = .notification(try MCPNotification(from: decoder))
        } else if hasResult || hasError {
            self = .response(try MCPResponse(from: decoder))
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: DynamicCodingKey("jsonrpc"),
                in: container,
                debugDescription: "MCP message is not a request, notification, or response"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .request(let request): try request.encode(to: encoder)
        case .notification(let notification): try notification.encode(to: encoder)
        case .response(let response): try response.encode(to: encoder)
        }
    }
}

public enum MCPMethod {
    public static let initialize = "initialize"
    public static let initialized = "notifications/initialized"
    public static let ping = "ping"
    public static let shutdown = "shutdown"
    public static let exit = "notifications/exit"
    public static let cancelled = "notifications/cancelled"
    public static let progress = "notifications/progress"
    public static let toolsList = "tools/list"
    public static let toolsCall = "tools/call"
    public static let resourcesList = "resources/list"
    public static let resourcesTemplatesList = "resources/templates/list"
    public static let resourcesRead = "resources/read"
    public static let resourcesSubscribe = "resources/subscribe"
    public static let resourcesUnsubscribe = "resources/unsubscribe"
    public static let promptsList = "prompts/list"
    public static let promptsGet = "prompts/get"
}
