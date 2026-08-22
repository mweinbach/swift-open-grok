import Foundation

public enum LiveSessionBusTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedPlatform
    case invalidSocketName(String)
    case socketPathTooLong(Int)
    case insecurePath(String)
    case addressInUse(String)
    case alreadyStarted
    case invalidFrame(String)
    case frameTooLarge(Int)
    case peerNotOwner
    case connectionFailed(String)
    case connectionClosed
    case timedOut

    public var description: String {
        switch self {
        case .unsupportedPlatform:
            return "session-bus Unix sockets are unsupported on this platform"
        case .invalidSocketName(let name):
            return "invalid session-bus socket name: \(name)"
        case .socketPathTooLong(let count):
            return "session-bus Unix socket path is too long (\(count) UTF-8 bytes)"
        case .insecurePath(let path):
            return "session-bus path is not private and owned by the current user: \(path)"
        case .addressInUse(let path):
            return "session-bus socket is already active: \(path)"
        case .alreadyStarted:
            return "session-bus transport is already listening"
        case .invalidFrame(let reason):
            return reason
        case .frameTooLarge(let count):
            return "session-bus JSON frame exceeds 65,536 bytes (\(count))"
        case .peerNotOwner:
            return "session-bus peer belongs to a different user"
        case .connectionFailed(let reason):
            return reason
        case .connectionClosed:
            return "session-bus connection closed before a complete reply"
        case .timedOut:
            return "session-bus request exceeded its deadline"
        }
    }
}

/// Machine-local, process-to-process session-bus wire transport.
///
/// The wire exactly matches upstream `session_bus/protocol.rs`: one compact
/// newline-terminated JSON object per connection, then one JSON response.
/// Full frames are capped at 64 KiB; the semantic 32 KiB message-body limit
/// is enforced by the runtime before routing.
public actor LiveSessionBusTransport {
    public typealias Handler = @Sendable (Data) async throws -> Data

    private let homeURL: URL
    private let processID: Int32
    private let handler: Handler

    #if os(macOS) || os(Linux)
    private var listener: LiveSessionBusSocketListener?
    private var listeningURL: URL?
    private var activeConnections: [UUID: ActiveConnection] = [:]

    private struct ActiveConnection {
        let connection: LiveSessionBusSocketConnection
        let task: Task<Void, Never>
    }
    #endif

    public init(
        homeURL: URL,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        handler: @escaping Handler
    ) {
        self.homeURL = homeURL.standardizedFileURL
        self.processID = processID
        self.handler = handler
    }

    @discardableResult
    public func start(socketName: String) async throws -> URL {
        #if os(macOS) || os(Linux)
        guard !socketName.isEmpty,
              socketName != ".",
              socketName != "..",
              !socketName.contains("/"),
              !socketName.utf8.contains(0)
        else {
            throw LiveSessionBusTransportError.invalidSocketName(socketName)
        }

        let directory = homeURL.appendingPathComponent("session-bus", isDirectory: true)
        let socketURL = directory.appendingPathComponent(socketName, isDirectory: false)
        if listener != nil {
            if listeningURL == socketURL { return socketURL }
            throw LiveSessionBusTransportError.alreadyStarted
        }

        try LiveSessionBusSocketSupport.secureDirectory(at: directory)
        _ = try LiveSessionBusSocketSupport.makeAddress(path: socketURL.path)
        try LiveSessionBusSocketSupport.removeStaleSocketIfNeeded(at: socketURL)

        let listener = try LiveSessionBusSocketListener(socketURL: socketURL)
        self.listener = listener
        listeningURL = socketURL
        listener.start(processID: processID) { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        return socketURL
        #else
        _ = socketName
        throw LiveSessionBusTransportError.unsupportedPlatform
        #endif
    }

    public func stop() async {
        #if os(macOS) || os(Linux)
        let listener = self.listener
        self.listener = nil
        listeningURL = nil
        let connections = activeConnections
        activeConnections.removeAll()
        listener?.stop()
        for active in connections.values {
            active.task.cancel()
            active.connection.close()
        }
        #endif
    }

    public static func request(
        socketURL: URL,
        payload: Data,
        timeout: TimeInterval = 5
    ) async throws -> Data {
        #if os(macOS) || os(Linux)
        try Task.checkCancellation()
        try LiveSessionBusSocketSupport.validateFrame(payload)
        let deadline = try LiveSessionBusSocketSupport.deadline(after: timeout)
        let connection = try LiveSessionBusSocketConnection.connect(
            to: socketURL.standardizedFileURL,
            deadline: deadline
        )
        defer { connection.close() }
        return try await withTaskCancellationHandler {
            try await connection.writeFrame(payload, deadline: deadline)
            return try await connection.readFrame(deadline: deadline)
        } onCancel: {
            connection.close()
        }
        #else
        _ = socketURL
        _ = payload
        _ = timeout
        throw LiveSessionBusTransportError.unsupportedPlatform
        #endif
    }

    #if os(macOS) || os(Linux)
    private func accept(_ connection: LiveSessionBusSocketConnection) {
        guard listener != nil else {
            connection.close()
            return
        }

        let identifier = UUID()
        let handler = self.handler
        let task = Task { [weak self, connection] in
            let owner = self
            defer {
                connection.close()
                Task { [owner, identifier] in
                    await owner?.finishConnection(identifier)
                }
            }
            do {
                let deadline = try LiveSessionBusSocketSupport.deadline(after: 5)
                let request = try await connection.readFrame(deadline: deadline)
                try Task.checkCancellation()
                let response = try await handler(request)
                try Task.checkCancellation()
                try await connection.writeFrame(response, deadline: deadline)
            } catch {
                // Malformed, expired, foreign, or cancelled peers receive no ack.
            }
        }
        activeConnections[identifier] = ActiveConnection(connection: connection, task: task)
    }

    private func finishConnection(_ identifier: UUID) {
        activeConnections.removeValue(forKey: identifier)
    }
    #endif
}
