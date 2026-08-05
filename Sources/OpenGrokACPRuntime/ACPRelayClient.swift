// ACPRelayClient.swift
//
// The outbound half of leader mode: a WebSocket *client* that dials a remote
// ACP endpoint and hands the socket to a local `ACPAgentRuntime`.
//
// This is the mirror image of `ACPServeHost`. Serve listens and lets a client
// dial in; the relay dials out and lets the far side drive. The agent runtime
// is identical either way — same prompt driver, same `session/update` fan-out,
// same cancellation — which is exactly why `ACPWebSocketConnectionTransport`
// was written role-agnostic.
//
// Rust reference: `crates/codegen/xai-grok-shell/src/agent/relay.rs`.
// `build_relay_request` (:370-397) for headers, `KEEPALIVE_INTERVAL_SECS = 15`
// (:19), `READ_LIVENESS_TIMEOUT_SECS = 4 * KEEPALIVE` = 60 (:31),
// `CONNECT_TIMEOUT_SECS = 30` (:44), `AUTH_ERROR_CODE = -32000` (:46), and
// `run_relay_loop` (:251-360) for the reconnect loop.

import Foundation
import OpenGrokHTTP
import OpenGrokShared

// MARK: - Configuration

/// The relay's auth material.
///
/// Upstream only builds a `RelayConfig` when the session is x.ai-issuer OIDC
/// with a non-empty key (`relay.rs:64-81`); BYOK / API-key / external logins
/// get no relay at all and the leader still serves local clients. That gate is
/// represented here by this value being optional on the configuration.
public struct ACPRelayAuthorization: Sendable, Hashable {
    /// Sent as `Authorization: Bearer <token>`.
    public var token: String
    /// Sent as `x-userid`.
    public var userID: String
    /// Sent as `X-XAI-Token-Auth`. `auth/config.rs:292` defaults it to
    /// `xai-grok-cli`.
    public var tokenHeader: String

    public init(token: String, userID: String, tokenHeader: String = "xai-grok-cli") {
        self.token = token
        self.userID = userID
        self.tokenHeader = tokenHeader
    }
}

public struct ACPRelayConfiguration: Sendable {
    /// `xai-grok-env/src/lib.rs:25` — `PROD_RELAY_WS_URL`.
    public static let productionURL = "wss://code.grok.com/ws/code-agent"
    /// `xai-grok-env/src/lib.rs:26` — the `Origin` header value.
    public static let productionOrigin = "https://grok.com"

    public var url: WebSocketURL
    public var origin: String
    public var authorization: ACPRelayAuthorization?
    /// `x-grok-client-version`.
    public var clientVersion: String
    /// `x-grok-client-mode`, `xai-grok-http/src/lib.rs:284-299`. A leader is
    /// headless: it has no terminal of its own.
    public var clientMode: String
    public var connectTimeoutSeconds: Double
    /// `nil` disables the client ping entirely, which is what tests want so a
    /// 15s timer cannot race a short assertion.
    public var keepAliveSeconds: Double?
    /// `nil` disables the half-open watchdog.
    public var readLivenessSeconds: Double?
    public var reconnect: WebSocketReconnectPolicy
    public var maximumMessageSize: Int

    public init(
        url: WebSocketURL,
        origin: String = ACPRelayConfiguration.productionOrigin,
        authorization: ACPRelayAuthorization? = nil,
        clientVersion: String = "0.0.0",
        clientMode: String = "headless",
        connectTimeoutSeconds: Double = 30,
        keepAliveSeconds: Double? = 15,
        readLivenessSeconds: Double? = 60,
        reconnect: WebSocketReconnectPolicy = .relay,
        maximumMessageSize: Int = WebSocketLimits.defaultMaximumMessageSize
    ) {
        self.url = url
        self.origin = origin
        self.authorization = authorization
        self.clientVersion = clientVersion
        self.clientMode = clientMode
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.keepAliveSeconds = keepAliveSeconds
        self.readLivenessSeconds = readLivenessSeconds
        self.reconnect = reconnect
        self.maximumMessageSize = maximumMessageSize
    }

    /// The handshake headers, in upstream's order (`relay.rs:370-397`).
    ///
    /// Header *names* are what a relay authenticates on, so they are spelled
    /// exactly as upstream sends them.
    public var handshakeHeaders: [(String, String)] {
        var headers: [(String, String)] = [("Origin", origin)]
        if let authorization {
            headers.append(("Authorization", "Bearer \(authorization.token)"))
            headers.append(("X-XAI-Token-Auth", authorization.tokenHeader))
            headers.append(("x-userid", authorization.userID))
        }
        headers.append(("x-grok-client-version", clientVersion))
        headers.append(("x-grok-client-mode", clientMode))
        return headers
    }
}

// MARK: - Session outcome

public enum ACPRelayEndReason: Sendable, Hashable, CustomStringConvertible {
    /// The far side closed cleanly or the stream ended.
    case remoteClosed
    /// An in-band JSON-RPC error with code -32000 (`relay.rs:46, 526-535`).
    case authError
    /// No traffic inside the liveness window — a half-open leg through a NAT
    /// or proxy (`relay.rs:489-508`).
    case readLivenessTimeout
    case cancelled
    case transportFailure(String)

    public var description: String {
        switch self {
        case .remoteClosed: return "remote closed the connection"
        case .authError: return "relay rejected the session (JSON-RPC -32000)"
        case .readLivenessTimeout: return "no relay traffic within the liveness window"
        case .cancelled: return "cancelled"
        case .transportFailure(let detail): return "transport failure: \(detail)"
        }
    }
}

// MARK: - Transport

/// `ACPWebSocketConnectionTransport` plus the two behaviours the relay adds on
/// top of plain ACP framing: the half-open read watchdog, and the in-band
/// error filter.
///
/// The error filter matches `relay.rs:511-547` exactly, including the part that
/// looks wrong at first glance: a JSON-RPC response carrying *any* `error` is
/// dropped rather than delivered to the agent. -32000 additionally ends the
/// session as an auth failure. This does mean a reverse request answered with
/// an error never resolves locally, which is upstream's behaviour and is why
/// `ACPReverseRequestBroker` requests must stay cancellable.
public struct ACPRelayTransport: ACPTransport {
    private let inner: ACPWebSocketConnectionTransport
    private let readLivenessSeconds: Double?
    private let outcome: ACPRelayOutcomeBox
    private let log: @Sendable (String) -> Void

    init(
        connection: WebSocketConnection,
        readLivenessSeconds: Double?,
        outcome: ACPRelayOutcomeBox,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.inner = ACPWebSocketConnectionTransport(connection: connection)
        self.readLivenessSeconds = readLivenessSeconds
        self.outcome = outcome
        self.log = log
    }

    public func send(_ message: ACPMessage) async throws {
        try await inner.send(message)
    }

    public func receive() async throws -> ACPMessage {
        while true {
            let message = try await receiveWithLiveness()
            if case .response(let id, _, let error) = message, let error {
                if error.code.code == ACPRelayTransport.authErrorCode {
                    await outcome.record(.authError)
                    log("relay: authentication rejected (\(error.message)); ending session")
                    throw ACPTransportError.closed
                }
                // Upstream drops these rather than forwarding
                // (`relay.rs:536-545`), so the id is logged to keep an
                // unresolvable reverse request diagnosable.
                log("relay: server error \(error.code.code) for id \(id) (skipping): \(error.message)")
                continue
            }
            return message
        }
    }

    /// Read, bounded by the liveness window.
    ///
    /// Not a task group, for the same reason as `ACPLeaderIPCHost.withTimeout`:
    /// a group awaits every child, and a socket read parked in
    /// `NWConnection.receive` does not observe cancellation, so a throwing
    /// timeout child would deadlock on the read it exists to pre-empt. The
    /// abandoned read is released when `close()` cancels the connection, which
    /// the reconnect loop does before redialling.
    private func receiveWithLiveness() async throws -> ACPMessage {
        guard let readLivenessSeconds else {
            return try await inner.receive()
        }
        let deadline = UInt64(max(0, readLivenessSeconds) * 1_000_000_000)
        let inner = self.inner
        let outcome = self.outcome
        let gate = AsyncOutcomeGate<ACPMessage>()
        let work = Task.detached {
            do {
                gate.finish(.success(try await inner.receive()))
            } catch {
                gate.finish(.failure(error))
            }
        }
        let timer = Task.detached {
            try? await Task.sleep(nanoseconds: deadline)
            guard !Task.isCancelled else { return }
            await outcome.record(.readLivenessTimeout)
            gate.finish(.failure(ACPTransportError.closed))
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        return try await gate.value()
    }

    public func close() async {
        await inner.close()
    }

    /// `relay.rs:46` — `AUTH_ERROR_CODE: i64 = -32000`. Spelled as the integer
    /// rather than `AcpErrorCode.authRequired` because the relay matches on the
    /// wire number, not on any ACP-level meaning.
    static let authErrorCode: Int32 = -32000
}

/// Why the current relay session ended, written by whichever part noticed.
actor ACPRelayOutcomeBox {
    private var reason: ACPRelayEndReason?

    func record(_ reason: ACPRelayEndReason) {
        // First writer wins: the liveness watchdog and the read loop both fire
        // when a connection dies, and the first one to notice has the real
        // cause.
        guard self.reason == nil else { return }
        self.reason = reason
    }

    func take() -> ACPRelayEndReason {
        defer { reason = nil }
        return reason ?? .remoteClosed
    }
}

// MARK: - Client

public actor ACPRelayClient {
    public typealias RuntimeProvider = @Sendable () async throws -> ACPAgentRuntime

    public let configuration: ACPRelayConfiguration
    private let makeRuntime: RuntimeProvider
    private let log: @Sendable (String) -> Void

    private var stopped = false
    private var activeConnection: WebSocketConnection?
    private var connectionCount = 0
    private var lastEndReason: ACPRelayEndReason?

    public init(
        configuration: ACPRelayConfiguration,
        makeRuntime: @escaping RuntimeProvider,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.makeRuntime = makeRuntime
        self.log = log
    }

    /// Number of successful relay connections so far. Observable so a
    /// reconnect test can wait for the *second* one rather than sleeping.
    public func successfulConnectionCount() -> Int { connectionCount }
    public func mostRecentEndReason() -> ACPRelayEndReason? { lastEndReason }

    /// Dial, serve, reconnect — until `stop()` or a terminal refusal.
    ///
    /// The runtime is built once and reused across reconnects: upstream keeps
    /// one long-lived agent process behind the relay, so session state must
    /// outlive any single socket (`app.rs:833-835` — remote clients recover by
    /// re-`initialize`-ing and replaying with `session/load`).
    public func run() async {
        let runtime: ACPAgentRuntime
        do {
            runtime = try await makeRuntime()
        } catch {
            log("relay: agent runtime unavailable: \(error)")
            return
        }

        var attempt = 0
        while !stopped {
            let outcome = ACPRelayOutcomeBox()
            do {
                let connection = try await dial()
                if stopped {
                    await connection.close(code: 1001, reason: "leader shutting down")
                    return
                }
                activeConnection = connection
                connectionCount += 1
                attempt = 0
                log("relay: connected to \(configuration.url.absoluteString)")

                let keepAlive = startKeepAlive(on: connection)
                let transport = ACPRelayTransport(
                    connection: connection,
                    readLivenessSeconds: configuration.readLivenessSeconds,
                    outcome: outcome,
                    log: log
                )
                await Self.pump(transport: transport, runtime: runtime)
                keepAlive?.cancel()
                activeConnection = nil
            } catch {
                await outcome.record(.transportFailure(String(describing: error)))
                log("relay: connection to \(configuration.url.absoluteString) failed: \(error)")
            }

            let reason = stopped ? ACPRelayEndReason.cancelled : await outcome.take()
            lastEndReason = reason
            if stopped { return }
            log("relay: disconnected (\(reason))")

            if reason == .authError, configuration.authorization == nil {
                // Nothing to refresh, so retrying would spin against a wall.
                log(
                    "relay: no credentials to refresh; not reconnecting. "
                        + "Run `open-grok login` and restart the leader."
                )
                return
            }

            attempt += 1
            guard configuration.reconnect.shouldRetry(afterAttempt: attempt - 1) else {
                log("relay: giving up after \(attempt - 1) reconnect attempts")
                return
            }
            let nanoseconds = configuration.reconnect.delayNanoseconds(forAttempt: attempt)
            log(
                "relay: reconnecting in \(configuration.reconnect.delaySeconds(forAttempt: attempt))s "
                    + "(attempt #\(attempt))"
            )
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
        }
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        if let activeConnection {
            await activeConnection.close(code: 1001, reason: "leader shutting down")
        }
        activeConnection = nil
    }

    /// Drive one relay connection against the runtime.
    ///
    /// Deliberately *not* `ACPAgentRuntime.serve`, even though the body is
    /// nearly the same. `serve` treats a transport error as fatal to the
    /// runtime — it calls `close()`, which cancels every prompt and latches the
    /// state to `.closed` (`ACPRuntimeActor.swift:119-127, 160-166`). That is
    /// right for stdio, where losing the transport means the process is done,
    /// and wrong for a relay, where a dropped leg is routine and the agent must
    /// outlive it. Using `serve` here made the runtime dead after the first
    /// disconnect: every later dial returned instantly and closed its own
    /// socket, so the leader reconnected forever while answering nothing.
    ///
    /// Upstream has no equivalent hazard because its agent is a separate
    /// process the relay merely pipes to (`app.rs:1346-1388`).
    private static func pump(transport: ACPRelayTransport, runtime: ACPAgentRuntime) async {
        let writer = ACPRelayTransportWriter(transport: transport)
        await runtime.setNotificationSink { message in
            try? await writer.send(message)
        }
        await runtime.setReverseSender { message in
            try await writer.send(message)
        }
        // Each inbound message goes on its own child task, for the same reason
        // as `ACPAgentRuntime.serve`: `session/prompt` does not return until
        // the driver finishes, so a sequential loop could never read the
        // `session/cancel` meant to interrupt it.
        await withTaskGroup(of: Void.self) { group in
            do {
                while true {
                    let incoming = try await transport.receive()
                    group.addTask {
                        for message in await runtime.handle(incoming) {
                            try? await writer.send(message)
                        }
                    }
                }
            } catch {
                // End of connection. The runtime is left intact on purpose;
                // the reconnect loop dials again and the far side re-runs
                // `initialize`, which is how upstream recovers too
                // (`app.rs:833-835`).
            }
        }
        await runtime.setNotificationSink(nil)
        await runtime.setReverseSender(nil)
        await transport.close()
    }

    private func dial() async throws -> WebSocketConnection {
        try await WebSocketDialer.connect(
            to: configuration.url,
            options: WebSocketDialOptions(
                headers: configuration.handshakeHeaders,
                connectTimeoutSeconds: configuration.connectTimeoutSeconds,
                maximumMessageSize: configuration.maximumMessageSize
            )
        )
    }

    /// Client-sent ping every 15s with an empty payload (`relay.rs:597, 644-650`).
    ///
    /// The client pings, not the server: this leg is the one that traverses the
    /// user's NAT, and it is the client that needs the mapping kept open.
    private func startKeepAlive(on connection: WebSocketConnection) -> Task<Void, Never>? {
        guard let seconds = configuration.keepAliveSeconds, seconds > 0 else { return nil }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        return Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                do {
                    try await connection.ping()
                } catch {
                    return
                }
            }
        }
    }
}


/// Serialises writes onto one relay transport.
///
/// An actor because the notification fan-out and the per-message reply tasks
/// send concurrently, and two interleaved sends would interleave their frames.
actor ACPRelayTransportWriter {
    private let transport: ACPRelayTransport

    init(transport: ACPRelayTransport) {
        self.transport = transport
    }

    func send(_ message: ACPMessage) async throws {
        try await transport.send(message)
    }
}
