// MCPOAuthTransportTests.swift
//
// Token attachment on actual MCP requests and the 401 recovery contract:
// `Authorization: Bearer {token}` header bytes (rmcp auth.rs:1731-1737), the
// static-header precedence (servers.rs:4294-4304), and 401 → disk-fresh /
// refresh → one retry (the non-browser prefix of `force_reauth(false)`,
// servers.rs:1465-1493, 2884-2983). The manager under test is the REAL
// `MCPAuthorizationManager` over the REAL store file in an isolated home.

import Foundation
import OpenGrokHTTP
import OpenGrokShared
import Testing
@testable import OpenGrokMCP

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&storage)
    }
}

/// Handler-driven HTTP fake that records every request.
private final class RecordingHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private let handler: @Sendable (HTTPRequest, Int) -> HTTPResponse

    init(handler: @escaping @Sendable (HTTPRequest, Int) -> HTTPResponse) {
        self.handler = handler
    }

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private nonisolated func record(_ request: HTTPRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        return recorded.count - 1
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        handler(request, record(request))
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await send(request)
                    continuation.yield(.metadata(response.metadata))
                    continuation.yield(.body(response.body))
                    continuation.yield(.end)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct StubAuthorization: MCPAuthorizationProviding {
    var token: String
    var onUnauthorized: @Sendable (String?) -> Bool = { _ in false }

    func accessToken() async throws -> String { token }
    func handleUnauthorized(staleToken: String?) async -> Bool {
        onUnauthorized(staleToken)
    }
}

/// A stub that fails the test if the transport consults it at all.
private struct ForbiddenAuthorization: MCPAuthorizationProviding {
    func accessToken() async throws -> String {
        Issue.record("authorization provider must not be consulted")
        return "unreachable"
    }
    func handleUnauthorized(staleToken: String?) async -> Bool {
        Issue.record("authorization provider must not be consulted")
        return false
    }
}

private let endpoint = URL(string: "http://127.0.0.1:9/mcp")!

private func pingResponse() -> HTTPResponse {
    HTTPResponse(
        metadata: HTTPResponseMetadata(
            statusCode: 200,
            headers: ["Content-Type": "application/json"]
        ),
        body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
    )
}

private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-mcp-authhttp-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

@Suite("MCP OAuth token attachment on the HTTP transport")
struct MCPOAuthTransportTests {
    @Test("the Authorization header carries exactly `Bearer {token}`")
    func headerBytes() async throws {
        let http = RecordingHTTPTransport { _, _ in pingResponse() }
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: endpoint),
            authorization: StubAuthorization(token: "at-123")
        )
        _ = try await transport.send(.request(MCPRequest(
            id: .number(1), method: MCPMethod.ping)))

        let request = try #require(http.requests.first)
        #expect(request.headers["Authorization"] == "Bearer at-123")
        #expect(request.method == .post)
        #expect(request.url == endpoint)
    }

    @Test("a statically configured Authorization header wins over the provider")
    func staticHeaderWins() async throws {
        let http = RecordingHTTPTransport { _, _ in pingResponse() }
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(
                endpoint: endpoint,
                headers: ["Authorization": "Bearer static-token"]
            ),
            authorization: ForbiddenAuthorization()
        )
        _ = try await transport.send(.request(MCPRequest(
            id: .number(1), method: MCPMethod.ping)))
        let request = try #require(http.requests.first)
        #expect(request.headers["Authorization"] == "Bearer static-token")
    }

    @Test("401 triggers a real refresh grant, then one retry with the new token")
    func unauthorizedRefreshRetry() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Seed the real store with a stale-but-refreshable credential.
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "srv", serverURL: endpoint,
            credentials: MCPStoredCredentials(
                clientId: "c",
                tokenResponse: MCPOAuthTokenResponse(
                    accessToken: "at-stale", refreshToken: "rt-good"),
                tokenReceivedAt: 1_000
            )
        )

        let http = RecordingHTTPTransport { request, _ in
            switch request.url.path {
            case "/mcp":
                let auth = request.headers["Authorization"]
                if auth == "Bearer at-stale" {
                    return HTTPResponse(
                        metadata: HTTPResponseMetadata(statusCode: 401), body: Data())
                }
                if auth == "Bearer at-new" {
                    return pingResponse()
                }
                return HTTPResponse(
                    metadata: HTTPResponseMetadata(statusCode: 403), body: Data())
            case "/.well-known/oauth-authorization-server/mcp":
                let metadata = #"{"authorization_endpoint":"http://127.0.0.1:9/authorize","token_endpoint":"http://127.0.0.1:9/token"}"#
                return HTTPResponse(
                    metadata: HTTPResponseMetadata(
                        statusCode: 200, headers: ["Content-Type": "application/json"]),
                    body: Data(metadata.utf8)
                )
            case "/token":
                let token = #"{"access_token":"at-new","token_type":"bearer","expires_in":3600,"refresh_token":"rt-good"}"#
                return HTTPResponse(
                    metadata: HTTPResponseMetadata(
                        statusCode: 200, headers: ["Content-Type": "application/json"]),
                    body: Data(token.utf8)
                )
            default:
                return HTTPResponse(
                    metadata: HTTPResponseMetadata(statusCode: 404), body: Data())
            }
        }

        let manager = MCPAuthorizationManager(
            baseURL: endpoint,
            transport: http,
            storage: MCPFileCredentialStorage(home: home, serverName: "srv", serverURL: endpoint)
        )
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: endpoint),
            authorization: manager
        )

        let reply = try await transport.send(.request(MCPRequest(
            id: .number(1), method: MCPMethod.ping)))
        guard case .response(let response)? = reply else {
            Issue.record("expected a response after the auth retry")
            return
        }
        #expect(response.error == nil)

        // Request order: stale MCP POST → discovery → refresh grant → retry.
        // (Discovery GETs also touch /mcp; the MCP wire calls are the POSTs.)
        let mcpRequests = http.requests.filter { $0.url.path == "/mcp" && $0.method == .post }
        #expect(mcpRequests.count == 2)
        #expect(mcpRequests[0].headers["Authorization"] == "Bearer at-stale")
        #expect(mcpRequests[1].headers["Authorization"] == "Bearer at-new")
        #expect(http.requests.contains { $0.url.path == "/token" })

        // The refreshed token was persisted to the real store.
        let stored = try MCPFileCredentialStorage(
            home: home, serverName: "srv", serverURL: endpoint
        ).load()
        #expect(stored?.tokenResponse?.accessToken == "at-new")
    }

    @Test("401 with no refresh path surfaces as an auth rejection, once")
    func unauthorizedWithoutRecovery() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Token with no refresh_token: the refresh arm is impossible.
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "srv", serverURL: endpoint,
            credentials: MCPStoredCredentials(
                clientId: "c",
                tokenResponse: MCPOAuthTokenResponse(accessToken: "at-dead")
            )
        )
        let http = RecordingHTTPTransport { request, _ in
            request.url.path == "/mcp"
                ? HTTPResponse(metadata: HTTPResponseMetadata(statusCode: 401), body: Data())
                : HTTPResponse(metadata: HTTPResponseMetadata(statusCode: 404), body: Data())
        }
        let manager = MCPAuthorizationManager(
            baseURL: endpoint,
            transport: http,
            storage: MCPFileCredentialStorage(home: home, serverName: "srv", serverURL: endpoint)
        )
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: endpoint),
            authorization: manager
        )

        await #expect(throws: MCPError.transport("MCP HTTP status 401")) {
            _ = try await transport.send(.request(MCPRequest(
                id: .number(1), method: MCPMethod.ping)))
        }
        // No retry storm: exactly one MCP POST.
        #expect(http.requests.filter { $0.url.path == "/mcp" && $0.method == .post }.count == 1)
    }

    @Test("the disk arm retries when another process wrote a different token")
    func diskFreshTokenRetries() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "srv", serverURL: endpoint,
            credentials: MCPStoredCredentials(
                clientId: "c",
                tokenResponse: MCPOAuthTokenResponse(accessToken: "at-old")
            )
        )
        let manager = MCPAuthorizationManager(
            baseURL: endpoint,
            transport: RecordingHTTPTransport { _, _ in
                HTTPResponse(metadata: HTTPResponseMetadata(statusCode: 404), body: Data())
            },
            storage: MCPFileCredentialStorage(home: home, serverName: "srv", serverURL: endpoint)
        )

        // Same token on disk as the one that 401'd → no point retrying.
        #expect(await manager.handleUnauthorized(staleToken: "at-old") == false)

        // "Another process" lands a different token → retry is worthwhile.
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "srv", serverURL: endpoint,
            credentials: MCPStoredCredentials(
                clientId: "c",
                tokenResponse: MCPOAuthTokenResponse(accessToken: "at-other"),
                tokenReceivedAt: 2_000
            )
        )
        #expect(await manager.handleUnauthorized(staleToken: "at-old") == true)
    }
}
