import Foundation
import OpenGrokShared
import OpenGrokToolProtocol

public enum MCPServerState: String, Codable, Sendable, Hashable, Equatable {
    case notInitialized
    case initialized
    case shuttingDown
    case closed
}

public struct MCPServerConfiguration: Sendable, Hashable, Equatable {
    public var serverInfo: MCPImplementation
    public var capabilities: MCPCapabilities
    public var supportedProtocolVersions: [MCPProtocolVersion]
    public var instructions: String?

    public init(
        serverInfo: MCPImplementation = MCPImplementation(name: OpenGrokMCP.productName, version: "0.0.0"),
        capabilities: MCPCapabilities = MCPCapabilities(),
        supportedProtocolVersions: [MCPProtocolVersion] = [.latest, .march2025, .november2024],
        instructions: String? = nil
    ) {
        self.serverInfo = serverInfo
        self.capabilities = capabilities
        self.supportedProtocolVersions = supportedProtocolVersions
        self.instructions = instructions
    }

    public func negotiatedProtocolVersion(for requested: MCPProtocolVersion) -> MCPProtocolVersion? {
        if supportedProtocolVersions.contains(requested) {
            return requested
        }
        return supportedProtocolVersions.first
    }
}

public protocol MCPServerHandler: Sendable {
    func listTools(_ params: MCPListToolsParams) async throws -> MCPListToolsResult
    func callTool(_ params: MCPCallToolParams) async throws -> MCPCallToolResult
    func listResources(_ params: MCPListResourcesParams) async throws -> MCPListResourcesResult
    func listResourceTemplates(_ params: MCPListResourceTemplatesParams) async throws -> MCPListResourceTemplatesResult
    func readResource(_ params: MCPReadResourceParams) async throws -> MCPReadResourceResult
    func subscribeResource(_ params: MCPSubscribeResourceParams) async throws
    func unsubscribeResource(_ params: MCPUnsubscribeResourceParams) async throws
    func listPrompts(_ params: MCPListPromptsParams) async throws -> MCPListPromptsResult
    func getPrompt(_ params: MCPGetPromptParams) async throws -> MCPGetPromptResult
}

public extension MCPServerHandler {
    func listTools(_ params: MCPListToolsParams) async throws -> MCPListToolsResult {
        _ = params
        throw MCPError.capabilityUnsupported("tools")
    }

    func callTool(_ params: MCPCallToolParams) async throws -> MCPCallToolResult {
        _ = params
        throw MCPError.capabilityUnsupported("tools")
    }

    func listResources(_ params: MCPListResourcesParams) async throws -> MCPListResourcesResult {
        _ = params
        throw MCPError.capabilityUnsupported("resources")
    }

    func listResourceTemplates(_ params: MCPListResourceTemplatesParams) async throws -> MCPListResourceTemplatesResult {
        _ = params
        throw MCPError.capabilityUnsupported("resources")
    }

    func readResource(_ params: MCPReadResourceParams) async throws -> MCPReadResourceResult {
        _ = params
        throw MCPError.capabilityUnsupported("resources")
    }

    func subscribeResource(_ params: MCPSubscribeResourceParams) async throws {
        _ = params
        throw MCPError.capabilityUnsupported("resources.subscribe")
    }

    func unsubscribeResource(_ params: MCPUnsubscribeResourceParams) async throws {
        _ = params
        throw MCPError.capabilityUnsupported("resources.subscribe")
    }

    func listPrompts(_ params: MCPListPromptsParams) async throws -> MCPListPromptsResult {
        _ = params
        throw MCPError.capabilityUnsupported("prompts")
    }

    func getPrompt(_ params: MCPGetPromptParams) async throws -> MCPGetPromptResult {
        _ = params
        throw MCPError.capabilityUnsupported("prompts")
    }
}

public actor MCPServer {
    private let configuration: MCPServerConfiguration
    private let handler: any MCPServerHandler
    private var serverState: MCPServerState = .notInitialized
    private var negotiatedVersion: MCPProtocolVersion?
    private var clientInfo: MCPImplementation?
    private var inFlight: [JsonRpcId: Task<MCPWireMessage, Never>] = [:]
    private var cancellationReasons: [JsonRpcId: String] = [:]

    public init(
        configuration: MCPServerConfiguration = MCPServerConfiguration(),
        handler: any MCPServerHandler = MCPUnsupportedServerHandler()
    ) {
        self.configuration = configuration
        self.handler = handler
    }

    public func state() -> MCPServerState { serverState }

    public func negotiatedProtocolVersion() -> MCPProtocolVersion? { negotiatedVersion }

    public func connectedClient() -> MCPImplementation? { clientInfo }

    public func handle(_ message: MCPWireMessage) async throws -> MCPWireMessage? {
        switch message {
        case .request(let request):
            return await handleRequest(request)
        case .notification(let notification):
            try await handleNotification(notification)
            return nil
        case .response:
            throw MCPError.invalidRequest("server cannot accept a response as a request")
        }
    }

    public func close() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        cancellationReasons.removeAll()
        serverState = .closed
    }

    private func handleRequest(_ request: MCPRequest) async -> MCPWireMessage {
        if request.method == MCPMethod.initialize {
            return initializeResponse(for: request)
        }
        if request.method == MCPMethod.shutdown {
            guard serverState == .initialized else {
                return errorResponse(id: request.id, error: .notInitialized)
            }
            serverState = .shuttingDown
            return successResponse(id: request.id, result: .object([:]))
        }
        guard serverState == .initialized else {
            return errorResponse(id: request.id, error: .notInitialized)
        }

        let task = Task { [weak self] () -> MCPWireMessage in
            guard let self else {
                return .response(MCPResponse(
                    id: request.id,
                    error: MCPError.internalError("MCP server deallocated").jsonRPCError()
                ))
            }
            do {
                try Task.checkCancellation()
                let result = try await self.route(request)
                try Task.checkCancellation()
                return .response(MCPResponse(id: request.id, result: result))
            } catch is CancellationError {
                let reason = await self.cancellationReason(for: request.id) ?? "cancelled"
                return .response(MCPResponse(
                    id: request.id,
                    error: MCPError.cancelled(requestID: request.id, reason: reason).jsonRPCError()
                ))
            } catch {
                return .response(MCPResponse(
                    id: request.id,
                    error: mcpError(from: error, method: request.method).jsonRPCError()
                ))
            }
        }
        inFlight[request.id] = task
        let response = await task.value
        inFlight.removeValue(forKey: request.id)
        cancellationReasons.removeValue(forKey: request.id)
        return response
    }

    private func handleNotification(_ notification: MCPNotification) async throws {
        switch notification.method {
        case MCPMethod.initialized:
            return
        case MCPMethod.cancelled:
            let params = try decodeParams(MCPCancelledParams.self, from: notification.params)
            cancellationReasons[params.requestId] = params.reason
            inFlight[params.requestId]?.cancel()
        case MCPMethod.exit:
            close()
        case MCPMethod.progress:
            return
        default:
            return
        }
    }

    private func initializeResponse(for request: MCPRequest) -> MCPWireMessage {
        guard serverState != .closed else {
            return errorResponse(id: request.id, error: .transportClosed)
        }
        guard serverState == .notInitialized else {
            return errorResponse(id: request.id, error: .alreadyInitialized)
        }

        do {
            let params = try decodeParams(MCPInitializeParams.self, from: request.params)
            guard let version = configuration.negotiatedProtocolVersion(for: params.protocolVersion) else {
                throw MCPError.capabilityUnsupported("protocol version \(params.protocolVersion.rawValue)")
            }
            negotiatedVersion = version
            clientInfo = params.clientInfo
            serverState = .initialized
            return successResponse(
                id: request.id,
                result: try mcpJSONValue(MCPInitializeResult(
                    protocolVersion: version,
                    capabilities: configuration.capabilities,
                    serverInfo: configuration.serverInfo,
                    instructions: configuration.instructions
                ))
            )
        } catch {
            return errorResponse(id: request.id, error: mcpError(from: error, method: MCPMethod.initialize))
        }
    }

    private func route(_ request: MCPRequest) async throws -> JSONValue {
        switch request.method {
        case MCPMethod.ping:
            return .object([:])
        case MCPMethod.toolsList:
            try requireCapability(configuration.capabilities.tools != nil, named: "tools")
            return try mcpJSONValue(await handler.listTools(try decodeParams(MCPListToolsParams.self, from: request.params)))
        case MCPMethod.toolsCall:
            try requireCapability(configuration.capabilities.tools != nil, named: "tools")
            let params = try decodeParams(MCPCallToolParams.self, from: request.params)
            guard !params.name.isEmpty else { throw MCPError.invalidParams("tool name cannot be empty") }
            return try mcpJSONValue(await handler.callTool(params))
        case MCPMethod.resourcesList:
            try requireCapability(configuration.capabilities.resources != nil, named: "resources")
            return try mcpJSONValue(await handler.listResources(try decodeParams(MCPListResourcesParams.self, from: request.params)))
        case MCPMethod.resourcesTemplatesList:
            try requireCapability(configuration.capabilities.resources != nil, named: "resources")
            return try mcpJSONValue(await handler.listResourceTemplates(try decodeParams(MCPListResourceTemplatesParams.self, from: request.params)))
        case MCPMethod.resourcesRead:
            try requireCapability(configuration.capabilities.resources != nil, named: "resources")
            let result = try await handler.readResource(try decodeParams(MCPReadResourceParams.self, from: request.params))
            for content in result.contents { try content.validate() }
            return try mcpJSONValue(result)
        case MCPMethod.resourcesSubscribe:
            try requireCapability(configuration.capabilities.resources?.subscribe == true, named: "resources.subscribe")
            try await handler.subscribeResource(try decodeParams(MCPSubscribeResourceParams.self, from: request.params))
            return .object([:])
        case MCPMethod.resourcesUnsubscribe:
            try requireCapability(configuration.capabilities.resources?.subscribe == true, named: "resources.subscribe")
            try await handler.unsubscribeResource(try decodeParams(MCPUnsubscribeResourceParams.self, from: request.params))
            return .object([:])
        case MCPMethod.promptsList:
            try requireCapability(configuration.capabilities.prompts != nil, named: "prompts")
            return try mcpJSONValue(await handler.listPrompts(try decodeParams(MCPListPromptsParams.self, from: request.params)))
        case MCPMethod.promptsGet:
            try requireCapability(configuration.capabilities.prompts != nil, named: "prompts")
            return try mcpJSONValue(await handler.getPrompt(try decodeParams(MCPGetPromptParams.self, from: request.params)))
        default:
            throw MCPError.methodNotFound(request.method)
        }
    }

    private func decodeParams<T: Decodable>(_ type: T.Type, from value: JSONValue?) throws -> T {
        let value = value ?? .object([:])
        do {
            return try value.decode(T.self)
        } catch {
            throw MCPError.invalidParams("invalid params: \(error)")
        }
    }

    private func requireCapability(_ condition: Bool, named name: String) throws {
        guard condition else { throw MCPError.capabilityUnsupported(name) }
    }

    private func cancellationReason(for requestID: JsonRpcId) -> String? {
        cancellationReasons[requestID]
    }

    private func successResponse(id: JsonRpcId, result: JSONValue) -> MCPWireMessage {
        .response(MCPResponse(id: id, result: result))
    }

    private func errorResponse(id: JsonRpcId, error: MCPError) -> MCPWireMessage {
        .response(MCPResponse(id: id, error: error.jsonRPCError()))
    }
}

public struct MCPUnsupportedServerHandler: MCPServerHandler, Sendable {
    public init() {}
}

public struct MCPClientConfiguration: Sendable, Hashable, Equatable {
    public var clientInfo: MCPImplementation
    public var protocolVersion: MCPProtocolVersion
    public var supportedProtocolVersions: [MCPProtocolVersion]
    public var capabilities: MCPCapabilities

    public init(
        clientInfo: MCPImplementation = MCPImplementation(name: OpenGrokMCP.productName, version: "0.0.0"),
        protocolVersion: MCPProtocolVersion = .latest,
        supportedProtocolVersions: [MCPProtocolVersion] = [.latest, .march2025, .november2024],
        capabilities: MCPCapabilities = MCPCapabilities()
    ) {
        self.clientInfo = clientInfo
        self.protocolVersion = protocolVersion
        self.supportedProtocolVersions = supportedProtocolVersions
        self.capabilities = capabilities
    }
}

public enum MCPClientState: String, Codable, Sendable, Hashable, Equatable {
    case disconnected
    case initializing
    case initialized
    case shuttingDown
    case closed
}

public actor MCPClient {
    private let transport: any MCPTransport
    private let configuration: MCPClientConfiguration
    private var clientState: MCPClientState = .disconnected
    private var initializeResult: MCPInitializeResult?
    private var pending: [JsonRpcId: Task<MCPWireMessage?, Error>] = [:]

    public init(
        transport: any MCPTransport,
        configuration: MCPClientConfiguration = MCPClientConfiguration()
    ) {
        self.transport = transport
        self.configuration = configuration
    }

    public func state() -> MCPClientState { clientState }

    public func serverInfo() -> MCPImplementation? { initializeResult?.serverInfo }

    public func serverCapabilities() -> MCPCapabilities? { initializeResult?.capabilities }

    public func protocolVersion() -> MCPProtocolVersion? { initializeResult?.protocolVersion }

    public func initializeResultValue() -> MCPInitializeResult? { initializeResult }

    public func initialize() async throws -> MCPInitializeResult {
        guard clientState == .disconnected else {
            if clientState == .closed { throw MCPError.transportClosed }
            throw MCPError.alreadyInitialized
        }
        clientState = .initializing
        do {
            let params = MCPInitializeParams(
                protocolVersion: configuration.protocolVersion,
                capabilities: configuration.capabilities,
                clientInfo: configuration.clientInfo
            )
            let response = try await performRequest(method: MCPMethod.initialize, params: try mcpJSONValue(params))
            let result = try decodeResult(MCPInitializeResult.self, from: response, method: MCPMethod.initialize)
            guard configuration.supportedProtocolVersions.contains(result.protocolVersion) else {
                throw MCPError.capabilityUnsupported("protocol version \(result.protocolVersion.rawValue)")
            }
            _ = try await performNotification(MCPNotification(method: MCPMethod.initialized))
            initializeResult = result
            clientState = .initialized
            return result
        } catch {
            clientState = .disconnected
            if let error = error as? MCPError { throw error }
            throw mcpError(from: error, method: MCPMethod.initialize)
        }
    }

    public func request(method: String, params: JSONValue? = nil) async throws -> JSONValue {
        guard clientState == .initialized else {
            if clientState == .closed { throw MCPError.transportClosed }
            throw MCPError.notInitialized
        }
        let response = try await performRequest(method: method, params: params)
        return try decodeResult(JSONValue.self, from: response, method: method)
    }

    public func listTools(_ params: MCPListToolsParams = MCPListToolsParams()) async throws -> MCPListToolsResult {
        try await requestTyped(method: MCPMethod.toolsList, params: params)
    }

    public func callTool(_ params: MCPCallToolParams) async throws -> MCPCallToolResult {
        try await requestTyped(method: MCPMethod.toolsCall, params: params)
    }

    public func listResources(_ params: MCPListResourcesParams = MCPListResourcesParams()) async throws -> MCPListResourcesResult {
        try await requestTyped(method: MCPMethod.resourcesList, params: params)
    }

    public func listResourceTemplates(_ params: MCPListResourceTemplatesParams = MCPListResourceTemplatesParams()) async throws -> MCPListResourceTemplatesResult {
        try await requestTyped(method: MCPMethod.resourcesTemplatesList, params: params)
    }

    public func readResource(_ params: MCPReadResourceParams) async throws -> MCPReadResourceResult {
        try await requestTyped(method: MCPMethod.resourcesRead, params: params)
    }

    public func subscribeResource(_ params: MCPSubscribeResourceParams) async throws {
        _ = try await request(method: MCPMethod.resourcesSubscribe, params: try mcpJSONValue(params))
    }

    public func unsubscribeResource(_ params: MCPUnsubscribeResourceParams) async throws {
        _ = try await request(method: MCPMethod.resourcesUnsubscribe, params: try mcpJSONValue(params))
    }

    public func listPrompts(_ params: MCPListPromptsParams = MCPListPromptsParams()) async throws -> MCPListPromptsResult {
        try await requestTyped(method: MCPMethod.promptsList, params: params)
    }

    public func getPrompt(_ params: MCPGetPromptParams) async throws -> MCPGetPromptResult {
        try await requestTyped(method: MCPMethod.promptsGet, params: params)
    }

    public func cancel(requestID: JsonRpcId, reason: String? = nil) async throws {
        pending[requestID]?.cancel()
        try await performNotification(MCPNotification(
            method: MCPMethod.cancelled,
            params: try mcpJSONValue(MCPCancelledParams(requestId: requestID, reason: reason))
        ))
    }

    public func shutdown() async throws {
        guard clientState == .initialized else {
            if clientState == .closed { return }
            throw MCPError.notInitialized
        }
        _ = try await performRequest(method: MCPMethod.shutdown, params: nil)
        clientState = .shuttingDown
    }

    public func close() async {
        if clientState == .initialized || clientState == .shuttingDown {
            try? await performNotification(MCPNotification(method: MCPMethod.exit))
        }
        await transport.close()
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        clientState = .closed
    }

    private func requestTyped<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        method: String,
        params: Params
    ) async throws -> Response {
        let response = try await request(method: method, params: try mcpJSONValue(params))
        do {
            return try response.decode(Response.self)
        } catch {
            throw MCPError.internalError("invalid \(method) result: \(error)")
        }
    }

    private func performRequest(method: String, params: JSONValue?) async throws -> MCPResponse {
        let request = MCPRequest(method: method, params: params)
        let task = Task<MCPWireMessage?, Error> {
            try await transport.send(.request(request))
        }
        pending[request.id] = task
        defer { pending.removeValue(forKey: request.id) }
        do {
            guard let message = try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                task.cancel()
                Task {
                    try? await transport.send(.notification(MCPNotification(
                        method: MCPMethod.cancelled,
                        params: try? mcpJSONValue(MCPCancelledParams(requestId: request.id, reason: "cancelled"))
                    )))
                }
            }) else {
                throw MCPError.transport("MCP transport returned no response for \(method)")
            }
            guard case .response(let response) = message else {
                throw MCPError.invalidRequest("MCP transport returned a non-response for \(method)")
            }
            guard response.id == request.id else {
                throw MCPError.invalidRequest("MCP response id does not match request id")
            }
            return response
        } catch is CancellationError {
            throw MCPError.cancelled(requestID: request.id, reason: "cancelled")
        } catch let error as MCPError {
            throw error
        } catch {
            throw mcpError(from: error, method: method)
        }
    }

    private func performNotification(_ notification: MCPNotification) async throws {
        do {
            _ = try await transport.send(.notification(notification))
        } catch let error as MCPError {
            throw error
        } catch {
            throw mcpError(from: error, method: notification.method)
        }
    }

    private func decodeResult<T: Decodable & Sendable>(
        _ type: T.Type,
        from response: MCPResponse,
        method: String
    ) throws -> T {
        if let error = response.error {
            throw MCPError.from(error, method: method)
        }
        guard let result = response.result else {
            throw MCPError.internalError("MCP response for \(method) omitted result")
        }
        do {
            return try result.decode(T.self)
        } catch {
            throw MCPError.internalError("invalid \(method) result: \(error)")
        }
    }
}
