import Foundation
import OpenGrokACP
import OpenGrokShared
import OpenGrokWorkspace

public enum ACPConnectionState: String, Hashable, Sendable, Codable {
    case connected
    case initialized
    case authenticated
    case closed
}

public enum ACPNotificationDisposition: String, Hashable, Sendable, Codable {
    case durable
    case live
}

public enum ACPRuntimeError: Error, Hashable, Sendable, CustomStringConvertible {
    case invalidState(expected: String, actual: String)
    case protocolVersionUnsupported(ProtocolVersion)
    case authenticationRequired
    case methodNotFound(String)
    case invalidParams(String)
    case sessionNotFound(AcpSessionId)
    case sessionClosed(AcpSessionId)
    case sessionBusy(AcpSessionId)
    case duplicateRequest(AcpRequestId)
    case requestCancelled
    case workspace(String)
    case transport(String)

    public var description: String {
        switch self {
        case .invalidState(let expected, let actual): return "invalid ACP state: expected \(expected), got \(actual)"
        case .protocolVersionUnsupported(let version): return "unsupported ACP protocol version \(version)"
        case .authenticationRequired: return "authentication required"
        case .methodNotFound(let method): return "method not found: \(method)"
        case .invalidParams(let detail): return "invalid params: \(detail)"
        case .sessionNotFound(let id): return "session not found: \(id)"
        case .sessionClosed(let id): return "session is closed: \(id)"
        case .sessionBusy(let id): return "session already has an active prompt: \(id)"
        case .duplicateRequest(let id): return "duplicate request id: \(id)"
        case .requestCancelled: return "request cancelled"
        case .workspace(let detail): return "workspace error: \(detail)"
        case .transport(let detail): return "transport error: \(detail)"
        }
    }

    public var acpError: AcpError {
        switch self {
        case .protocolVersionUnsupported:
            return AcpError(code: .invalidRequest, message: description)
        case .authenticationRequired:
            return AcpError(code: .authRequired, message: description)
        case .methodNotFound(let method):
            return AcpError(code: .methodNotFound, message: "Method not found: \(method)")
        case .invalidParams(let detail):
            return AcpError(code: .invalidParams, message: detail)
        case .sessionNotFound(let id):
            return AcpError.resourceNotFound(uri: "session://\(id.rawValue)")
        case .requestCancelled:
            return AcpError(code: .requestCancelled, message: description)
        case .invalidState, .sessionClosed, .sessionBusy, .duplicateRequest, .workspace, .transport:
            return AcpError.internalError(description)
        }
    }
}

public struct ACPSessionSnapshot: Hashable, Sendable, Codable {
    public var sessionId: AcpSessionId
    public var cwd: String
    public var additionalDirectories: [String]
    public var mcpServers: [McpServer]
    public var modeId: SessionModeId?
    public var modelId: ModelId?
    public var closed: Bool
    public var createdAt: String
    public var updatedAt: String
    public var durableUpdates: [SessionNotification]

    public init(
        sessionId: AcpSessionId,
        cwd: String,
        additionalDirectories: [String] = [],
        mcpServers: [McpServer] = [],
        modeId: SessionModeId? = nil,
        modelId: ModelId? = nil,
        closed: Bool = false,
        createdAt: String,
        updatedAt: String,
        durableUpdates: [SessionNotification] = []
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.additionalDirectories = additionalDirectories
        self.mcpServers = mcpServers
        self.modeId = modeId
        self.modelId = modelId
        self.closed = closed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.durableUpdates = durableUpdates
    }
}

public protocol ACPSessionStore: Sendable {
    func create(_ session: ACPSessionSnapshot) async throws
    func read(_ sessionId: AcpSessionId) async throws -> ACPSessionSnapshot?
    func update(_ session: ACPSessionSnapshot) async throws
    func list(cwd: String?) async throws -> [ACPSessionSnapshot]
}

public actor InMemoryACPSessionStore: ACPSessionStore {
    private var sessions: [AcpSessionId: ACPSessionSnapshot]

    public init(sessions: [ACPSessionSnapshot] = []) {
        self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
    }

    public func create(_ session: ACPSessionSnapshot) throws {
        guard sessions[session.sessionId] == nil else {
            throw ACPRuntimeError.sessionBusy(session.sessionId)
        }
        sessions[session.sessionId] = session
    }

    public func read(_ sessionId: AcpSessionId) -> ACPSessionSnapshot? {
        sessions[sessionId]
    }

    public func update(_ session: ACPSessionSnapshot) throws {
        guard sessions[session.sessionId] != nil else {
            throw ACPRuntimeError.sessionNotFound(session.sessionId)
        }
        sessions[session.sessionId] = session
    }

    public func list(cwd: String?) -> [ACPSessionSnapshot] {
        sessions.values
            .filter { cwd == nil || $0.cwd == cwd }
            .sorted {
                if $0.updatedAt == $1.updatedAt {
                    return $0.sessionId.rawValue < $1.sessionId.rawValue
                }
                return $0.updatedAt < $1.updatedAt
            }
    }
}

public struct ACPAgentConfiguration: Sendable {
    public var protocolVersion: ProtocolVersion
    public var agentCapabilities: AgentCapabilities
    public var authMethods: [AuthMethod]
    public var agentInfo: Implementation
    public var meta: AcpMeta?
    public var requireAuthentication: Bool
    public var modes: SessionModeState?
    public var models: SessionModelState?

    public init(
        protocolVersion: ProtocolVersion = .v1,
        agentCapabilities: AgentCapabilities = AgentCapabilities(
            loadSession: true,
            sessionCapabilities: SessionCapabilities(
                list: EmptyCapability(),
                fork: EmptyCapability(),
                resume: EmptyCapability(),
                close: EmptyCapability()
            ),
            auth: AgentAuthCapabilities(logout: EmptyCapability())
        ),
        authMethods: [AuthMethod] = [],
        agentInfo: Implementation = Implementation(name: "open-grok", version: "0.0.0"),
        meta: AcpMeta? = OpenGrokACPExtension.wireDictionary.mapValues { .string($0) },
        requireAuthentication: Bool = false,
        modes: SessionModeState? = nil,
        models: SessionModelState? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
        self.authMethods = authMethods
        self.agentInfo = agentInfo
        self.meta = meta
        self.requireAuthentication = requireAuthentication
        self.modes = modes
        self.models = models
    }
}

public struct ACPPromptContext: Sendable {
    public var session: ACPSessionSnapshot
    public var request: PromptRequest

    public init(session: ACPSessionSnapshot, request: PromptRequest) {
        self.session = session
        self.request = request
    }
}

public protocol ACPPromptDriver: Sendable {
    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse
    func cancel(sessionId: AcpSessionId) async
}

public struct ACPNoopPromptDriver: ACPPromptDriver {
    public init() {}

    public func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        try Task.checkCancellation()
        return PromptResponse(stopReason: .endTurn, userMessageId: context.request.messageId)
    }

    public func cancel(sessionId: AcpSessionId) async {}
}

public protocol ACPWorkspaceBoundary: Sendable {
    func validate(cwd: String) async throws -> String
    func readTextFile(sessionId: AcpSessionId, path: String, line: UInt32?, limit: UInt32?) async throws -> String
    func writeTextFile(sessionId: AcpSessionId, path: String, content: String) async throws
}

public struct LocalACPWorkspaceBoundary: ACPWorkspaceBoundary {
    public let operations: LocalWorkspaceOps

    public init(operations: LocalWorkspaceOps) {
        self.operations = operations
    }

    public func validate(cwd: String) async throws -> String {
        do { return try operations.resolvePath(cwd).path }
        catch { throw ACPRuntimeError.workspace(String(describing: error)) }
    }

    public func readTextFile(sessionId: AcpSessionId, path: String, line: UInt32?, limit: UInt32?) async throws -> String {
        do {
            let data = try await operations.readFile(path: path, toolCallId: "acp-\(sessionId.rawValue)")
            let text = String(decoding: data, as: UTF8.self)
            guard line != nil || limit != nil else { return text }
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            let start = max(0, Int(line ?? 1) - 1)
            let selected = Array(lines.dropFirst(start).prefix(Int(limit ?? UInt32.max)))
            return selected.map(String.init).joined(separator: "\n")
        } catch { throw ACPRuntimeError.workspace(String(describing: error)) }
    }

    public func writeTextFile(sessionId: AcpSessionId, path: String, content: String) async throws {
        do {
            try await operations.writeFile(
                path: path,
                data: Data(content.utf8),
                toolCallId: "acp-\(sessionId.rawValue)"
            )
        } catch { throw ACPRuntimeError.workspace(String(describing: error)) }
    }
}

public protocol ACPAgentExtensionHandler: Sendable {
    func handle(method: String, params: JSONValue) async throws -> JSONValue
}

public actor ACPReverseRequestBroker {
    private var nextId: Int64 = 1
    private var pending: [AcpRequestId: ResponseChannel<AcpResponseEnvelope>] = [:]

    public init() {}

    public func request(
        method: String,
        params: JSONValue,
        send: @escaping @Sendable (ACPMessage) async throws -> Void
    ) async throws -> JSONValue {
        let id = AcpRequestId.number(nextId)
        nextId += 1
        let channel = ResponseChannel<AcpResponseEnvelope>()
        pending[id] = channel
        do {
            try await send(.request(id: id, method: method, params: params))
        } catch {
            pending.removeValue(forKey: id)
            channel.cancel()
            throw error
        }
        return try await withTaskCancellationHandler {
            let result = await channel.awaitResponse()
            await remove(id)
            switch result {
            case .success(let value): return value.result ?? .null
            case .failure(let error): throw error
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    @discardableResult
    public func resolve(_ message: ACPMessage) -> Bool {
        guard case .response(let id, let result, let error) = message,
              let channel = pending.removeValue(forKey: id) else {
            return false
        }
        if let error { return channel.resume(with: .failure(error)) }
        return channel.resume(with: .success(AcpResponseEnvelope(result: result ?? .null)))
    }

    public func cancel(_ id: AcpRequestId) {
        guard let channel = pending.removeValue(forKey: id) else { return }
        _ = channel.resume(with: .failure(AcpError(code: .requestCancelled, message: "request cancelled")))
    }

    public func cancelAll() {
        let channels = pending.values
        pending.removeAll()
        for channel in channels {
            _ = channel.resume(with: .failure(AcpError(code: .requestCancelled, message: "request cancelled")))
        }
    }

    public func pendingCount() -> Int { pending.count }
    private func remove(_ id: AcpRequestId) { pending.removeValue(forKey: id) }
}

public enum ACPClientRole: String, Hashable, Sendable, Codable {
    case driver
    case subscriber
}

public actor ACPLeaderRouter {
    private struct Client {
        var send: @Sendable (ACPMessage) async -> Void
        var sessions: Set<AcpSessionId>
    }

    private struct SessionRoute {
        var driver: String?
        var subscribers: Set<String>
    }

    private var clients: [String: Client] = [:]
    private var sessions: [AcpSessionId: SessionRoute] = [:]
    private var interactions: [AcpRequestId: String] = [:]

    public init() {}

    public func register(clientID: String, send: @escaping @Sendable (ACPMessage) async -> Void) throws {
        guard clients[clientID] == nil else {
            throw ACPRuntimeError.duplicateRequest(.string(clientID))
        }
        clients[clientID] = Client(send: send, sessions: [])
    }

    public func unregister(clientID: String) {
        clients.removeValue(forKey: clientID)
        for (sessionID, var route) in sessions {
            route.subscribers.remove(clientID)
            if route.driver == clientID {
                route.driver = route.subscribers.sorted { $0 < $1 }.first
            }
            sessions[sessionID] = route
        }
    }

    public func claim(sessionID: AcpSessionId, clientID: String, role: ACPClientRole = .driver) throws {
        guard clients[clientID] != nil else {
            throw ACPRuntimeError.transport("client is not registered")
        }
        var route = sessions[sessionID] ?? SessionRoute(driver: nil, subscribers: [])
        switch role {
        case .driver:
            route.driver = clientID
            route.subscribers.insert(clientID)
        case .subscriber:
            route.subscribers.insert(clientID)
        }
        sessions[sessionID] = route
        clients[clientID]?.sessions.insert(sessionID)
    }

    public func recipients(for message: ACPMessage, from clientID: String) -> [String] {
        let route = ACPMethodRoute.normalize(method: message.method ?? "", params: message.params ?? .object([:]))
        if case .response(let id, _, _) = message, let owner = interactions[id] {
            return clients[owner] == nil ? [] : [owner]
        }
        guard let sessionID = sessionID(in: route.params), let session = sessions[sessionID] else {
            return clients[clientID] == nil ? [] : [clientID]
        }
        if route.method == ClientMethodNames.sessionUpdate ||
            route.method == ClientMethodNames.sessionRequestPermission ||
            route.method == OpenGrokACPExtMethods.askUserQuestion {
            return Array(session.subscribers).sorted()
        }
        if let driver = session.driver, clients[driver] != nil { return [driver] }
        return []
    }

    public func route(_ message: ACPMessage, from clientID: String) async -> [String] {
        let recipients = recipients(for: message, from: clientID)
        let route = ACPMethodRoute.normalize(method: message.method ?? "", params: message.params ?? .object([:]))
        if route.method == ClientMethodNames.sessionRequestPermission ||
            route.method == OpenGrokACPExtMethods.askUserQuestion,
            let id = message.id,
            let sessionID = sessionID(in: route.params),
            let driver = sessions[sessionID]?.driver {
            interactions[id] = driver
        }
        if case .response(let id, _, _) = message { interactions.removeValue(forKey: id) }
        for recipient in recipients { await clients[recipient]?.send(message) }
        return recipients
    }

    public func sessionRecipients(_ sessionID: AcpSessionId) -> [String] {
        Array(sessions[sessionID]?.subscribers ?? []).sorted()
    }

    private func sessionID(in params: JSONValue) -> AcpSessionId? {
        guard case .object(let object) = params,
              case .string(let value) = object["sessionId"] else { return nil }
        return AcpSessionId(value)
    }
}
