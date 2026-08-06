// UnixSocketListener.swift
//
// A Unix-domain-socket accept loop producing `WebSocketByteChannel`s.
//
// It lives in `OpenGrokHTTP` rather than beside its one caller because
// `NWConnectionByteChannel` — the adapter every byte channel here is built on —
// is internal to this target, and because this is socket plumbing with no
// protocol opinion: the bytes it yields are not WebSocket bytes, they are
// whatever the peer sends. The leader IPC envelope is layered on top by
// `OpenGrokACPRuntime`.
//
// Network.framework remains the Apple implementation; the C adapter below
// supplies POSIX sockets on non-Network Unix platforms.

import Foundation

#if canImport(Network)
import Network
#endif

public enum UnixSocketListenerError: Error, Sendable, Hashable, CustomStringConvertible {
    case unsupportedPlatform(String)
    case pathTooLong(path: String, limit: Int)
    case bindFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case .unsupportedPlatform(let detail):
            return "cannot listen on a Unix socket on this platform: \(detail)"
        case .pathTooLong(let path, let limit):
            return
                "socket path is \(path.utf8.count) bytes, over the \(limit) byte sockaddr_un limit: "
                + path
        case .bindFailed(let path, let reason):
            return "could not bind the Unix socket at \(path): \(reason)"
        }
    }
}

public actor UnixSocketListener {
    /// `sockaddr_un.sun_path` is 104 bytes on Darwin and 108 on Linux, both
    /// including the terminator. `bind(2)` truncates silently rather than
    /// failing, which would leave a listener at a path nobody dials, so the
    /// smaller limit is enforced up front.
    public static let maximumPathLength = 103

    public let path: String
    private var started = false
    private var stream: AsyncStream<any WebSocketByteChannel>?

    #if canImport(Network)
    private var listener: NWListener?
    private var continuation: AsyncStream<any WebSocketByteChannel>.Continuation?
    private let queue = DispatchQueue(label: "opengrok-unix-socket")
    #else
    private var listener: PortableSocketListener?
    private var continuation: AsyncStream<any WebSocketByteChannel>.Continuation?
    private var acceptTask: Task<Void, Never>?
    #endif

    public init(path: String) {
        self.path = path
    }

    /// Bind and start accepting; the stream yields one channel per client.
    ///
    /// Returns only once the listener is actually bound. `NWListener.start` is
    /// asynchronous and the socket file does not appear until the listener
    /// reaches `.ready`, so returning early would mean announcing a socket
    /// address that nothing is listening on yet — a client that dialled
    /// immediately would be refused.
    ///
    /// The caller is responsible for having removed any stale socket file and
    /// for holding whatever lock makes that removal safe — this type has no way
    /// to tell a crashed leader's leftover socket from a live one's.
    @discardableResult
    public func start(readyTimeoutSeconds: Double = 5) async throws -> AsyncStream<any WebSocketByteChannel> {
        if let stream, started { return stream }
        guard path.utf8.count <= Self.maximumPathLength else {
            throw UnixSocketListenerError.pathTooLong(
                path: path,
                limit: Self.maximumPathLength
            )
        }

        #if canImport(Network)
        let parameters = NWParameters()
        parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw UnixSocketListenerError.bindFailed(
                path: path,
                reason: String(describing: error)
            )
        }

        var escaped: AsyncStream<any WebSocketByteChannel>.Continuation?
        let stream = AsyncStream<any WebSocketByteChannel> { escaped = $0 }
        let continuation = escaped
        let queue = self.queue

        listener.newConnectionHandler = { connection in
            let channel = NWConnectionByteChannel(connection, queue: queue)
            connection.start(queue: queue)
            continuation?.yield(channel)
        }

        let gate = ContinuationGate()
        let socketPath = path
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                gate.finish(.success(()))
            case .failed(let error):
                gate.finish(.failure(UnixSocketListenerError.bindFailed(
                    path: socketPath,
                    reason: String(describing: error)
                )))
            case .cancelled:
                gate.finish(.failure(UnixSocketListenerError.bindFailed(
                    path: socketPath,
                    reason: "listener cancelled before it became ready"
                )))
            case .setup, .waiting:
                break
            @unknown default:
                break
            }
        }
        listener.start(queue: queue)

        // The deadline resolves the same gate rather than throwing from a
        // sibling task; see `NWConnectionByteChannel.startAndWaitReady`.
        let deadline = Task { [readyTimeoutSeconds] in
            try? await Task.sleep(
                nanoseconds: UInt64(max(0, readyTimeoutSeconds) * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            gate.finish(.failure(UnixSocketListenerError.bindFailed(
                path: socketPath,
                reason: "listener did not become ready within \(Int(readyTimeoutSeconds))s"
            )))
        }
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                gate.attach(continuation)
            }
            deadline.cancel()
        } catch {
            deadline.cancel()
            listener.cancel()
            continuation?.finish()
            throw error
        }

        self.listener = listener
        self.continuation = continuation
        self.stream = stream
        started = true
        return stream
        #else
        let listener: PortableSocketListener
        do {
            listener = try PortableSocketListener.unix(path: path)
        } catch let error as PortableSocketError {
            throw UnixSocketListenerError.bindFailed(path: path, reason: error.description)
        }
        let (stream, continuation) = AsyncStream<any WebSocketByteChannel>.makeStream()
        self.listener = listener
        self.continuation = continuation
        self.stream = stream
        started = true
        acceptTask = Task { [weak self, listener] in
            while !Task.isCancelled {
                do {
                    let channel = try await listener.accept()
                    await self?.yield(channel)
                } catch {
                    break
                }
            }
        }
        return stream
        #endif
    }

    public func stop() async {
        #if canImport(Network)
        listener?.cancel()
        listener = nil
        continuation?.finish()
        continuation = nil
        #else
        acceptTask?.cancel()
        acceptTask = nil
        listener?.close()
        listener = nil
        continuation?.finish()
        continuation = nil
        #endif
        stream = nil
        started = false
    }

    #if !canImport(Network)
    private func yield(_ channel: any WebSocketByteChannel) {
        guard started, let continuation else {
            Task { await channel.close() }
            return
        }
        continuation.yield(channel)
    }
    #endif
}

/// Dialling the other side of a `UnixSocketListener`.
///
/// The client half of leader IPC: a TUI, an IDE or a `-p` run connects here to
/// share the leader's agent instead of starting its own.
public enum UnixSocketDialer {
    public static func connect(
        path: String,
        connectTimeoutSeconds: Double = 5
    ) async throws -> any WebSocketByteChannel {
        #if canImport(Network)
        let parameters = NWParameters()
        parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        let connection = NWConnection(to: NWEndpoint.unix(path: path), using: parameters)
        let channel = NWConnectionByteChannel(
            connection,
            queue: DispatchQueue(label: "opengrok-unix-dial")
        )
        do {
            try await channel.startAndWaitReady(timeoutSeconds: connectTimeoutSeconds)
        } catch {
            await channel.close()
            // A refused Unix socket almost always means "no leader is running",
            // which is a different situation from a network failure and is
            // worth naming at the point it is detected.
            throw UnixSocketListenerError.bindFailed(
                path: path,
                reason: "could not connect (no listener?): \(error)"
            )
        }
        return channel
        #else
        do {
            return try await PortableSocketConnector.unix(
                path: path,
                timeoutSeconds: connectTimeoutSeconds
            )
        } catch let error as PortableSocketError {
            throw UnixSocketListenerError.bindFailed(path: path, reason: error.description)
        }
        #endif
    }
}
