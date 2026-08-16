// ACPServeHost.swift
//
// Serving ACP over a WebSocket, which is what `open-grok serve` is.
//
// The framing is identical to stdio — one JSON-RPC 2.0 object per message —
// so `ACPAgentRuntime` is reused untouched. What changes is the carrier: each
// WebSocket text frame carries exactly one line that stdio would have written,
// and the connection can come and go without ending the process.
//
// Rust reference (`/Users/mweinbach/Projects/grok-build`),
// `crates/codegen/xai-grok-shell/src/agent/server.rs`:
//
//   * `:219-232` — a text frame's trailing CR/LF is trimmed, and the literal
//     text `ping` or an empty frame is skipped rather than parsed. Browser
//     clients send `ping` as an application-level keepalive; treating it as
//     JSON would fail every 15 seconds.
//   * `:233-243` — a binary frame is decoded as UTF-8 and handled exactly like
//     a text frame.
//   * `:255-262` — outbound, each agent line becomes one text frame, with
//     empty lines dropped.
//   * `:263-270` — the server pings every `KEEPALIVE_INTERVAL_SECS` (15).
//   * `:293-343` — one agent instance is created on first connect and reused
//     across reconnects, so session state survives a client disconnect.
//   * `:92-126` — auth: `Authorization: Bearer <secret>`, else `?server-key=`.
//   * `:469-485` — exactly one route, `GET /ws`.

import Foundation
import OpenGrokHTTP
import OpenGrokShared

// MARK: - Transport

/// `ACPTransport` over one `WebSocketConnection`.
///
/// The message-level quirks upstream applies on the way in (CR/LF trimming,
/// skipping the literal `ping`, decoding binary as text) are applied here, so
/// the runtime above sees the same clean `ACPMessage` stream stdio produces.
///
/// Role-agnostic on purpose: the server wraps its accepted connection in one
/// of these, and an ACP *client* over WebSocket wraps its dialled connection
/// in the same type. Distinct from `ACPWebSocketTransport`, which sits on the
/// URLSession-backed `WebSocketClient` and cannot serve.
public struct ACPWebSocketConnectionTransport: ACPTransport {
    private let connection: any WebSocketClient

    public init(connection: any WebSocketClient) {
        self.connection = connection
    }

    public func send(_ message: ACPMessage) async throws {
        let data = try message.encodedData()
        try await connection.send(.text(String(decoding: data, as: UTF8.self)))
    }

    public func receive() async throws -> ACPMessage {
        while true {
            guard let message = try await connection.receive() else {
                throw ACPTransportError.closed
            }
            let text: String
            switch message {
            case .text(let value):
                text = value
            case .data(let data):
                // `server.rs:233-243`: a binary frame that is not UTF-8 is
                // dropped, not an error.
                guard let value = String(data: data, encoding: .utf8) else { continue }
                text = value
            }
            guard let payload = Self.normalize(text) else { continue }
            guard let data = payload.data(using: .utf8) else {
                throw ACPTransportError.unsupportedPayload
            }
            return try ACPMessage(data: data)
        }
    }

    public func close() async {
        await connection.close(code: 1000, reason: "ACP runtime closed")
    }

    /// Upstream's inbound filter (`server.rs:222-227`): trim trailing CR/LF,
    /// then skip the literal `ping` and empty frames. Returns `nil` for a
    /// frame that should be ignored.
    /// Trimming runs over UTF-8 bytes rather than `Character`s on purpose:
    /// Swift treats CRLF as a *single* grapheme cluster, so a `Character`
    /// comparison against `"\r"` or `"\n"` silently fails to match a line
    /// ending with `\r\n` — which is the exact ending this is here to strip.
    static func normalize(_ text: String) -> String? {
        var bytes = Array(text.utf8)
        while let last = bytes.last, last == UInt8(ascii: "\r") || last == UInt8(ascii: "\n") {
            bytes.removeLast()
        }
        if bytes.isEmpty || bytes == Array("ping".utf8) { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Authorization

/// The auth check upstream performs before upgrading (`server.rs:92-106`).
///
/// The order is load-bearing and copied deliberately: when an `Authorization`
/// header is present, its token decides — a wrong bearer token is *not*
/// rescued by a correct `?server-key=`. Only an absent (or non-Bearer) header
/// falls through to the query parameter.
public struct ACPServeAuthorization: Sendable {
    public static let queryParameterName = "server-key"

    public let secret: String

    public init(secret: String) {
        self.secret = secret
    }

    public func authorize(_ request: WebSocketHandshakeRequest) -> Bool {
        if let token = request.bearerToken {
            return Self.constantTimeEquals(token, secret)
        }
        guard let key = request.queryItems[Self.queryParameterName] else { return false }
        return Self.constantTimeEquals(key, secret)
    }

    /// Compares without an early exit. Upstream uses `==` on a `String`; this
    /// is the same decision with the timing signal removed, which cannot
    /// change any accept/reject outcome.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        let count = min(left.count, right.count)
        for index in 0..<count { difference |= left[index] ^ right[index] }
        return difference == 0 && left.count == right.count
    }
}

// MARK: - Configuration

public struct ACPServeConfiguration: Sendable {
    /// Interface to bind. Upstream's default is `127.0.0.1`
    /// (`crates/codegen/xai-grok-pager/src/app/cli.rs:337`).
    public var host: String
    /// Upstream's default port (same line).
    public var port: UInt16
    /// Upstream mounts exactly one route (`server.rs:470`).
    public var path: String
    /// Required. Upstream auto-generates one when `--secret` is absent and
    /// prints it; it is never optional at the server.
    public var secret: String
    /// Upstream's `MAX_BUFFER_SIZE` (`server.rs:56`).
    public var maximumMessageSize: Int
    /// Seconds between keepalive pings — upstream's `KEEPALIVE_INTERVAL_SECS`
    /// (`server.rs:57`). `nil` disables. Spelled as a `TimeInterval` rather
    /// than a `Duration` because the package deploys to macOS 12 and
    /// `Duration` is 13+.
    public var keepAliveInterval: TimeInterval?

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 2419,
        path: String = "/ws",
        secret: String,
        maximumMessageSize: Int = WebSocketLimits.defaultMaximumMessageSize,
        keepAliveInterval: TimeInterval? = TimeInterval(WebSocketLimits.keepAliveIntervalSeconds)
    ) {
        self.host = host
        self.port = port
        self.path = path
        self.secret = secret
        self.maximumMessageSize = maximumMessageSize
        self.keepAliveInterval = keepAliveInterval
    }
}

/// Where the server actually bound, after an ephemeral port is resolved.
public struct ACPServeEndpoint: Sendable, Hashable {
    public var host: String
    public var port: UInt16
    public var path: String

    public init(host: String, port: UInt16, path: String) {
        self.host = host
        self.port = port
        self.path = path
    }

    public var address: String { "\(host):\(port)" }
    public var url: String { "ws://\(host):\(port)\(path)" }

    /// The URL upstream prints for the operator to paste
    /// (`crates/codegen/xai-grok-pager-bin/src/main.rs:97-100`).
    public func url(withSecret secret: String) -> String {
        "\(url)?\(ACPServeAuthorization.queryParameterName)=\(secret)"
    }
}

// MARK: - Host

/// Runs the ACP agent over a WebSocket endpoint until stopped.
///
/// The runtime factory is injected rather than constructed here: the runtime
/// needs a prompt driver built from the live sampler/provider stack, which
/// only the CLI composition can assemble. Sharing one session store across the
/// runtimes the factory returns is what makes reconnects resume rather than
/// restart — see `LiveServeComposition`.
public actor ACPServeHost {
    public typealias RuntimeFactory = @Sendable () async throws -> ACPAgentRuntime

    public let configuration: ACPServeConfiguration

    private let makeRuntime: RuntimeFactory
    private let log: @Sendable (String) -> Void
    private var server: WebSocketServer?
    private var endpoint: ACPServeEndpoint?
    private var activeRuntime: ACPAgentRuntime?
    private var activeTransport: ACPWebSocketConnectionTransport?
    private var stopped = false

    public init(
        configuration: ACPServeConfiguration,
        makeRuntime: @escaping RuntimeFactory,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.makeRuntime = makeRuntime
        self.log = log
    }

    /// Bind and return the resolved endpoint. Separate from `run()` so the CLI
    /// can print the banner with the real port before the accept loop starts.
    @discardableResult
    public func start() async throws -> ACPServeEndpoint {
        let authorization = ACPServeAuthorization(secret: configuration.secret)
        let policy = WebSocketUpgradePolicy(path: configuration.path) { request in
            authorization.authorize(request)
        }
        let server = WebSocketServer(
            configuration: WebSocketServerConfiguration(
                host: configuration.host,
                port: configuration.port,
                policy: policy,
                maximumMessageSize: configuration.maximumMessageSize
            )
        )
        let boundPort = try await server.start()
        let endpoint = ACPServeEndpoint(
            host: configuration.host,
            port: boundPort,
            path: configuration.path
        )
        self.server = server
        self.endpoint = endpoint
        return endpoint
    }

    /// Accept connections until `stop()`.
    ///
    /// Connections are served one at a time and the newest wins: a second
    /// client closes the first. That matches upstream's observable behaviour —
    /// `setup_acp_connection` (`server.rs:342`) repoints the relay at the new
    /// connection, so the previous client stops receiving notifications — but
    /// says so on the wire with a close frame instead of leaving the old
    /// client connected to a channel nothing writes to.
    public func run() async {
        guard let server else {
            log("serve: run() called before start()")
            return
        }
        let stream = await server.connections
        for await accepted in stream {
            if stopped {
                await accepted.connection.close(code: 1001, reason: "server shutting down")
                continue
            }
            await replaceActiveConnection()
            log("serve: client connected from \(accepted.peerDescription)")
            await serveConnection(accepted)
            log("serve: client disconnected from \(accepted.peerDescription)")
            if stopped { break }
        }
        await replaceActiveConnection()
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        await server?.stop()
        await replaceActiveConnection()
        server = nil
    }

    public func boundEndpoint() -> ACPServeEndpoint? { endpoint }

    // MARK: internals

    private func serveConnection(_ accepted: WebSocketServerConnection) async {
        let runtime: ACPAgentRuntime
        do {
            runtime = try await makeRuntime()
        } catch {
            log("serve: could not build the agent runtime: \(error)")
            // The client is told why rather than seeing a socket that accepts
            // and then goes silent.
            await accepted.connection.close(
                code: 1011,
                reason: "agent runtime unavailable: \(error)"
            )
            return
        }
        let transport = ACPWebSocketConnectionTransport(connection: accepted.connection)
        activeRuntime = runtime
        activeTransport = transport

        let keepAlive = makeKeepAliveTask(for: accepted.connection)
        await runtime.serve(transport)
        keepAlive?.cancel()

        if activeRuntime === runtime {
            activeRuntime = nil
            activeTransport = nil
        }
        await runtime.close()
    }

    /// Upstream pings every 15s to keep intermediaries from idling the
    /// connection out (`server.rs:263-269`, empty payload).
    private func makeKeepAliveTask(for connection: WebSocketConnection) -> Task<Void, Never>? {
        guard let interval = configuration.keepAliveInterval, interval > 0 else { return nil }
        let nanoseconds = UInt64(interval * 1_000_000_000)
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

    private func replaceActiveConnection() async {
        if let runtime = activeRuntime {
            await runtime.close()
            activeRuntime = nil
        }
        if let transport = activeTransport {
            await transport.close()
            activeTransport = nil
        }
    }
}
