import Foundation
import OpenGrokComputerHubCore
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes

public struct McpServerInfo: Codable, Sendable, Hashable {
    public var name: String
    public var version: String
    public var capabilities: JSONValue

    public init(name: String, version: String, capabilities: JSONValue = .null) {
        self.name = name
        self.version = version
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case version
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        capabilities = try container.decodeIfPresent(JSONValue.self, forKey: .capabilities) ?? .null
    }
}

public struct McpToolDefinition: Codable, Sendable, Hashable {
    public var name: String
    public var description: String?
    public var inputSchema: JSONValue?

    public init(
        name: String,
        description: String? = nil,
        inputSchema: JSONValue? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "inputSchema"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try container.decodeIfPresent(JSONValue.self, forKey: .inputSchema)
    }
}

public struct McpCallResult: Codable, Sendable, Hashable {
    public var content: [McpContent]
    public var isError: Bool

    public init(content: [McpContent] = [], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    private enum CodingKeys: String, CodingKey {
        case content
        case isError = "isError"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent([McpContent].self, forKey: .content) ?? []
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }
}

public enum McpContent: Codable, Sendable, Hashable {
    case text(text: String)
    case image(mimeType: String, data: String)
    case resource(uri: String, mimeType: String?, text: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case mimeType = "mimeType"
        case data
        case uri
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(text: try container.decode(String.self, forKey: .text))
        case "image":
            self = .image(
                mimeType: try container.decode(String.self, forKey: .mimeType),
                data: try container.decode(String.self, forKey: .data)
            )
        case "resource":
            self = .resource(
                uri: try container.decode(String.self, forKey: .uri),
                mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType),
                text: try container.decodeIfPresent(String.self, forKey: .text)
            )
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
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let mimeType, let data):
            try container.encode("image", forKey: .type)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encode(data, forKey: .data)
        case .resource(let uri, let mimeType, let text):
            try container.encode("resource", forKey: .type)
            try container.encode(uri, forKey: .uri)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(text, forKey: .text)
        }
    }
}

public enum McpError: Error, Sendable, Hashable, Equatable, CustomStringConvertible, LocalizedError {
    case transport(String)
    case protocolError(code: Int64, message: String)
    case timeout(String)
    case decode(String)

    public var description: String {
        switch self {
        case .transport(let detail):
            return "transport error: \(detail)"
        case .protocolError(let code, let message):
            return "protocol error (code \(code)): \(message)"
        case .timeout(let detail):
            return "timeout: \(detail)"
        case .decode(let detail):
            return "decode error: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

public protocol McpTransport: Sendable {
    func initialize() async throws -> McpServerInfo
    func listTools() async throws -> [McpToolDefinition]
    func callTool(name: String, arguments: JSONValue) async throws -> McpCallResult
    func close() async throws
}

public struct McpBridgeConfig: Sendable, Hashable {
    public var sessionId: SessionId
    public var namespace: String?

    public init(sessionId: SessionId, namespace: String? = nil) {
        self.sessionId = sessionId
        self.namespace = namespace
    }
}

public struct McpBridgeHandle: Sendable {
    public let bridge: McpBridge
    public let serverInfo: McpServerInfo

    public init(bridge: McpBridge, serverInfo: McpServerInfo) {
        self.bridge = bridge
        self.serverInfo = serverInfo
    }
}

public final class McpBridge: Sendable {
    public let sessionId: SessionId

    private let transport: any McpTransport
    private let bridgedHandlers: [McpToolHandler]
    private let info: McpServerInfo

    private init(
        transport: any McpTransport,
        sessionId: SessionId,
        handlers: [McpToolHandler],
        serverInfo: McpServerInfo
    ) {
        self.transport = transport
        self.sessionId = sessionId
        self.bridgedHandlers = handlers
        self.info = serverInfo
    }

    public static func connect(
        _ transport: any McpTransport,
        _ config: McpBridgeConfig
    ) async throws -> McpBridgeHandle {
        let serverInfo: McpServerInfo
        do {
            serverInfo = try await transport.initialize()
        } catch {
            throw normalizedMcpError(error)
        }
        let definitions: [McpToolDefinition]
        do {
            definitions = try await transport.listTools()
        } catch {
            try? await transport.close()
            throw normalizedMcpError(error)
        }

        let handlers = definitions.compactMap { definition -> McpToolHandler? in
            guard let toolId = try? ToolId(definition.name) else { return nil }
            return McpToolHandler(
                toolId: toolId,
                definition: definition,
                transport: transport,
                namespace: config.namespace
            )
        }

        let bridge = McpBridge(
            transport: transport,
            sessionId: config.sessionId,
            handlers: handlers,
            serverInfo: serverInfo
        )
        return McpBridgeHandle(bridge: bridge, serverInfo: serverInfo)
    }

    public static func connect(
        transport: any McpTransport,
        config: McpBridgeConfig
    ) async throws -> McpBridgeHandle {
        try await connect(transport, config)
    }

    public func handlers() -> [McpToolHandler] {
        bridgedHandlers
    }

    public func serverInfo() -> McpServerInfo {
        info
    }

    public func toolCount() -> Int {
        bridgedHandlers.count
    }

    public func shutdown() async throws {
        do {
            try await transport.close()
        } catch {
            throw normalizedMcpError(error)
        }
    }

    deinit {
        let transport = self.transport
        Task {
            try? await transport.close()
        }
    }
}

public final class McpToolHandler: ToolHandle, Sendable {
    public let toolId: ToolId
    public let definition: McpToolDefinition

    private let transport: any McpTransport
    private let namespace: String?

    fileprivate init(
        toolId: ToolId,
        definition: McpToolDefinition,
        transport: any McpTransport,
        namespace: String?
    ) {
        self.toolId = toolId
        self.definition = definition
        self.transport = transport
        self.namespace = namespace
    }

    public func id() -> ToolId {
        toolId
    }

    public func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        var description = ToolDescription(
            name: definition.name,
            description: definition.description ?? ""
        )
        if let namespace {
            description = description.withNamespace(namespace)
        }
        if let inputSchema = definition.inputSchema {
            description = description.withArgumentsSchema(inputSchema)
        }
        return description
    }

    public func capabilities() -> ToolCapabilities {
        ToolCapabilities()
    }

    public func inputSchema() -> JSONValue? {
        definition.inputSchema
    }

    public func execute(
        ctx: ToolCallContext,
        args: JSONValue
    ) async -> ToolStream<TypedToolOutput> {
        _ = ctx
        let result: McpCallResult
        do {
            result = try await transport.callTool(name: definition.name, arguments: args)
        } catch let error as McpError {
            return terminalOnly(.failure(.execution(toolId: toolId, detail: error.description)))
        } catch {
            return terminalOnly(.failure(.execution(
                toolId: toolId,
                detail: normalizedMcpError(error).description
            )))
        }

        do {
            let output = translateMcpResult(result)
            let value = try JSONValue.encode(output)
            return terminalOnly(.success(.fromValue(toolId: toolId, value: value)))
        } catch {
            return terminalOnly(.failure(.execution(
                toolId: toolId,
                detail: "serializing MCP output: \(error)"
            )))
        }
    }

    public func handleCall(
        ctx: ToolCallContext,
        args: JSONValue
    ) async -> ToolStream<TypedToolOutput> {
        await execute(ctx: ctx, args: args)
    }
}

private func normalizedMcpError(_ error: Error) -> McpError {
    if let error = error as? McpError {
        return error
    }
    return .transport(String(describing: error))
}

func translateMcpResult(_ result: McpCallResult) -> ToolOutputWire {
    guard !result.content.isEmpty else { return .text("") }

    if result.isError {
        let text = result.content.compactMap { content -> String? in
            guard case .text(let text) = content else { return nil }
            return text
        }.joined(separator: "\n")
        return .text(text)
    }

    if result.content.count == 1, case .text(let text) = result.content[0] {
        return .text(text)
    }

    let blocks = result.content.map { content -> McpBlock in
        switch content {
        case .text(let text):
            return .text(text: text)
        case .image(let mimeType, let data):
            return .image(mimeType: mimeType, data: data)
        case .resource(let uri, let mimeType, let text):
            return .resource(uri: uri, mimeType: mimeType, text: text)
        }
    }
    return .mcp(blocks: blocks)
}
