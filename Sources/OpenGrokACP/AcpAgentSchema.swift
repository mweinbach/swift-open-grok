// AcpAgentSchema.swift
//
// Typed agent-side ACP request/response payloads (initialize, authenticate,
// session lifecycle, prompt, cancel, model, mode, configuration).

import Foundation
import OpenGrokShared

// MARK: - Implementation metadata

/// Metadata about the client or agent implementation.
public struct Implementation: Hashable, Sendable, Codable {
    public var name: String
    public var title: String?
    public var version: String
    public var meta: AcpMeta?

    public init(name: String, version: String, title: String? = nil, meta: AcpMeta? = nil) {
        self.name = name
        self.version = version
        self.title = title
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case name, title, version
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        version = try container.decode(String.self, forKey: .version)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

// MARK: - Capabilities

/// Prompt capabilities advertised by the agent.
public struct PromptCapabilities: Hashable, Sendable, Codable {
    public var image: Bool
    public var audio: Bool
    public var embeddedContext: Bool
    public var meta: AcpMeta?

    public init(
        image: Bool = false,
        audio: Bool = false,
        embeddedContext: Bool = false,
        meta: AcpMeta? = nil
    ) {
        self.image = image
        self.audio = audio
        self.embeddedContext = embeddedContext
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case image, audio, embeddedContext
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        image = try container.decodeIfPresent(Bool.self, forKey: .image) ?? false
        audio = try container.decodeIfPresent(Bool.self, forKey: .audio) ?? false
        embeddedContext = try container.decodeIfPresent(Bool.self, forKey: .embeddedContext) ?? false
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(image, forKey: .image)
        try container.encode(audio, forKey: .audio)
        try container.encode(embeddedContext, forKey: .embeddedContext)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// MCP capabilities advertised by the agent.
public struct McpCapabilities: Hashable, Sendable, Codable {
    public var http: Bool
    public var sse: Bool
    public var meta: AcpMeta?

    public init(http: Bool = false, sse: Bool = false, meta: AcpMeta? = nil) {
        self.http = http
        self.sse = sse
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case http, sse
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        http = try container.decodeIfPresent(Bool.self, forKey: .http) ?? false
        sse = try container.decodeIfPresent(Bool.self, forKey: .sse) ?? false
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(http, forKey: .http)
        try container.encode(sse, forKey: .sse)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Capability markers that are present when `{}` is supplied.
public struct EmptyCapability: Hashable, Sendable, Codable {
    public var meta: AcpMeta?

    public init(meta: AcpMeta? = nil) {
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        meta = try container?.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public typealias SessionListCapabilities = EmptyCapability
public typealias SessionForkCapabilities = EmptyCapability
public typealias SessionResumeCapabilities = EmptyCapability
public typealias SessionCloseCapabilities = EmptyCapability
public typealias SessionAdditionalDirectoriesCapabilities = EmptyCapability
public typealias LogoutCapabilities = EmptyCapability

/// Session capabilities advertised by the agent.
public struct SessionCapabilities: Hashable, Sendable, Codable {
    public var list: SessionListCapabilities?
    public var additionalDirectories: SessionAdditionalDirectoriesCapabilities?
    public var fork: SessionForkCapabilities?
    public var resume: SessionResumeCapabilities?
    public var close: SessionCloseCapabilities?
    public var meta: AcpMeta?

    public init(
        list: SessionListCapabilities? = nil,
        additionalDirectories: SessionAdditionalDirectoriesCapabilities? = nil,
        fork: SessionForkCapabilities? = nil,
        resume: SessionResumeCapabilities? = nil,
        close: SessionCloseCapabilities? = nil,
        meta: AcpMeta? = nil
    ) {
        self.list = list
        self.additionalDirectories = additionalDirectories
        self.fork = fork
        self.resume = resume
        self.close = close
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case list, additionalDirectories, fork, resume, close
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        list = try container.decodeIfPresent(SessionListCapabilities.self, forKey: .list)
        additionalDirectories = try container.decodeIfPresent(
            SessionAdditionalDirectoriesCapabilities.self,
            forKey: .additionalDirectories
        )
        fork = try container.decodeIfPresent(SessionForkCapabilities.self, forKey: .fork)
        resume = try container.decodeIfPresent(SessionResumeCapabilities.self, forKey: .resume)
        close = try container.decodeIfPresent(SessionCloseCapabilities.self, forKey: .close)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(list, forKey: .list)
        try container.encodeIfPresent(additionalDirectories, forKey: .additionalDirectories)
        try container.encodeIfPresent(fork, forKey: .fork)
        try container.encodeIfPresent(resume, forKey: .resume)
        try container.encodeIfPresent(close, forKey: .close)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Authentication-related agent capabilities.
public struct AgentAuthCapabilities: Hashable, Sendable, Codable {
    public var logout: LogoutCapabilities?
    public var meta: AcpMeta?

    public init(logout: LogoutCapabilities? = nil, meta: AcpMeta? = nil) {
        self.logout = logout
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case logout
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logout = try container.decodeIfPresent(LogoutCapabilities.self, forKey: .logout)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(logout, forKey: .logout)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Capabilities supported by the agent.
public struct AgentCapabilities: Hashable, Sendable, Codable {
    public var loadSession: Bool
    public var promptCapabilities: PromptCapabilities
    public var mcpCapabilities: McpCapabilities
    public var sessionCapabilities: SessionCapabilities
    public var auth: AgentAuthCapabilities
    public var meta: AcpMeta?

    public init(
        loadSession: Bool = false,
        promptCapabilities: PromptCapabilities = PromptCapabilities(),
        mcpCapabilities: McpCapabilities = McpCapabilities(),
        sessionCapabilities: SessionCapabilities = SessionCapabilities(),
        auth: AgentAuthCapabilities = AgentAuthCapabilities(),
        meta: AcpMeta? = nil
    ) {
        self.loadSession = loadSession
        self.promptCapabilities = promptCapabilities
        self.mcpCapabilities = mcpCapabilities
        self.sessionCapabilities = sessionCapabilities
        self.auth = auth
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case loadSession, promptCapabilities, mcpCapabilities, sessionCapabilities, auth
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        loadSession = try container.decodeIfPresent(Bool.self, forKey: .loadSession) ?? false
        promptCapabilities = try container.decodeIfPresent(PromptCapabilities.self, forKey: .promptCapabilities)
            ?? PromptCapabilities()
        mcpCapabilities = try container.decodeIfPresent(McpCapabilities.self, forKey: .mcpCapabilities)
            ?? McpCapabilities()
        sessionCapabilities = try container.decodeIfPresent(SessionCapabilities.self, forKey: .sessionCapabilities)
            ?? SessionCapabilities()
        auth = try container.decodeIfPresent(AgentAuthCapabilities.self, forKey: .auth)
            ?? AgentAuthCapabilities()
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(loadSession, forKey: .loadSession)
        try container.encode(promptCapabilities, forKey: .promptCapabilities)
        try container.encode(mcpCapabilities, forKey: .mcpCapabilities)
        try container.encode(sessionCapabilities, forKey: .sessionCapabilities)
        try container.encode(auth, forKey: .auth)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Filesystem capabilities advertised by the client.
public struct FileSystemCapabilities: Hashable, Sendable, Codable {
    public var readTextFile: Bool
    public var writeTextFile: Bool
    public var meta: AcpMeta?

    public init(readTextFile: Bool = false, writeTextFile: Bool = false, meta: AcpMeta? = nil) {
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case readTextFile, writeTextFile
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        readTextFile = try container.decodeIfPresent(Bool.self, forKey: .readTextFile) ?? false
        writeTextFile = try container.decodeIfPresent(Bool.self, forKey: .writeTextFile) ?? false
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(readTextFile, forKey: .readTextFile)
        try container.encode(writeTextFile, forKey: .writeTextFile)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Client-side capabilities.
public struct ClientCapabilities: Hashable, Sendable, Codable {
    public var fs: FileSystemCapabilities
    public var terminal: Bool
    public var meta: AcpMeta?

    public init(
        fs: FileSystemCapabilities = FileSystemCapabilities(),
        terminal: Bool = false,
        meta: AcpMeta? = nil
    ) {
        self.fs = fs
        self.terminal = terminal
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case fs, terminal
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fs = try container.decodeIfPresent(FileSystemCapabilities.self, forKey: .fs)
            ?? FileSystemCapabilities()
        terminal = try container.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fs, forKey: .fs)
        try container.encode(terminal, forKey: .terminal)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

// MARK: - Auth methods

/// Describes an available authentication method.
///
/// Wire form is untagged by default (agent-handled auth). Additional
/// unstable variants are retained as opaque objects for forward
/// compatibility.
public struct AuthMethod: Hashable, Sendable, Codable {
    public var id: AuthMethodId
    public var name: String?
    public var description: String?
    /// Optional type discriminator when present (`agent`, `env_var`, `terminal`).
    public var type: String?
    /// Lossless retention of unknown / unstable fields.
    public var unknownFields: [String: JSONValue]
    public var meta: AcpMeta?

    public init(
        id: AuthMethodId,
        name: String? = nil,
        description: String? = nil,
        type: String? = nil,
        unknownFields: [String: JSONValue] = [:],
        meta: AcpMeta? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.type = type
        self.unknownFields = unknownFields
        self.meta = meta
    }

    private enum KnownKeys: String {
        case id, name, description, type
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
        var unknown: [String: JSONValue] = [:]
        var idValue: AuthMethodId?
        var name: String?
        var description: String?
        var type: String?
        var meta: AcpMeta?

        for key in container.allKeys {
            switch key.stringValue {
            case KnownKeys.id.rawValue:
                idValue = try container.decode(AuthMethodId.self, forKey: key)
            case KnownKeys.name.rawValue:
                name = try container.decodeIfPresent(String.self, forKey: key)
            case KnownKeys.description.rawValue:
                description = try container.decodeIfPresent(String.self, forKey: key)
            case KnownKeys.type.rawValue:
                type = try container.decodeIfPresent(String.self, forKey: key)
            case KnownKeys.meta.rawValue:
                meta = try container.decodeIfPresent(AcpMeta.self, forKey: key)
            default:
                unknown[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
        }
        guard let idValue else {
            throw DecodingError.keyNotFound(
                DynamicCodingKeys(stringValue: "id")!,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "AuthMethod.id required")
            )
        }
        self.id = idValue
        self.name = name
        self.description = description
        self.type = type
        self.unknownFields = unknown
        self.meta = meta
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKeys.self)
        try container.encode(id, forKey: DynamicCodingKeys(stringValue: "id")!)
        try container.encodeIfPresent(name, forKey: DynamicCodingKeys(stringValue: "name")!)
        try container.encodeIfPresent(description, forKey: DynamicCodingKeys(stringValue: "description")!)
        try container.encodeIfPresent(type, forKey: DynamicCodingKeys(stringValue: "type")!)
        try container.encodeIfPresent(meta, forKey: DynamicCodingKeys(stringValue: "_meta")!)
        for (key, value) in unknownFields {
            try container.encode(value, forKey: DynamicCodingKeys(stringValue: key)!)
        }
    }
}

// MARK: - MCP servers

public struct EnvVariable: Hashable, Sendable, Codable {
    public var name: String
    public var value: String
    public var meta: AcpMeta?

    public init(name: String, value: String, meta: AcpMeta? = nil) {
        self.name = name
        self.value = value
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case name, value
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct HttpHeader: Hashable, Sendable, Codable {
    public var name: String
    public var value: String
    public var meta: AcpMeta?

    public init(name: String, value: String, meta: AcpMeta? = nil) {
        self.name = name
        self.value = value
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case name, value
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// MCP server connection description.
public enum McpServer: Hashable, Sendable, Codable {
    case http(McpServerHttp)
    case sse(McpServerSse)
    case stdio(McpServerStdio)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "stdio"
        switch type {
        case "http":
            self = .http(try McpServerHttp(from: decoder))
        case "sse":
            self = .sse(try McpServerSse(from: decoder))
        case "stdio":
            self = .stdio(try McpServerStdio(from: decoder))
        default:
            // Unknown transport — preserve as stdio-like with empty command for forward compat.
            self = .stdio(try McpServerStdio(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .http(let value):
            try encodeTagged(type: "http", value, to: encoder)
        case .sse(let value):
            try encodeTagged(type: "sse", value, to: encoder)
        case .stdio(let value):
            try encodeTagged(type: "stdio", value, to: encoder)
        }
    }
}

public struct McpServerHttp: Hashable, Sendable, Codable {
    public var name: String
    public var url: String
    public var headers: [HttpHeader]
    public var meta: AcpMeta?

    public init(name: String, url: String, headers: [HttpHeader] = [], meta: AcpMeta? = nil) {
        self.name = name
        self.url = url
        self.headers = headers
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case name, url, headers
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        headers = try container.decodeIfPresent([HttpHeader].self, forKey: .headers) ?? []
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        if !headers.isEmpty {
            try container.encode(headers, forKey: .headers)
        }
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct McpServerSse: Hashable, Sendable, Codable {
    public var name: String
    public var url: String
    public var headers: [HttpHeader]
    public var meta: AcpMeta?

    public init(name: String, url: String, headers: [HttpHeader] = [], meta: AcpMeta? = nil) {
        self.name = name
        self.url = url
        self.headers = headers
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case name, url, headers
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        headers = try container.decodeIfPresent([HttpHeader].self, forKey: .headers) ?? []
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        if !headers.isEmpty {
            try container.encode(headers, forKey: .headers)
        }
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct McpServerStdio: Hashable, Sendable, Codable {
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [EnvVariable]
    public var meta: AcpMeta?

    public init(
        name: String,
        command: String,
        args: [String] = [],
        env: [EnvVariable] = [],
        meta: AcpMeta? = nil
    ) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case name, command, args, env
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([EnvVariable].self, forKey: .env) ?? []
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        if !args.isEmpty {
            try container.encode(args, forKey: .args)
        }
        if !env.isEmpty {
            try container.encode(env, forKey: .env)
        }
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

// MARK: - Session mode / model / config

public struct SessionMode: Hashable, Sendable, Codable {
    public var id: SessionModeId
    public var name: String
    public var description: String?
    public var meta: AcpMeta?

    public init(id: SessionModeId, name: String, description: String? = nil, meta: AcpMeta? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SessionModeId.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct SessionModeState: Hashable, Sendable, Codable {
    public var currentModeId: SessionModeId
    public var availableModes: [SessionMode]
    public var meta: AcpMeta?

    public init(
        currentModeId: SessionModeId,
        availableModes: [SessionMode] = [],
        meta: AcpMeta? = nil
    ) {
        self.currentModeId = currentModeId
        self.availableModes = availableModes
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case currentModeId, availableModes
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentModeId = try container.decode(SessionModeId.self, forKey: .currentModeId)
        availableModes = try container.decodeIfPresent([SessionMode].self, forKey: .availableModes) ?? []
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentModeId, forKey: .currentModeId)
        try container.encode(availableModes, forKey: .availableModes)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct ModelInfo: Hashable, Sendable, Codable {
    public var modelId: ModelId
    public var name: String
    public var description: String?
    public var meta: AcpMeta?

    public init(modelId: ModelId, name: String, description: String? = nil, meta: AcpMeta? = nil) {
        self.modelId = modelId
        self.name = name
        self.description = description
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case modelId, name, description
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelId = try container.decode(ModelId.self, forKey: .modelId)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelId, forKey: .modelId)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct SessionModelState: Hashable, Sendable, Codable {
    public var currentModelId: ModelId
    public var availableModels: [ModelInfo]
    public var meta: AcpMeta?

    public init(
        currentModelId: ModelId,
        availableModels: [ModelInfo] = [],
        meta: AcpMeta? = nil
    ) {
        self.currentModelId = currentModelId
        self.availableModels = availableModels
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case currentModelId, availableModels
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentModelId = try container.decode(ModelId.self, forKey: .currentModelId)
        availableModels = try container.decodeIfPresent([ModelInfo].self, forKey: .availableModels) ?? []
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentModelId, forKey: .currentModelId)
        try container.encode(availableModels, forKey: .availableModels)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct SessionConfigSelectOption: Hashable, Sendable, Codable {
    public var valueId: SessionConfigValueId
    public var name: String
    public var description: String?
    public var meta: AcpMeta?

    public init(
        valueId: SessionConfigValueId,
        name: String,
        description: String? = nil,
        meta: AcpMeta? = nil
    ) {
        self.valueId = valueId
        self.name = name
        self.description = description
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case valueId, name, description
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        valueId = try container.decode(SessionConfigValueId.self, forKey: .valueId)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(valueId, forKey: .valueId)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// Session configuration option. Retains unknown fields for forward compat.
public struct SessionConfigOption: Hashable, Sendable, Codable {
    public var id: SessionConfigId
    public var name: String
    public var description: String?
    public var category: String?
    public var currentValue: String?
    public var options: [SessionConfigSelectOption]
    public var unknownFields: [String: JSONValue]
    public var meta: AcpMeta?

    public init(
        id: SessionConfigId,
        name: String,
        description: String? = nil,
        category: String? = nil,
        currentValue: String? = nil,
        options: [SessionConfigSelectOption] = [],
        unknownFields: [String: JSONValue] = [:],
        meta: AcpMeta? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.currentValue = currentValue
        self.options = options
        self.unknownFields = unknownFields
        self.meta = meta
    }

    private static let known: Set<String> = [
        "id", "name", "description", "category", "currentValue", "options", "_meta",
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
        id = try container.decode(SessionConfigId.self, forKey: DynamicCodingKeys(stringValue: "id")!)
        name = try container.decode(String.self, forKey: DynamicCodingKeys(stringValue: "name")!)
        description = try container.decodeIfPresent(String.self, forKey: DynamicCodingKeys(stringValue: "description")!)
        category = try container.decodeIfPresent(String.self, forKey: DynamicCodingKeys(stringValue: "category")!)
        currentValue = try container.decodeIfPresent(String.self, forKey: DynamicCodingKeys(stringValue: "currentValue")!)
        options = try container.decodeIfPresent(
            [SessionConfigSelectOption].self,
            forKey: DynamicCodingKeys(stringValue: "options")!
        ) ?? []
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: DynamicCodingKeys(stringValue: "_meta")!)
        var unknown: [String: JSONValue] = [:]
        for key in container.allKeys where !Self.known.contains(key.stringValue) {
            unknown[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        unknownFields = unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKeys.self)
        try container.encode(id, forKey: DynamicCodingKeys(stringValue: "id")!)
        try container.encode(name, forKey: DynamicCodingKeys(stringValue: "name")!)
        try container.encodeIfPresent(description, forKey: DynamicCodingKeys(stringValue: "description")!)
        try container.encodeIfPresent(category, forKey: DynamicCodingKeys(stringValue: "category")!)
        try container.encodeIfPresent(currentValue, forKey: DynamicCodingKeys(stringValue: "currentValue")!)
        if !options.isEmpty {
            try container.encode(options, forKey: DynamicCodingKeys(stringValue: "options")!)
        }
        try container.encodeIfPresent(meta, forKey: DynamicCodingKeys(stringValue: "_meta")!)
        for (key, value) in unknownFields {
            try container.encode(value, forKey: DynamicCodingKeys(stringValue: key)!)
        }
    }
}

// MARK: - Initialize / authenticate

public struct InitializeRequest: Hashable, Sendable, Codable {
    public var protocolVersion: ProtocolVersion
    public var clientCapabilities: ClientCapabilities
    public var clientInfo: Implementation?
    public var meta: AcpMeta?

    public init(
        protocolVersion: ProtocolVersion,
        clientCapabilities: ClientCapabilities = ClientCapabilities(),
        clientInfo: Implementation? = nil,
        meta: AcpMeta? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.clientCapabilities = clientCapabilities
        self.clientInfo = clientInfo
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, clientCapabilities, clientInfo
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(ProtocolVersion.self, forKey: .protocolVersion)
        clientCapabilities = try container.decodeIfPresent(ClientCapabilities.self, forKey: .clientCapabilities)
            ?? ClientCapabilities()
        clientInfo = try container.decodeIfPresent(Implementation.self, forKey: .clientInfo)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(clientCapabilities, forKey: .clientCapabilities)
        try container.encodeIfPresent(clientInfo, forKey: .clientInfo)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension InitializeRequest: AcpRequest {
    public typealias Response = InitializeResponse
    public var methodName: String { AgentMethodNames.initialize }
}

public struct InitializeResponse: Hashable, Sendable, Codable {
    public var protocolVersion: ProtocolVersion
    public var agentCapabilities: AgentCapabilities
    public var authMethods: [AuthMethod]
    public var agentInfo: Implementation?
    public var meta: AcpMeta?

    public init(
        protocolVersion: ProtocolVersion,
        agentCapabilities: AgentCapabilities = AgentCapabilities(),
        authMethods: [AuthMethod] = [],
        agentInfo: Implementation? = nil,
        meta: AcpMeta? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
        self.authMethods = authMethods
        self.agentInfo = agentInfo
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, agentCapabilities, authMethods, agentInfo
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(ProtocolVersion.self, forKey: .protocolVersion)
        agentCapabilities = try container.decodeIfPresent(AgentCapabilities.self, forKey: .agentCapabilities)
            ?? AgentCapabilities()
        authMethods = try container.decodeIfPresent([AuthMethod].self, forKey: .authMethods) ?? []
        agentInfo = try container.decodeIfPresent(Implementation.self, forKey: .agentInfo)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(agentCapabilities, forKey: .agentCapabilities)
        try container.encode(authMethods, forKey: .authMethods)
        try container.encodeIfPresent(agentInfo, forKey: .agentInfo)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct AuthenticateRequest: Hashable, Sendable, Codable {
    public var methodId: AuthMethodId
    public var meta: AcpMeta?

    public init(methodId: AuthMethodId, meta: AcpMeta? = nil) {
        self.methodId = methodId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case methodId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        methodId = try container.decode(AuthMethodId.self, forKey: .methodId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(methodId, forKey: .methodId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension AuthenticateRequest: AcpRequest {
    public typealias Response = AuthenticateResponse
    public var methodName: String { AgentMethodNames.authenticate }
}

public struct AuthenticateResponse: Hashable, Sendable, Codable {
    public var meta: AcpMeta?

    public init(meta: AcpMeta? = nil) {
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct LogoutRequest: Hashable, Sendable, Codable {
    public var meta: AcpMeta?

    public init(meta: AcpMeta? = nil) {
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension LogoutRequest: AcpRequest {
    public typealias Response = LogoutResponse
    public var methodName: String { AgentMethodNames.logout }
}

public struct LogoutResponse: Hashable, Sendable, Codable {
    public var meta: AcpMeta?

    public init(meta: AcpMeta? = nil) {
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

// MARK: - Session lifecycle requests

public struct NewSessionRequest: Hashable, Sendable, Codable {
    public var cwd: String
    public var additionalDirectories: [String]
    public var mcpServers: [McpServer]
    public var meta: AcpMeta?

    public init(
        cwd: String,
        additionalDirectories: [String] = [],
        mcpServers: [McpServer] = [],
        meta: AcpMeta? = nil
    ) {
        self.cwd = cwd
        self.additionalDirectories = additionalDirectories
        self.mcpServers = mcpServers
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case cwd, additionalDirectories, mcpServers
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try container.decode(String.self, forKey: .cwd)
        additionalDirectories = try container.decodeIfPresent([String].self, forKey: .additionalDirectories) ?? []
        mcpServers = try container.decodeIfPresent([McpServer].self, forKey: .mcpServers) ?? []
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cwd, forKey: .cwd)
        if !additionalDirectories.isEmpty {
            try container.encode(additionalDirectories, forKey: .additionalDirectories)
        }
        try container.encode(mcpServers, forKey: .mcpServers)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension NewSessionRequest: AcpRequest {
    public typealias Response = NewSessionResponse
    public var methodName: String { AgentMethodNames.sessionNew }
}

public struct NewSessionResponse: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var modes: SessionModeState?
    public var models: SessionModelState?
    public var configOptions: [SessionConfigOption]?
    public var meta: AcpMeta?

    public init(
        sessionId: AcpSessionId,
        modes: SessionModeState? = nil,
        models: SessionModelState? = nil,
        configOptions: [SessionConfigOption]? = nil,
        meta: AcpMeta? = nil
    ) {
        self.sessionId = sessionId
        self.modes = modes
        self.models = models
        self.configOptions = configOptions
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, modes, models, configOptions
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        modes = try container.decodeIfPresent(SessionModeState.self, forKey: .modes)
        models = try container.decodeIfPresent(SessionModelState.self, forKey: .models)
        configOptions = try container.decodeIfPresent([SessionConfigOption].self, forKey: .configOptions)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(modes, forKey: .modes)
        try container.encodeIfPresent(models, forKey: .models)
        try container.encodeIfPresent(configOptions, forKey: .configOptions)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct LoadSessionRequest: Hashable, Sendable, Codable {
    public var mcpServers: [McpServer]
    public var cwd: String
    public var additionalDirectories: [String]
    public var sessionId: AcpSessionId
    public var meta: AcpMeta?

    public init(
        sessionId: AcpSessionId,
        cwd: String,
        mcpServers: [McpServer] = [],
        additionalDirectories: [String] = [],
        meta: AcpMeta? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.additionalDirectories = additionalDirectories
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case mcpServers, cwd, additionalDirectories, sessionId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mcpServers = try container.decodeIfPresent([McpServer].self, forKey: .mcpServers) ?? []
        cwd = try container.decode(String.self, forKey: .cwd)
        additionalDirectories = try container.decodeIfPresent([String].self, forKey: .additionalDirectories) ?? []
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mcpServers, forKey: .mcpServers)
        try container.encode(cwd, forKey: .cwd)
        if !additionalDirectories.isEmpty {
            try container.encode(additionalDirectories, forKey: .additionalDirectories)
        }
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension LoadSessionRequest: AcpRequest {
    public typealias Response = LoadSessionResponse
    public var methodName: String { AgentMethodNames.sessionLoad }
}

public struct LoadSessionResponse: Hashable, Sendable, Codable {
    public var modes: SessionModeState?
    public var models: SessionModelState?
    public var configOptions: [SessionConfigOption]?
    public var meta: AcpMeta?

    public init(
        modes: SessionModeState? = nil,
        models: SessionModelState? = nil,
        configOptions: [SessionConfigOption]? = nil,
        meta: AcpMeta? = nil
    ) {
        self.modes = modes
        self.models = models
        self.configOptions = configOptions
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case modes, models, configOptions
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modes = try container.decodeIfPresent(SessionModeState.self, forKey: .modes)
        models = try container.decodeIfPresent(SessionModelState.self, forKey: .models)
        configOptions = try container.decodeIfPresent([SessionConfigOption].self, forKey: .configOptions)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(modes, forKey: .modes)
        try container.encodeIfPresent(models, forKey: .models)
        try container.encodeIfPresent(configOptions, forKey: .configOptions)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct ForkSessionRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var cwd: String?
    public var additionalDirectories: [String]
    public var mcpServers: [McpServer]
    public var meta: AcpMeta?

    public init(
        sessionId: AcpSessionId,
        cwd: String? = nil,
        additionalDirectories: [String] = [],
        mcpServers: [McpServer] = [],
        meta: AcpMeta? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.additionalDirectories = additionalDirectories
        self.mcpServers = mcpServers
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, cwd, additionalDirectories, mcpServers
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        additionalDirectories = try container.decodeIfPresent([String].self, forKey: .additionalDirectories) ?? []
        mcpServers = try container.decodeIfPresent([McpServer].self, forKey: .mcpServers) ?? []
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        if !additionalDirectories.isEmpty {
            try container.encode(additionalDirectories, forKey: .additionalDirectories)
        }
        try container.encode(mcpServers, forKey: .mcpServers)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension ForkSessionRequest: AcpRequest {
    public typealias Response = ForkSessionResponse
    public var methodName: String { AgentMethodNames.sessionFork }
}

public struct ForkSessionResponse: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var modes: SessionModeState?
    public var models: SessionModelState?
    public var configOptions: [SessionConfigOption]?
    public var meta: AcpMeta?

    public init(
        sessionId: AcpSessionId,
        modes: SessionModeState? = nil,
        models: SessionModelState? = nil,
        configOptions: [SessionConfigOption]? = nil,
        meta: AcpMeta? = nil
    ) {
        self.sessionId = sessionId
        self.modes = modes
        self.models = models
        self.configOptions = configOptions
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, modes, models, configOptions
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        modes = try container.decodeIfPresent(SessionModeState.self, forKey: .modes)
        models = try container.decodeIfPresent(SessionModelState.self, forKey: .models)
        configOptions = try container.decodeIfPresent([SessionConfigOption].self, forKey: .configOptions)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(modes, forKey: .modes)
        try container.encodeIfPresent(models, forKey: .models)
        try container.encodeIfPresent(configOptions, forKey: .configOptions)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct ResumeSessionRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var cwd: String?
    public var additionalDirectories: [String]
    public var mcpServers: [McpServer]
    public var meta: AcpMeta?

    public init(
        sessionId: AcpSessionId,
        cwd: String? = nil,
        additionalDirectories: [String] = [],
        mcpServers: [McpServer] = [],
        meta: AcpMeta? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.additionalDirectories = additionalDirectories
        self.mcpServers = mcpServers
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, cwd, additionalDirectories, mcpServers
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        additionalDirectories = try container.decodeIfPresent([String].self, forKey: .additionalDirectories) ?? []
        mcpServers = try container.decodeIfPresent([McpServer].self, forKey: .mcpServers) ?? []
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        if !additionalDirectories.isEmpty {
            try container.encode(additionalDirectories, forKey: .additionalDirectories)
        }
        try container.encode(mcpServers, forKey: .mcpServers)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension ResumeSessionRequest: AcpRequest {
    public typealias Response = ResumeSessionResponse
    public var methodName: String { AgentMethodNames.sessionResume }
}

public struct ResumeSessionResponse: Hashable, Sendable, Codable {
    public var modes: SessionModeState?
    public var models: SessionModelState?
    public var configOptions: [SessionConfigOption]?
    public var meta: AcpMeta?

    public init(
        modes: SessionModeState? = nil,
        models: SessionModelState? = nil,
        configOptions: [SessionConfigOption]? = nil,
        meta: AcpMeta? = nil
    ) {
        self.modes = modes
        self.models = models
        self.configOptions = configOptions
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case modes, models, configOptions
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modes = try container.decodeIfPresent(SessionModeState.self, forKey: .modes)
        models = try container.decodeIfPresent(SessionModelState.self, forKey: .models)
        configOptions = try container.decodeIfPresent([SessionConfigOption].self, forKey: .configOptions)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(modes, forKey: .modes)
        try container.encodeIfPresent(models, forKey: .models)
        try container.encodeIfPresent(configOptions, forKey: .configOptions)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct CloseSessionRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var meta: AcpMeta?

    public init(sessionId: AcpSessionId, meta: AcpMeta? = nil) {
        self.sessionId = sessionId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension CloseSessionRequest: AcpRequest {
    public typealias Response = CloseSessionResponse
    public var methodName: String { AgentMethodNames.sessionClose }
}

public struct CloseSessionResponse: Hashable, Sendable, Codable {
    public var meta: AcpMeta?

    public init(meta: AcpMeta? = nil) {
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct ListSessionsRequest: Hashable, Sendable, Codable {
    public var cwd: String?
    public var meta: AcpMeta?

    public init(cwd: String? = nil, meta: AcpMeta? = nil) {
        self.cwd = cwd
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case cwd
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension ListSessionsRequest: AcpRequest {
    public typealias Response = ListSessionsResponse
    public var methodName: String { AgentMethodNames.sessionList }
}

public struct AcpSessionInfo: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var cwd: String?
    public var title: String?
    public var updatedAt: String?
    public var meta: AcpMeta?

    public init(
        sessionId: AcpSessionId,
        cwd: String? = nil,
        title: String? = nil,
        updatedAt: String? = nil,
        meta: AcpMeta? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, cwd, title, updatedAt
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct ListSessionsResponse: Hashable, Sendable, Codable {
    public var sessions: [AcpSessionInfo]
    public var meta: AcpMeta?

    public init(sessions: [AcpSessionInfo] = [], meta: AcpMeta? = nil) {
        self.sessions = sessions
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessions
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent([AcpSessionInfo].self, forKey: .sessions) ?? []
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessions, forKey: .sessions)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

// MARK: - Mode / model / config setters

public struct SetSessionModeRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var modeId: SessionModeId
    public var meta: AcpMeta?

    public init(sessionId: AcpSessionId, modeId: SessionModeId, meta: AcpMeta? = nil) {
        self.sessionId = sessionId
        self.modeId = modeId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, modeId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        modeId = try container.decode(SessionModeId.self, forKey: .modeId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(modeId, forKey: .modeId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension SetSessionModeRequest: AcpRequest {
    public typealias Response = SetSessionModeResponse
    public var methodName: String { AgentMethodNames.sessionSetMode }
}

public struct SetSessionModeResponse: Hashable, Sendable, Codable {
    public var meta: AcpMeta?

    public init(meta: AcpMeta? = nil) {
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct SetSessionModelRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var modelId: ModelId
    public var meta: AcpMeta?

    public init(sessionId: AcpSessionId, modelId: ModelId, meta: AcpMeta? = nil) {
        self.sessionId = sessionId
        self.modelId = modelId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, modelId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        modelId = try container.decode(ModelId.self, forKey: .modelId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(modelId, forKey: .modelId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension SetSessionModelRequest: AcpRequest {
    public typealias Response = SetSessionModelResponse
    public var methodName: String { AgentMethodNames.sessionSetModel }
}

public struct SetSessionModelResponse: Hashable, Sendable, Codable {
    public var meta: AcpMeta?

    public init(meta: AcpMeta? = nil) {
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct SetSessionConfigOptionRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var configId: SessionConfigId
    public var value: String
    public var meta: AcpMeta?

    public init(
        sessionId: AcpSessionId,
        configId: SessionConfigId,
        value: String,
        meta: AcpMeta? = nil
    ) {
        self.sessionId = sessionId
        self.configId = configId
        self.value = value
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, configId, value
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        configId = try container.decode(SessionConfigId.self, forKey: .configId)
        value = try container.decode(String.self, forKey: .value)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(configId, forKey: .configId)
        try container.encode(value, forKey: .value)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension SetSessionConfigOptionRequest: AcpRequest {
    public typealias Response = SetSessionConfigOptionResponse
    public var methodName: String { AgentMethodNames.sessionSetConfigOption }
}

public struct SetSessionConfigOptionResponse: Hashable, Sendable, Codable {
    public var configOptions: [SessionConfigOption]?
    public var meta: AcpMeta?

    public init(configOptions: [SessionConfigOption]? = nil, meta: AcpMeta? = nil) {
        self.configOptions = configOptions
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case configOptions
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configOptions = try container.decodeIfPresent([SessionConfigOption].self, forKey: .configOptions)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(configOptions, forKey: .configOptions)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

// MARK: - Prompt / cancel

public struct PromptRequest: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var prompt: [ContentBlock]
    public var messageId: String?
    public var meta: AcpMeta?

    public init(
        sessionId: AcpSessionId,
        prompt: [ContentBlock],
        messageId: String? = nil,
        meta: AcpMeta? = nil
    ) {
        self.sessionId = sessionId
        self.prompt = prompt
        self.messageId = messageId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, prompt, messageId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        prompt = try container.decode([ContentBlock].self, forKey: .prompt)
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(prompt, forKey: .prompt)
        try container.encodeIfPresent(messageId, forKey: .messageId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension PromptRequest: AcpRequest {
    public typealias Response = PromptResponse
    public var methodName: String { AgentMethodNames.sessionPrompt }
}

/// Reasons why an agent stops processing a prompt turn.
public enum StopReason: String, Hashable, Sendable, Codable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
}

public struct PromptResponse: Hashable, Sendable, Codable {
    public var stopReason: StopReason
    public var userMessageId: String?
    public var meta: AcpMeta?

    public init(stopReason: StopReason, userMessageId: String? = nil, meta: AcpMeta? = nil) {
        self.stopReason = stopReason
        self.userMessageId = userMessageId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case stopReason, userMessageId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stopReason = try container.decode(StopReason.self, forKey: .stopReason)
        userMessageId = try container.decodeIfPresent(String.self, forKey: .userMessageId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stopReason, forKey: .stopReason)
        try container.encodeIfPresent(userMessageId, forKey: .userMessageId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

public struct CancelNotification: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var meta: AcpMeta?

    public init(sessionId: AcpSessionId, meta: AcpMeta? = nil) {
        self.sessionId = sessionId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(AcpSessionId.self, forKey: .sessionId)
        meta = try container.decodeIfPresent(AcpMeta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

extension CancelNotification: AcpRequest {
    public typealias Response = EmptyAcpResponse
    public var methodName: String { AgentMethodNames.sessionCancel }
}

// MARK: - Dynamic coding keys

struct DynamicCodingKeys: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
