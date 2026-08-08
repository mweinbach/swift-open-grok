import Foundation
import OpenGrokHTTP

public protocol MCPTransport: Sendable {
    func send(_ message: MCPWireMessage) async throws -> MCPWireMessage?
    func close() async
}

public enum MCPWireCodec {
    public static func encode(_ message: MCPWireMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(message)
        } catch {
            throw MCPError.parse("unable to encode MCP message: \(error)")
        }
    }

    public static func decode(_ data: Data) throws -> MCPWireMessage {
        guard !data.isEmpty else {
            throw MCPError.parse("empty MCP message")
        }
        do {
            return try JSONDecoder().decode(MCPWireMessage.self, from: data)
        } catch {
            throw MCPError.parse("invalid MCP JSON-RPC message: \(error)")
        }
    }

    public static func encodeString(_ message: MCPWireMessage) throws -> String {
        guard let string = String(data: try encode(message), encoding: .utf8) else {
            throw MCPError.parse("MCP message is not valid UTF-8")
        }
        return string
    }

    public static func decodeString(_ string: String) throws -> MCPWireMessage {
        guard let data = string.data(using: .utf8) else {
            throw MCPError.parse("MCP message is not valid UTF-8")
        }
        return try decode(data)
    }
}

public struct MCPHTTPTransportConfiguration: Sendable, Equatable {
    public var endpoint: URL
    public var headers: [String: String]
    public var timeout: TimeInterval?

    public init(
        endpoint: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) {
        self.endpoint = endpoint
        self.headers = headers
        self.timeout = timeout
    }
}

/// Bearer-token seam for OAuth-protected MCP servers, filled by
/// `MCPAuthorizationManager`. Mirrors rmcp's `AuthClient` wrapper, which
/// injects the token on every streamable-HTTP operation
/// (rmcp-2.1.0 transport/common/auth/streamable_http_client.rs:9-67) as
/// `Authorization: Bearer {token}` (transport/auth.rs:1731-1737).
public protocol MCPAuthorizationProviding: Sendable {
    /// Token for the next request. Refreshes proactively when the stored
    /// token is within the expiry buffer.
    func accessToken() async throws -> String
    /// Called after an HTTP 401. Returns `true` when a one-shot retry is
    /// worthwhile — a fresh token appeared on disk (another session or
    /// process authenticated) or a refresh grant succeeded. This is the
    /// non-browser prefix of upstream's tool-call recovery ladder
    /// (`force_reauth(false)`, xai-grok-mcp/src/servers.rs:2884-2983).
    func handleUnauthorized(staleToken: String?) async -> Bool
}

public actor MCPHTTPTransport: MCPTransport {
    private let httpTransport: any HTTPTransport
    private let configuration: MCPHTTPTransportConfiguration
    private let authorization: (any MCPAuthorizationProviding)?
    private var sessionID: String?
    private var isClosed = false

    public init(
        httpTransport: any HTTPTransport,
        configuration: MCPHTTPTransportConfiguration,
        authorization: (any MCPAuthorizationProviding)? = nil
    ) {
        self.httpTransport = httpTransport
        self.configuration = configuration
        self.authorization = authorization
    }

    public var currentSessionID: String? { sessionID }

    public func send(_ message: MCPWireMessage) async throws -> MCPWireMessage? {
        guard !isClosed else { throw MCPError.transportClosed }
        let body = try MCPWireCodec.encode(message)

        do {
            var attachedToken: String?
            var response = try await sendOnce(body: body, attachedToken: &attachedToken)
            // 401 with an auth seam: try disk-fresh/refresh recovery once,
            // then replay. Upstream recovers the same failure via
            // `force_reauth(false)` + one retry at the tool-call layer
            // (servers.rs:1465-1493); the browser escalation arm of that
            // ladder stays with the explicit `mcp login` trigger.
            if response.metadata.statusCode == 401,
               let authorization,
               await authorization.handleUnauthorized(staleToken: attachedToken) {
                response = try await sendOnce(body: body, attachedToken: &attachedToken)
            }
            guard (200..<300).contains(response.metadata.statusCode) else {
                throw MCPError.transport("MCP HTTP status \(response.metadata.statusCode)")
            }
            if let value = headerValue("mcp-session-id", in: response.metadata.headers) {
                sessionID = value
            }
            guard !response.body.isEmpty else { return nil }
            return try decodeHTTPBody(response.body, contentType: response.metadata.contentType)
        } catch let error as MCPError {
            throw error
        } catch {
            throw mcpError(from: error)
        }
    }

    private func sendOnce(body: Data, attachedToken: inout String?) async throws -> HTTPResponse {
        var headers = configuration.headers
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        headers["Accept"] = headers["Accept"] ?? "application/json, text/event-stream"
        if let sessionID {
            headers["Mcp-Session-Id"] = sessionID
        }
        // A statically configured Authorization header wins; upstream never
        // builds the auth client when config carries one (servers.rs:4294-4304).
        let hasStaticAuthorization = headers.keys.contains {
            $0.caseInsensitiveCompare("Authorization") == .orderedSame
        }
        if let authorization, !hasStaticAuthorization {
            let token: String
            do {
                token = try await authorization.accessToken()
            } catch let error as MCPAuthError {
                throw MCPError.transport(String(describing: error))
            }
            attachedToken = token
            headers["Authorization"] = "Bearer \(token)"
        }

        let request = HTTPRequest(
            method: .post,
            url: configuration.endpoint,
            headers: headers,
            body: body,
            timeout: configuration.timeout,
            idempotency: .nonIdempotent
        )
        return try await httpTransport.send(request)
    }

    public func close() {
        isClosed = true
    }

    private func decodeHTTPBody(_ data: Data, contentType: String?) throws -> MCPWireMessage {
        if contentType?.lowercased().contains("text/event-stream") == true {
            let text = String(decoding: data, as: UTF8.self)
            let eventData = text
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .compactMap { line -> String? in
                    let value = line.trimmingCharacters(in: .whitespaces)
                    guard value.hasPrefix("data:") else { return nil }
                    return String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                }
                .joined()
            guard let eventBytes = eventData.data(using: .utf8), !eventData.isEmpty else {
                throw MCPError.parse("MCP event stream contained no data event")
            }
            return try MCPWireCodec.decode(eventBytes)
        }
        return try MCPWireCodec.decode(data)
    }

    private func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { key, _ in key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public actor MCPInMemoryTransport: MCPTransport {
    private let server: MCPServer
    private var isClosed = false

    public init(server: MCPServer) {
        self.server = server
    }

    public func send(_ message: MCPWireMessage) async throws -> MCPWireMessage? {
        guard !isClosed else { throw MCPError.transportClosed }
        return try await server.handle(message)
    }

    public func close() {
        isClosed = true
    }
}
