import Foundation
import OpenGrokShared
import OpenGrokToolProtocol

/// ACP extension names shared by the client-provided, in-process MCP bridge.
public enum MCPACPWire {
    public static let call = "x.ai/mcp/call"
    public static let sdkCall = "x.ai/mcp/sdk_call"
    public static let servers = "x.ai/mcp/servers"
    public static let sdk = "x.ai/mcp/sdk"
}

/// One MCP server advertised in `session/new`'s ACP `_meta` dictionary.
public struct MCPACPServerEntry: Codable, Sendable, Hashable {
    public var name: String
    public var serverID: String

    public init(name: String, serverID: String) {
        self.name = name
        self.serverID = serverID
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case serverID = "serverId"
    }

    /// Malformed entries and repeated server names are ignored, preserving the
    /// first valid declaration as upstream's ACP session registration does.
    public static func parse(from metadata: [String: JSONValue]?) -> [Self] {
        guard let values = metadata?[MCPACPWire.servers]?.arrayValue else {
            return []
        }

        var names = Set<String>()
        var entries: [Self] = []
        for value in values {
            guard let object = value.objectValue,
                  let name = object["name"]?.stringValue,
                  let serverID = object["serverId"]?.stringValue,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !serverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  names.insert(name).inserted else {
                continue
            }
            entries.append(Self(name: name, serverID: serverID))
        }
        return entries
    }
}

/// The ACP dependency remains outside OpenGrokMCP: callers bind the owning
/// session and connected client into this reverse-invocation adapter.
public protocol MCPACPReverseInvoker: Sendable {
    func invoke(
        serverID: String,
        message: JSONValue,
        timeoutNanoseconds: UInt64
    ) async throws -> JSONValue
}

public struct ClosureMCPACPReverseInvoker: MCPACPReverseInvoker {
    private let invocation: @Sendable (String, JSONValue, UInt64) async throws -> JSONValue

    public init(
        _ invocation: @escaping @Sendable (String, JSONValue, UInt64) async throws -> JSONValue
    ) {
        self.invocation = invocation
    }

    public func invoke(
        serverID: String,
        message: JSONValue,
        timeoutNanoseconds: UInt64
    ) async throws -> JSONValue {
        try await invocation(serverID, message, timeoutNanoseconds)
    }
}

/// Half-duplex MCP transport over the ACP client's `x.ai/mcp/sdk_call` method.
///
/// ACP SDK calls accept requests, not notifications; in particular MCP's
/// post-handshake `notifications/initialized` must remain local. Session
/// ownership is enforced when this transport is issued by its bridge registry.
public actor MCPACPTransport: MCPTransport {
    public nonisolated let serverID: String
    public nonisolated let sessionID: String
    public nonisolated let serverName: String

    private let invoker: any MCPACPReverseInvoker
    private let invokeTimeoutNanoseconds: UInt64
    private let events: MCPEventStream?
    private let clientID: UInt64
    private var pending: [JsonRpcId: Task<JSONValue, Error>] = [:]
    private var closed = false

    public init(
        serverID: String,
        sessionID: String,
        serverName: String? = nil,
        invoker: any MCPACPReverseInvoker,
        invokeTimeoutNanoseconds: UInt64 = 60_000_000_000,
        events: MCPEventStream? = nil,
        clientID: UInt64 = 0
    ) {
        self.serverID = serverID
        self.sessionID = sessionID
        self.serverName = serverName ?? serverID
        self.invoker = invoker
        self.invokeTimeoutNanoseconds = invokeTimeoutNanoseconds
        self.events = events
        self.clientID = clientID
    }

    public func send(_ message: MCPWireMessage) async throws -> MCPWireMessage? {
        guard !closed else { throw MCPError.transportClosed }
        guard !serverID.isEmpty, !sessionID.isEmpty else {
            throw MCPError.invalidRequest("ACP MCP transport has no authorized session or server")
        }

        switch message {
        case .notification:
            return nil
        case .response:
            throw MCPError.invalidRequest("ACP MCP bridge accepts requests only")
        case .request(let request):
            return try await forward(request)
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        let requests = pending.values
        pending.removeAll()
        for task in requests {
            task.cancel()
        }
        events?.publish(.transportClosed(server: serverName, clientId: clientID))
    }

    public func isClosed() -> Bool { closed }

    private func forward(_ request: MCPRequest) async throws -> MCPWireMessage {
        guard pending[request.id] == nil else {
            throw MCPError.invalidRequest("duplicate ACP MCP request id \(request.id)")
        }

        let payload = try JSONValue.encode(request)
        let invoker = self.invoker
        let serverID = self.serverID
        let timeoutNanoseconds = invokeTimeoutNanoseconds
        let method = request.method

        let invocation = Task<JSONValue, Error> {
            try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask {
                    try await invoker.invoke(
                        serverID: serverID,
                        message: payload,
                        timeoutNanoseconds: timeoutNanoseconds
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    throw MCPError.timeout(method: method)
                }
                guard let value = try await group.next() else {
                    throw MCPError.internalError("ACP MCP reverse invocation completed without a response")
                }
                group.cancelAll()
                return value
            }
        }
        pending[request.id] = invocation

        do {
            let value = try await withTaskCancellationHandler {
                try await invocation.value
            } onCancel: {
                invocation.cancel()
            }
            pending.removeValue(forKey: request.id)
            guard !closed else { throw MCPError.transportClosed }
            return response(for: request, value: value)
        } catch {
            pending.removeValue(forKey: request.id)
            if closed { throw MCPError.transportClosed }
            if Task.isCancelled || error is CancellationError {
                throw MCPError.cancelled(requestID: request.id, reason: "ACP MCP request cancelled")
            }
            return failure(for: request, reason: String(describing: error))
        }
    }

    private func response(for request: MCPRequest, value: JSONValue) -> MCPWireMessage {
        guard case .object(var object) = value else {
            return failure(for: request, reason: "ACP MCP client returned a non-object response")
        }

        switch request.id {
        case .string(let identifier):
            object["id"] = .string(identifier)
        case .number(let identifier):
            object["id"] = .number(.int64(identifier))
        }

        do {
            let response = try JSONValue.object(object).decode(MCPResponse.self)
            if request.method == MCPMethod.initialize {
                if let error = response.error {
                    events?.publish(.handshakeFailed(server: serverName, reason: error.message))
                } else {
                    events?.publish(.ready(server: serverName))
                }
            }
            return .response(response)
        } catch {
            return failure(for: request, reason: "ACP MCP client returned an invalid response: \(error)")
        }
    }

    private func failure(for request: MCPRequest, reason: String) -> MCPWireMessage {
        if request.method == MCPMethod.initialize {
            events?.publish(.handshakeFailed(server: serverName, reason: reason))
        }
        return .response(MCPResponse(
            id: request.id,
            error: JsonRpcError(code: MCPJSONRPCErrorCode.internalError, message: reason)
        ))
    }
}

/// Per-session capability boundary: a reverse MCP transport cannot be opened,
/// retrieved, or closed for another session or an unadvertised server.
public actor MCPACPBridgeRegistry {
    public nonisolated let sessionID: String
    public nonisolated let servers: [MCPACPServerEntry]

    private let invoker: any MCPACPReverseInvoker
    private let invokeTimeoutNanoseconds: UInt64
    private let events: MCPEventStream?
    private let clientID: UInt64
    private let authorizedServers: [String: MCPACPServerEntry]
    private var opened: [String: MCPACPTransport] = [:]
    private var closed = false

    public init(
        sessionID: String,
        servers: [MCPACPServerEntry],
        invoker: any MCPACPReverseInvoker,
        invokeTimeoutNanoseconds: UInt64 = 60_000_000_000,
        events: MCPEventStream? = nil,
        clientID: UInt64 = 0
    ) {
        self.sessionID = sessionID
        self.servers = servers
        self.invoker = invoker
        self.invokeTimeoutNanoseconds = invokeTimeoutNanoseconds
        self.events = events
        self.clientID = clientID
        var authorizedServers: [String: MCPACPServerEntry] = [:]
        for server in servers where !server.serverID.isEmpty && !server.name.isEmpty {
            if authorizedServers[server.serverID] == nil {
                authorizedServers[server.serverID] = server
            }
        }
        self.authorizedServers = authorizedServers
    }

    public func open(serverID: String, sessionID: String) throws -> MCPACPTransport {
        let entry = try authorize(serverID: serverID, sessionID: sessionID)
        guard opened[serverID] == nil else { throw MCPError.alreadyInitialized }
        let transport = MCPACPTransport(
            serverID: serverID,
            sessionID: sessionID,
            serverName: entry.name,
            invoker: invoker,
            invokeTimeoutNanoseconds: invokeTimeoutNanoseconds,
            events: events,
            clientID: clientID
        )
        opened[serverID] = transport
        return transport
    }

    public func transport(serverID: String, sessionID: String) throws -> MCPACPTransport {
        _ = try authorize(serverID: serverID, sessionID: sessionID)
        guard let transport = opened[serverID] else { throw MCPError.notInitialized }
        return transport
    }

    public func close(serverID: String, sessionID: String) async throws {
        _ = try authorize(serverID: serverID, sessionID: sessionID)
        guard let transport = opened.removeValue(forKey: serverID) else {
            throw MCPError.notInitialized
        }
        await transport.close()
    }

    public func closeAll() async {
        guard !closed else { return }
        closed = true
        let transports = opened.values
        opened.removeAll()
        for transport in transports {
            await transport.close()
        }
    }

    private func authorize(serverID: String, sessionID: String) throws -> MCPACPServerEntry {
        guard !closed else { throw MCPError.transportClosed }
        guard !self.sessionID.isEmpty, self.sessionID == sessionID else {
            throw MCPError.invalidRequest("ACP MCP server is not authorized for this session")
        }
        guard let entry = authorizedServers[serverID] else {
            throw MCPError.invalidRequest("ACP MCP server is not advertised by this session")
        }
        return entry
    }
}
