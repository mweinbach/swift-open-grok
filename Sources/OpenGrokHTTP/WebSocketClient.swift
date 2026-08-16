// WebSocketClient.swift
//
// The dialling half: URL parsing, a TLS-capable outbound connector with a
// bounded connect timeout, and the reconnect schedule the relay uses.
//
// `WebSocketNetworkChannel.connect(host:port:)` in `WebSocketServer.swift` is
// the plaintext-loopback dialer the serve tests drive. Production leader/relay
// traffic goes to `wss://code.grok.com/ws/code-agent`, so it needs three things
// that dialer does not have: TLS, a connect timeout, and a failure surfaced at
// dial time rather than on the first read.
//
// Rust reference: `crates/codegen/xai-grok-shell/src/agent/relay.rs` —
// `build_relay_request` (:370-397) for the dial, `CONNECT_TIMEOUT_SECS = 30`
// (:44), and `run_relay_loop` (:251-360) for the backoff schedule.

import Foundation

#if canImport(Network)
import Network
#endif

// MARK: - URL

public enum WebSocketURLError: Error, Sendable, Hashable, CustomStringConvertible {
    case malformed(String)
    case unsupportedScheme(String)
    case missingHost(String)
    case invalidPort(String)

    public var description: String {
        switch self {
        case .malformed(let value):
            return "not a WebSocket URL: \(value)"
        case .unsupportedScheme(let scheme):
            return "unsupported WebSocket scheme `\(scheme)`; expected ws or wss"
        case .missingHost(let value):
            return "WebSocket URL has no host: \(value)"
        case .invalidPort(let value):
            return "WebSocket URL has an invalid port: \(value)"
        }
    }
}

/// A parsed `ws://` or `wss://` endpoint.
///
/// Kept separate from `ACPServeEndpoint`, which only ever describes a local
/// plaintext listener; a relay URL carries a scheme, a query, and a port that
/// defaults by scheme.
public struct WebSocketURL: Sendable, Hashable {
    public var isSecure: Bool
    public var host: String
    public var port: UInt16
    public var path: String
    /// Query string without the leading `?`. `nil` and `""` are distinct only
    /// in that `nil` omits the `?` entirely.
    public var query: String?

    public init(isSecure: Bool, host: String, port: UInt16, path: String = "/", query: String? = nil) {
        self.isSecure = isSecure
        self.host = host
        self.port = port
        self.path = path.isEmpty ? "/" : path
        self.query = query
    }

    /// The request target for the handshake request line.
    public var target: String {
        guard let query, !query.isEmpty else { return path }
        return path + "?" + query
    }

    /// The `Host:` header value. The port is elided when it is the scheme
    /// default, which is what every browser and `tungstenite` do — a server
    /// matching virtual hosts on `Host` will not recognise `grok.com:443`.
    public var hostHeader: String {
        let isDefaultPort = (isSecure && port == 443) || (!isSecure && port == 80)
        if isDefaultPort { return host }
        if host.contains(":") { return "[\(host)]:\(port)" }
        return "\(host):\(port)"
    }

    public var absoluteString: String {
        let scheme = isSecure ? "wss" : "ws"
        return "\(scheme)://\(hostHeader)\(target)"
    }

    /// Parse `ws://host[:port][/path][?query]`.
    ///
    /// Hand-rolled rather than `URLComponents` because `URLComponents` on Linux
    /// does not agree with Darwin about `ws:` — it is not in its list of
    /// schemes with an authority, so `host` comes back nil.
    public static func parse(_ string: String) throws -> WebSocketURL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.range(of: "://") else {
            throw WebSocketURLError.malformed(string)
        }
        let scheme = trimmed[trimmed.startIndex..<separator.lowerBound].lowercased()
        let isSecure: Bool
        switch scheme {
        case "ws": isSecure = false
        case "wss": isSecure = true
        default: throw WebSocketURLError.unsupportedScheme(scheme)
        }

        var rest = String(trimmed[separator.upperBound...])

        // Split the query off before the path so a `?` inside a query value
        // cannot be mistaken for a second delimiter.
        var query: String?
        if let mark = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: mark)...])
            rest = String(rest[rest.startIndex..<mark])
        }

        var path = "/"
        if let slash = rest.firstIndex(of: "/") {
            path = String(rest[slash...])
            rest = String(rest[rest.startIndex..<slash])
        }

        let authority = rest
        guard !authority.isEmpty else { throw WebSocketURLError.missingHost(string) }

        let host: String
        var explicitPort: UInt16?
        if authority.hasPrefix("[") {
            // IPv6 literal: the colon that separates the port is the one after
            // the closing bracket, never one inside the address.
            guard let close = authority.firstIndex(of: "]") else {
                throw WebSocketURLError.malformed(string)
            }
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let after = authority[authority.index(after: close)...]
            if after.hasPrefix(":") {
                explicitPort = try parsePort(String(after.dropFirst()), original: string)
            } else if !after.isEmpty {
                throw WebSocketURLError.malformed(string)
            }
        } else if let colon = authority.lastIndex(of: ":") {
            host = String(authority[authority.startIndex..<colon])
            explicitPort = try parsePort(String(authority[authority.index(after: colon)...]), original: string)
        } else {
            host = authority
        }

        guard !host.isEmpty else { throw WebSocketURLError.missingHost(string) }
        return WebSocketURL(
            isSecure: isSecure,
            host: host,
            port: explicitPort ?? (isSecure ? 443 : 80),
            path: path,
            query: query
        )
    }

    private static func parsePort(_ text: String, original: String) throws -> UInt16 {
        guard let port = UInt16(text), port != 0 else {
            throw WebSocketURLError.invalidPort(original)
        }
        return port
    }
}

// MARK: - Reconnect schedule

/// The relay's reconnect schedule.
///
/// Upstream increments the delay *before* the first sleep, so the observable
/// sequence is 2s, 4s, 8s, 16s, 32s, 60s, 60s… rather than starting at the 1s
/// base (`relay.rs:341-353`). `delay(forAttempt:)` reproduces that exactly;
/// getting it wrong by one step would double the reconnect latency at every
/// point on the curve.
public struct WebSocketReconnectPolicy: Sendable, Hashable {
    public var baseDelaySeconds: Double
    public var maximumDelaySeconds: Double
    public var multiplier: Double
    /// `nil` retries forever, which is what the relay does — it stops only on
    /// cancellation or a terminal auth refusal.
    public var maximumAttempts: Int?

    public init(
        baseDelaySeconds: Double = 1,
        maximumDelaySeconds: Double = 60,
        multiplier: Double = 2,
        maximumAttempts: Int? = nil
    ) {
        self.baseDelaySeconds = baseDelaySeconds
        self.maximumDelaySeconds = maximumDelaySeconds
        self.multiplier = multiplier
        self.maximumAttempts = maximumAttempts
    }

    /// `relay.rs:42-43` — base 1s, ×2, cap 60s, unbounded attempts, no jitter.
    public static let relay = WebSocketReconnectPolicy()

    /// `leader/mod.rs:113-118` — the IPC client's bounded variant: base 1s, ×2,
    /// cap 30s, 5 attempts. Used by headless and `-p` clients, which must fail
    /// rather than hang forever.
    public static let boundedLeaderClient = WebSocketReconnectPolicy(
        maximumDelaySeconds: 30,
        maximumAttempts: 5
    )

    /// Seconds to wait before retry number `attempt` (1-based).
    public func delaySeconds(forAttempt attempt: Int) -> Double {
        guard attempt >= 1 else { return 0 }
        var delay = baseDelaySeconds
        for _ in 0..<attempt {
            delay = min(delay * multiplier, maximumDelaySeconds)
        }
        return min(delay, maximumDelaySeconds)
    }

    public func shouldRetry(afterAttempt attempt: Int) -> Bool {
        guard let maximumAttempts else { return true }
        return attempt < maximumAttempts
    }

    /// Nanoseconds, for `Task.sleep(nanoseconds:)`.
    public func delayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        UInt64(max(0, delaySeconds(forAttempt: attempt)) * 1_000_000_000)
    }
}

// MARK: - Dialer

public enum WebSocketDialError: Error, Sendable, Hashable, CustomStringConvertible {
    case unsupportedPlatform(String)
    case connectTimeout(seconds: Double, url: String)
    case connectionFailed(url: String, reason: String)

    public var description: String {
        switch self {
        case .unsupportedPlatform(let detail):
            return "cannot dial a WebSocket on this platform: \(detail)"
        case .connectTimeout(let seconds, let url):
            return "timed out after \(Int(seconds))s connecting to \(url)"
        case .connectionFailed(let url, let reason):
            return "could not connect to \(url): \(reason)"
        }
    }
}

public struct WebSocketDialOptions: Sendable {
    /// Extra handshake headers, in order. `Host`, `Upgrade`, `Connection`,
    /// `Sec-WebSocket-Key` and `Sec-WebSocket-Version` are supplied by
    /// `WebSocketHandshake.clientRequest` and must not be repeated here.
    public var headers: [(String, String)]
    /// `relay.rs:44` — 30s, covering TCP, TLS and the HTTP upgrade together.
    public var connectTimeoutSeconds: Double
    public var maximumMessageSize: Int

    public init(
        headers: [(String, String)] = [],
        connectTimeoutSeconds: Double = 30,
        maximumMessageSize: Int = WebSocketLimits.defaultMaximumMessageSize
    ) {
        self.headers = headers
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.maximumMessageSize = maximumMessageSize
    }
}

public enum WebSocketDialBackend: Sendable, Hashable {
    case networkFramework
    case urlSession
}

public enum WebSocketDialer {
    public static var outboundBackend: WebSocketDialBackend {
        #if canImport(Network)
        return .networkFramework
        #else
        return .urlSession
        #endif
    }

    /// Open a TCP (or TLS) byte channel and wait for it to become usable.
    ///
    /// Unlike `WebSocketNetworkChannel.connect`, this does not return until the
    /// connection is actually established, so a refused or unroutable endpoint
    /// throws here instead of surfacing as an end-of-stream during the
    /// handshake.
    public static func channel(
        to url: WebSocketURL,
        connectTimeoutSeconds: Double = 30
    ) async throws -> any WebSocketByteChannel {
        #if canImport(Network)
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(url.host),
            port: NWEndpoint.Port(rawValue: url.port) ?? (url.isSecure ? .https : .http)
        )
        let parameters: NWParameters = url.isSecure ? .tls : .tcp
        let connection = NWConnection(to: endpoint, using: parameters)
        let channel = NWConnectionByteChannel(
            connection,
            queue: DispatchQueue(label: "opengrok-websocket-dial")
        )
        do {
            try await channel.startAndWaitReady(timeoutSeconds: connectTimeoutSeconds)
        } catch let error as WebSocketDialError {
            await channel.close()
            throw error
        }
        return channel
        #else
        guard !url.isSecure else {
            throw WebSocketDialError.unsupportedPlatform(
                "portable sockets provide plaintext ws:// only; cannot reach \(url.absoluteString)"
            )
        }
        do {
            return try await PortableSocketConnector.tcp(
                host: url.host,
                port: url.port,
                timeoutSeconds: connectTimeoutSeconds
            )
        } catch let error as PortableSocketError {
            throw WebSocketDialError.connectionFailed(
                url: url.absoluteString,
                reason: error.description
            )
        }
        #endif
    }

    /// Dial, upgrade, and return a client-role connection.
    ///
    /// The returned connection masks every outbound frame, because `role` is
    /// `.client` — RFC 6455 §5.3 requires it and `server.rs` closes an
    /// unmasked client frame.
    public static func connect(
        to url: WebSocketURL,
        options: WebSocketDialOptions = WebSocketDialOptions()
    ) async throws -> any WebSocketClient {
        #if canImport(Network)
        let channel = try await channel(to: url, connectTimeoutSeconds: options.connectTimeoutSeconds)
        do {
            return try await WebSocketClientUpgrade.connect(
                channel: channel,
                host: url.hostHeader,
                target: url.target,
                headers: options.headers,
                maximumMessageSize: options.maximumMessageSize
            )
        } catch {
            await channel.close()
            throw error
        }
        #else
        guard let endpoint = URL(string: url.absoluteString) else {
            throw WebSocketDialError.connectionFailed(
                url: url.absoluteString,
                reason: "Foundation rejected the WebSocket URL"
            )
        }
        var headers: [String: String] = [:]
        for (name, value) in options.headers {
            headers[name] = value
        }
        do {
            return try URLSessionWebSocketClient.connect(
                url: endpoint,
                configuration: HTTPTransportConfiguration(
                    connectTimeout: options.connectTimeoutSeconds,
                    requestTimeout: options.connectTimeoutSeconds
                ),
                headers: headers,
                maximumMessageSize: options.maximumMessageSize
            )
        } catch {
            throw WebSocketDialError.connectionFailed(
                url: url.absoluteString,
                reason: String(describing: error)
            )
        }
        #endif
    }
}
