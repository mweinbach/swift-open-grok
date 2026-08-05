// WebSocketServer.swift
//
// The listening half: a TCP accept loop that turns inbound connections into
// `WebSocketConnection`s after a successful RFC 6455 upgrade.
//
// Everything protocol-shaped lives in `WebSocketProtocol.swift` /
// `WebSocketConnection.swift` and is platform-independent; this file is only
// the socket. It follows the same platform-adapter convention as
// `OpenGrokTestSupport/HttpServer.swift`: `Network.framework` where it exists,
// and an honest typed error where it does not.
//
// Rust reference: `crates/codegen/xai-grok-shell/src/agent/server.rs:469-485`
// binds a `tokio::net::TcpListener` and mounts exactly one route, `GET /ws`.

import Foundation

#if canImport(Network)
import Network
#endif

// MARK: - Configuration

public struct WebSocketServerConfiguration: Sendable {
    /// Interface to bind. Defaults to loopback — see `LiveServeComposition`
    /// for why the default must stay loopback.
    public var host: String
    /// `0` binds an ephemeral port; the bound port is returned by `start()`.
    public var port: UInt16
    public var policy: WebSocketUpgradePolicy
    public var maximumMessageSize: Int

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 0,
        policy: WebSocketUpgradePolicy = WebSocketUpgradePolicy(),
        maximumMessageSize: Int = WebSocketLimits.defaultMaximumMessageSize
    ) {
        self.host = host
        self.port = port
        self.policy = policy
        self.maximumMessageSize = maximumMessageSize
    }
}

/// An accepted, upgraded connection.
public struct WebSocketServerConnection: Sendable {
    public let request: WebSocketHandshakeRequest
    public let connection: WebSocketConnection
    /// Peer address for logging, best-effort.
    public let peerDescription: String

    public init(
        request: WebSocketHandshakeRequest,
        connection: WebSocketConnection,
        peerDescription: String
    ) {
        self.request = request
        self.connection = connection
        self.peerDescription = peerDescription
    }
}

public enum WebSocketServerError: Error, Sendable, Hashable, CustomStringConvertible {
    /// No listening-socket adapter exists for this platform yet.
    case unsupportedPlatform(String)
    case alreadyStarted
    case notStarted
    case bindFailed(String)
    case startupTimeout(seconds: Int)

    public var description: String {
        switch self {
        case .unsupportedPlatform(let detail):
            return "websocket server is unavailable on this platform: \(detail)"
        case .alreadyStarted:
            return "websocket server is already started"
        case .notStarted:
            return "websocket server has not been started"
        case .bindFailed(let detail):
            return "websocket server could not bind: \(detail)"
        case .startupTimeout(let seconds):
            return "websocket server did not become ready within \(seconds)s"
        }
    }
}

// MARK: - Server

/// A local WebSocket server.
///
/// `start()` binds and returns the port; `connections` yields each connection
/// that completed the upgrade. Handshake failures are answered with an HTTP
/// status and never reach the stream.
public actor WebSocketServer {
    public let configuration: WebSocketServerConfiguration

    private var continuation: AsyncStream<WebSocketServerConnection>.Continuation?
    private var stream: AsyncStream<WebSocketServerConnection>?
    private var started = false
    private var stopped = false
    #if canImport(Network)
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "opengrok-websocket-server")
    #endif

    public init(configuration: WebSocketServerConfiguration) {
        self.configuration = configuration
        let (stream, continuation) = AsyncStream<WebSocketServerConnection>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    /// Connections that completed the upgrade, in accept order. The stream
    /// finishes when `stop()` is called or the listener fails.
    public nonisolated var connections: AsyncStream<WebSocketServerConnection> {
        get async { await takeStream() }
    }

    private func takeStream() -> AsyncStream<WebSocketServerConnection> {
        stream ?? AsyncStream { $0.finish() }
    }

    /// Bind and begin accepting. Returns the bound port.
    @discardableResult
    public func start() async throws -> UInt16 {
        guard !started else { throw WebSocketServerError.alreadyStarted }
        started = true
        #if canImport(Network)
        return try startWithNetwork()
        #else
        // Deliberately a typed error rather than a partial implementation: an
        // epoll/`accept(2)` adapter is real work, and a server that silently
        // fails to listen is worse than one that says it cannot.
        throw WebSocketServerError.unsupportedPlatform(
            "Network.framework is unavailable and no epoll accept-loop adapter is implemented; "
                + "see WebSocketServer.swift"
        )
        #endif
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        #if canImport(Network)
        listener?.cancel()
        listener = nil
        #endif
        continuation?.finish()
        continuation = nil
    }

    #if canImport(Network)
    private func startWithNetwork() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Pinning the local endpoint is what actually makes the default bind
        // loopback-only. Without it `NWListener` accepts on every interface,
        // which would expose the agent to the network.
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.port) ?? .any
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw WebSocketServerError.bindFailed(String(describing: error))
        }
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        let outcome = ListenerOutcome()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.port = listener.port?.rawValue
                ready.signal()
            case .failed(let error):
                outcome.failure = String(describing: error)
                ready.signal()
            case .cancelled:
                outcome.failure = outcome.failure ?? "listener cancelled"
                ready.signal()
            default:
                break
            }
        }

        let handoff = self
        listener.newConnectionHandler = { connection in
            Task { await handoff.accept(NWConnectionBox(connection)) }
        }
        listener.start(queue: queue)

        let timeoutSeconds = 5
        if ready.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            listener.cancel()
            self.listener = nil
            throw WebSocketServerError.startupTimeout(seconds: timeoutSeconds)
        }
        if let failure = outcome.failure {
            listener.cancel()
            self.listener = nil
            throw WebSocketServerError.bindFailed(failure)
        }
        guard let port = outcome.port else {
            listener.cancel()
            self.listener = nil
            throw WebSocketServerError.bindFailed("listener became ready without a port")
        }
        return port
    }

    private func accept(_ box: NWConnectionBox) async {
        guard !stopped, let continuation else {
            box.value.cancel()
            return
        }
        let channel = NWConnectionByteChannel(box.value, queue: queue)
        await channel.start()
        let policy = configuration.policy
        let maximumMessageSize = configuration.maximumMessageSize
        let peer = String(describing: box.value.endpoint)
        // The upgrade runs off the accept path so one slow or hostile client
        // cannot stall the listener.
        Task {
            do {
                let upgraded = try await WebSocketServerUpgrade.perform(channel: channel, policy: policy)
                let connection = WebSocketConnection(
                    channel: channel,
                    role: .server,
                    maximumMessageSize: maximumMessageSize,
                    initialBytes: upgraded.leftover
                )
                continuation.yield(
                    WebSocketServerConnection(
                        request: upgraded.request,
                        connection: connection,
                        peerDescription: peer
                    )
                )
            } catch {
                // `perform` already wrote the HTTP status and closed.
                await channel.close()
            }
        }
    }
    #endif
}

/// Dialling the other side of a `WebSocketServer`.
///
/// This is the client complement of the listener and shares its platform
/// guard. `URLSessionWebSocketClient` already covers ordinary outbound
/// WebSocket use; this exists for callers that need the raw byte channel —
/// notably anything that must speak the exact frames, and the tests that drive
/// a live `open-grok serve` endpoint.
public enum WebSocketNetworkChannel {
    public static func connect(host: String, port: UInt16) async throws -> any WebSocketByteChannel {
        #if canImport(Network)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        let channel = NWConnectionByteChannel(
            connection,
            queue: DispatchQueue(label: "opengrok-websocket-client")
        )
        await channel.start()
        return channel
        #else
        throw WebSocketServerError.unsupportedPlatform(
            "Network.framework is unavailable and no BSD-socket dialer is implemented"
        )
        #endif
    }
}

#if canImport(Network)

/// Mutable box for the listener's readiness handoff, touched only between
/// `listener.start` and the semaphore signal.
private final class ListenerOutcome: @unchecked Sendable {
    var port: UInt16?
    var failure: String?
}

/// One-shot handoff between a `Network.framework` state callback and an
/// awaiting continuation.
///
/// Both sides race: the callback can fire before `attach`, and `attach` can
/// land before any state arrives. Whichever is second delivers. `finish` is
/// idempotent because `stateUpdateHandler` fires repeatedly and resuming a
/// continuation twice traps.
final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        outcome = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}

/// `NWConnection` predates `Sendable` annotation in some SDKs; the box keeps
/// the actor boundary honest without weakening anything else.
private struct NWConnectionBox: @unchecked Sendable {
    let value: NWConnection
    init(_ value: NWConnection) { self.value = value }
}

/// `WebSocketByteChannel` over an `NWConnection`.
///
/// Reads are one-at-a-time by construction: `WebSocketConnection` is an actor
/// and calls `read()` from a single serialized context.
final class NWConnectionByteChannel: WebSocketByteChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var closed = false

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() async {
        connection.start(queue: queue)
    }

    /// Start and block until the connection is usable, or fail.
    ///
    /// `start()` alone only hands the connection to the queue, so a refused or
    /// unroutable endpoint shows up later as an end-of-stream in the middle of
    /// the handshake. Production dialling needs the failure at dial time, with
    /// the endpoint named — hence the readiness wait and the bounded timeout.
    func startAndWaitReady(timeoutSeconds: Double) async throws {
        let endpointDescription = String(describing: connection.endpoint)
        let gate = ContinuationGate()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                gate.finish(.success(()))
            case .failed(let error):
                gate.finish(.failure(WebSocketDialError.connectionFailed(
                    url: endpointDescription,
                    reason: String(describing: error)
                )))
            case .cancelled:
                gate.finish(.failure(WebSocketDialError.connectionFailed(
                    url: endpointDescription,
                    reason: "connection cancelled before it became ready"
                )))
            case .setup, .preparing, .waiting:
                // `.waiting` is retryable by design (DNS still resolving, path
                // not yet satisfied); the timeout is what bounds it.
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)

        // The timeout resolves the same gate rather than throwing from a
        // sibling task: a task group would have to await both children, so a
        // throwing timeout task would park forever on the continuation task it
        // was meant to pre-empt.
        let deadline = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
        let timeout = Task {
            try? await Task.sleep(nanoseconds: deadline)
            guard !Task.isCancelled else { return }
            gate.finish(.failure(WebSocketDialError.connectTimeout(
                seconds: timeoutSeconds,
                url: endpointDescription
            )))
        }
        defer {
            timeout.cancel()
            connection.stateUpdateHandler = nil
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.attach(continuation)
        }
    }

    func read() async throws -> [UInt8]? {
        if isClosed { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: Array(data))
                    return
                }
                // No data and complete means EOF; no data and not complete is
                // a spurious wakeup, reported as an empty chunk so the caller
                // loops rather than treating it as end of stream.
                continuation.resume(returning: isComplete ? nil : [])
            }
        }
    }

    func write(_ bytes: [UInt8]) async throws {
        if isClosed { throw WebSocketChannelError.closed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(bytes),
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    func close() async {
        guard markClosed() else { return }
        connection.cancel()
    }

    /// Flip the closed flag, returning whether this call was the one that did
    /// it. Synchronous because `NSLock` is unavailable from an async context.
    private func markClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        closed = true
        return true
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
}

#endif
