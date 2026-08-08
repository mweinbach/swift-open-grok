// MCPOAuthFlowTests.swift
//
// The MCP OAuth runtime against a scripted authorization server: discovery
// (RFC 9728 + RFC 8414 ladders and the SSRF gates), dynamic client
// registration, the PKCE authorization-code exchange persisting to the REAL
// mcp_credentials.json in an isolated home, refresh semantics, and the full
// browser flow where the browser is a fake driving the REAL loopback
// listener over an actual socket (the E6 pattern). Every endpoint the code
// can dial is pinned to 127.0.0.1; assertions parse JSON.

import Foundation
import OpenGrokHTTP
import OpenGrokShared
import Testing
@testable import OpenGrokMCP

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Routed transport fake

/// Path-routing HTTP fake: the OAuth legs (discovery, DCR, token) resolve by
/// path, so ordering-based scripting would be brittle. Records every request.
private final class RoutedHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private let handler: @Sendable (HTTPRequest) -> HTTPResponse

    init(handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) {
        self.handler = handler
    }

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private nonisolated func record(_ request: HTTPRequest) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        record(request)
        return handler(request)
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

private func jsonResponse(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return HTTPResponse(
        metadata: HTTPResponseMetadata(
            statusCode: status,
            headers: ["Content-Type": "application/json"]
        ),
        body: data
    )
}

private func emptyResponse(_ status: Int, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(metadata: HTTPResponseMetadata(statusCode: status, headers: headers), body: Data())
}

/// The scripted server base: a dead loopback port so a pin failure dials
/// nothing real (the transport is a fake; no socket is ever opened).
private let asBase = "http://127.0.0.1:9"

/// Standard scripted AS: direct RFC 8414 discovery plus DCR and token
/// endpoints. `tokenHandler` sees the parsed form body of each token POST.
private func scriptedAuthServer(
    metadataExtras: [String: Any] = [:],
    scopesSupported: [String]? = nil,
    issuer: String? = nil,
    tokenHandler: @escaping @Sendable ([String: String]) -> HTTPResponse
) -> RoutedHTTPTransport {
    // Serialize the metadata document eagerly so the @Sendable route handler
    // captures only Data.
    var metadata: [String: Any] = [
        "authorization_endpoint": "\(asBase)/authorize",
        "token_endpoint": "\(asBase)/token",
        "registration_endpoint": "\(asBase)/register",
    ]
    if let scopesSupported { metadata["scopes_supported"] = scopesSupported }
    if let issuer { metadata["issuer"] = issuer }
    for (k, v) in metadataExtras { metadata[k] = v }
    let metadataData = (try? JSONSerialization.data(withJSONObject: metadata)) ?? Data()

    return RoutedHTTPTransport { request in
        let path = request.url.path
        if path == "/.well-known/oauth-authorization-server/mcp" {
            return HTTPResponse(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"]
                ),
                body: metadataData
            )
        }
        if path == "/register", request.method == .post {
            return jsonResponse(201, [
                "client_id": "dcr-client-1",
                "client_secret": "",
                "redirect_uris": ["unchecked"],
            ])
        }
        if path == "/token", request.method == .post {
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            return tokenHandler(parseForm(body))
        }
        // The MCP endpoint itself 401s without resource metadata, steering
        // discovery to the direct well-known ladder.
        if path == "/mcp" { return emptyResponse(401) }
        return emptyResponse(404)
    }
}

private func parseForm(_ body: String) -> [String: String] {
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        fields[key] = value
    }
    return fields
}

private func queryValue(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == name })?.value
}

private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-mcp-oauth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private let serverURL = URL(string: "\(asBase)/mcp")!

private func makeManager(
    transport: RoutedHTTPTransport,
    home: URL,
    serverName: String = "srv",
    now: @escaping @Sendable () -> UInt64 = { 1_800_000_000 }
) -> MCPAuthorizationManager {
    MCPAuthorizationManager(
        baseURL: serverURL,
        transport: transport,
        storage: MCPFileCredentialStorage(home: home, serverName: serverName, serverURL: serverURL),
        now: now
    )
}

/// Deliver `path` to the real loopback listener over an actual socket and
/// return the raw HTTP response (the fake browser's transport).
@discardableResult
private func socketGET(port: UInt16, target: String, method: String = "GET") -> String {
    let fd = socket(AF_INET, {
        #if canImport(Darwin)
        SOCK_STREAM
        #else
        Int32(SOCK_STREAM.rawValue)
        #endif
    }(), 0)
    guard fd >= 0 else { return "" }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return "" }
    let request = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
    _ = Array(request.utf8).withUnsafeBufferPointer {
        send(fd, $0.baseAddress, $0.count, 0)
    }
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n <= 0 { break }
        response.append(contentsOf: buffer[..<n])
    }
    return String(decoding: response, as: UTF8.self)
}

// MARK: - Discovery

@Suite("MCP OAuth discovery")
struct MCPOAuthDiscoveryTests {
    @Test("direct RFC 8414 ladder finds the well-known metadata")
    func directDiscovery() async throws {
        let transport = scriptedAuthServer { _ in emptyResponse(500) }
        let result = try await MCPOAuthDiscovery.discoverMetadata(
            baseURL: serverURL, transport: transport)
        #expect(result.metadata.authorizationEndpoint == "\(asBase)/authorize")
        #expect(result.metadata.tokenEndpoint == "\(asBase)/token")
        #expect(result.metadata.registrationEndpoint == "\(asBase)/register")
    }

    @Test("a server with no OAuth support fails closed with noAuthorizationSupport")
    func noSupport() async throws {
        let transport = RoutedHTTPTransport { _ in emptyResponse(404) }
        await #expect(throws: MCPAuthError.noAuthorizationSupport) {
            _ = try await MCPOAuthDiscovery.discoverMetadata(
                baseURL: serverURL, transport: transport)
        }
    }

    @Test("WWW-Authenticate resource_metadata is honored, same-origin only")
    func wwwAuthenticateDiscovery() async throws {
        let transport = RoutedHTTPTransport { request in
            switch request.url.path {
            case "/mcp":
                return emptyResponse(401, headers: [
                    "WWW-Authenticate": #"Bearer resource_metadata="\#(asBase)/rm", scope="mcp.read mcp.write""#,
                ])
            case "/rm":
                let metadata: [String: Any] = [
                    "resource": "\(asBase)/mcp",
                    // Same-origin AS lives under a well-known path directly.
                    "authorization_servers": ["\(asBase)/.well-known/oauth-authorization-server/mcp"],
                    "scopes_supported": ["mcp.read"],
                ]
                return jsonResponse(200, metadata)
            case "/.well-known/oauth-authorization-server/mcp":
                return jsonResponse(200, [
                    "authorization_endpoint": "\(asBase)/authorize",
                    "token_endpoint": "\(asBase)/token",
                ])
            default:
                return emptyResponse(404)
            }
        }
        // The SSRF gate rejects loopback AS candidates from resource
        // metadata (rmcp auth.rs:894-899) — so this path must FALL THROUGH
        // to direct discovery, which still succeeds against the same host.
        let result = try await MCPOAuthDiscovery.discoverMetadata(
            baseURL: serverURL, transport: transport)
        #expect(result.metadata.tokenEndpoint == "\(asBase)/token")
        // The WWW-Authenticate scope hint was captured on the way.
        #expect(result.wwwAuthScopes == ["mcp.read", "mcp.write"])
    }

    @Test("resource metadata identifier mismatch is an error, not a fall-through")
    func resourceMismatch() async throws {
        let transport = RoutedHTTPTransport { request in
            switch request.url.path {
            case "/mcp":
                return emptyResponse(401, headers: [
                    "WWW-Authenticate": #"Bearer resource_metadata="\#(asBase)/rm""#,
                ])
            case "/rm":
                return jsonResponse(200, [
                    "resource": "https://evil.example.com/other",
                    "authorization_servers": ["https://as.example.com"],
                ])
            default:
                return emptyResponse(404)
            }
        }
        await #expect(throws: MCPAuthError.metadataError(
            "Protected resource metadata resource mismatch: "
                + "expected '\(asBase)/mcp', got 'https://evil.example.com/other'"
        )) {
            _ = try await MCPOAuthDiscovery.discoverMetadata(
                baseURL: serverURL, transport: transport)
        }
    }

    @Test("authorization-server SSRF gate blocks loopback, private, and cloud-metadata hosts")
    func ssrfGate() {
        func allowed(_ s: String) -> Bool {
            MCPOAuthURLPolicy.isAllowedAuthorizationServerMetadataURL(URL(string: s)!)
        }
        #expect(allowed("https://auth.example.com/x"))
        #expect(!allowed("http://localhost/x"))
        #expect(!allowed("http://sub.localhost/x"))
        #expect(!allowed("http://127.0.0.1/x"))
        #expect(!allowed("http://10.0.0.8/x"))
        #expect(!allowed("http://172.16.4.1/x"))
        #expect(!allowed("http://192.168.1.1/x"))
        #expect(!allowed("http://169.254.169.254/x"))
        #expect(!allowed("http://100.64.3.2/x"))
        #expect(!allowed("http://metadata.google.internal/x"))
        #expect(!allowed("http://metadata/x"))
        #expect(!allowed("ftp://auth.example.com/x"))
    }

    @Test("cross-origin discovery redirects are rejected on the final URL")
    func crossOriginRedirect() async {
        // The transport reports a final URL on a different origin, the way an
        // auto-following URLSession would after a hostile redirect.
        let transport = RoutedHTTPTransport { _ in
            HTTPResponse(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    url: URL(string: "https://evil.example.com/.well-known/oauth-authorization-server")
                ),
                body: Data("{}".utf8)
            )
        }
        await #expect(throws: MCPAuthError.noAuthorizationSupport) {
            _ = try await MCPOAuthDiscovery.discoverMetadata(
                baseURL: serverURL, transport: transport)
        }
    }
}

// MARK: - DCR + authorization URL + exchange

@Suite("MCP OAuth authorization-code flow")
struct MCPOAuthFlowUnitTests {
    @Test("dynamic registration sends the public-native-client request body")
    func dcrBody() async throws {
        let transport = scriptedAuthServer { _ in emptyResponse(500) }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = makeManager(transport: transport, home: home)
        let metadata = try await manager.discoverMetadata()
        await manager.setMetadata(metadata)
        try await manager.registerClient(
            name: mcpOAuthClientName,
            redirectURI: "http://127.0.0.1:7777/callback",
            scopes: ["mcp.read", "mcp.write"]
        )

        let registration = try #require(
            transport.requests.first { $0.url.path == "/register" })
        let body = try #require(
            try JSONSerialization.jsonObject(with: registration.body ?? Data()) as? [String: Any])
        // rmcp auth.rs:1198-1213, field for field.
        #expect(body["client_name"] as? String == "Grok")
        #expect(body["redirect_uris"] as? [String] == ["http://127.0.0.1:7777/callback"])
        #expect(body["grant_types"] as? [String] == ["authorization_code", "refresh_token"])
        #expect(body["token_endpoint_auth_method"] as? String == "none")
        #expect(body["response_types"] as? [String] == ["code"])
        #expect(body["scope"] as? String == "mcp.read mcp.write")
        #expect(body["application_type"] as? String == "native")
    }

    @Test("authorization URL carries PKCE S256, state, and the RFC 8707 resource")
    func authorizationURLShape() async throws {
        let transport = scriptedAuthServer { _ in emptyResponse(500) }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = makeManager(transport: transport, home: home)
        let metadata = try await manager.discoverMetadata()
        await manager.setMetadata(metadata)
        try await manager.configureClient(
            clientID: "byo-client", redirectURI: "http://127.0.0.1:7777/callback")

        let url = try await manager.authorizationURL(scopes: ["mcp.read"])
        #expect(url.absoluteString.hasPrefix("\(asBase)/authorize?"))
        #expect(queryValue(url, "response_type") == "code")
        #expect(queryValue(url, "client_id") == "byo-client")
        #expect(queryValue(url, "code_challenge_method") == "S256")
        #expect(queryValue(url, "code_challenge")?.count == 43)
        #expect(queryValue(url, "redirect_uri") == "http://127.0.0.1:7777/callback")
        #expect(queryValue(url, "resource") == serverURL.absoluteString)
        #expect(queryValue(url, "scope") == "mcp.read")
        #expect((queryValue(url, "state") ?? "").isEmpty == false)
    }

    @Test("code exchange persists rmcp-shaped credentials into the real store file")
    func exchangePersists() async throws {
        let tokenBodies = LockedBox<[[String: String]]>([])
        let transport = scriptedAuthServer { fields in
            tokenBodies.mutate { $0.append(fields) }
            return jsonResponse(200, [
                "access_token": "at-ok",
                "token_type": "Bearer",
                "expires_in": 3600,
                "refresh_token": "rt-ok",
                "scope": "mcp.read",
            ])
        }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = makeManager(transport: transport, home: home, now: { 1_730_000_123 })
        let metadata = try await manager.discoverMetadata()
        await manager.setMetadata(metadata)
        try await manager.registerClient(
            name: mcpOAuthClientName,
            redirectURI: "http://127.0.0.1:7777/callback",
            scopes: ["mcp.read"]
        )
        let authURL = try await manager.authorizationURL(scopes: ["mcp.read"])
        let state = try #require(queryValue(authURL, "state"))

        let token = try await manager.exchangeCode(code: "auth-code", state: state)
        #expect(token.accessToken == "at-ok")

        // The token POST body, field for field (rmcp auth.rs:1556-1563).
        let body = try #require(tokenBodies.value.first)
        #expect(body["grant_type"] == "authorization_code")
        #expect(body["code"] == "auth-code")
        #expect(body["redirect_uri"] == "http://127.0.0.1:7777/callback")
        #expect(body["client_id"] == "dcr-client-1")
        #expect(body["resource"] == serverURL.absoluteString)
        #expect((body["code_verifier"] ?? "").count == 43)
        // Empty DCR client_secret means public client — no secret anywhere.
        #expect(body["client_secret"] == nil)

        // Tokens landed in the REAL mcp_credentials.json — parse it.
        let data = try Data(contentsOf: MCPCredentialStore.defaultPath(home: home))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require(object["srv:\(asBase)/mcp"] as? [String: Any])
        #expect(entry["client_id"] as? String == "dcr-client-1")
        #expect(entry["granted_scopes"] as? [String] == ["mcp.read"])
        #expect(entry["token_received_at"] as? Int == 1_730_000_123)
        let tokenObject = try #require(entry["token_response"] as? [String: Any])
        #expect(tokenObject["access_token"] as? String == "at-ok")
        #expect(tokenObject["refresh_token"] as? String == "rt-ok")
    }

    @Test("exchange rejects an unknown state and consumes a used one")
    func exchangeStateSemantics() async throws {
        let transport = scriptedAuthServer { _ in
            jsonResponse(200, ["access_token": "at", "token_type": "bearer"])
        }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = makeManager(transport: transport, home: home)
        let metadata = try await manager.discoverMetadata()
        await manager.setMetadata(metadata)
        try await manager.configureClient(
            clientID: "c", redirectURI: "http://127.0.0.1:7777/callback")

        await #expect(throws: MCPAuthError.internalError("Authorization state not found")) {
            _ = try await manager.exchangeCode(code: "c1", state: "never-issued")
        }

        let authURL = try await manager.authorizationURL(scopes: [])
        let state = try #require(queryValue(authURL, "state"))
        _ = try await manager.exchangeCode(code: "c1", state: state)
        // One-time use: replay fails.
        await #expect(throws: MCPAuthError.internalError("Authorization state not found")) {
            _ = try await manager.exchangeCode(code: "c1", state: state)
        }
    }

    @Test("RFC 9207 iss validation: required when advertised, matched when present")
    func issValidation() async throws {
        let issuer = "https://auth.example.com"
        let transport = scriptedAuthServer(
            metadataExtras: ["authorization_response_iss_parameter_supported": true],
            issuer: issuer
        ) { _ in
            jsonResponse(200, ["access_token": "at", "token_type": "bearer"])
        }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = makeManager(transport: transport, home: home)
        let metadata = try await manager.discoverMetadata()
        await manager.setMetadata(metadata)
        try await manager.configureClient(
            clientID: "c", redirectURI: "http://127.0.0.1:7777/callback")

        // Missing iss while the AS requires it.
        var authURL = try await manager.authorizationURL(scopes: [])
        var state = try #require(queryValue(authURL, "state"))
        await #expect(throws: MCPAuthError.authorizationServerMissingIssuer(expected: issuer)) {
            _ = try await manager.exchangeCode(code: "c1", state: state, issuer: nil)
        }

        // Mismatched iss.
        authURL = try await manager.authorizationURL(scopes: [])
        state = try #require(queryValue(authURL, "state"))
        await #expect(throws: MCPAuthError.authorizationServerMismatch(
            expected: issuer, received: "https://evil.example.com"
        )) {
            _ = try await manager.exchangeCode(
                code: "c1", state: state, issuer: "https://evil.example.com")
        }

        // Matching iss succeeds.
        authURL = try await manager.authorizationURL(scopes: [])
        state = try #require(queryValue(authURL, "state"))
        let token = try await manager.exchangeCode(code: "c1", state: state, issuer: issuer)
        #expect(token.accessToken == "at")
    }

    @Test("refresh keeps the old refresh token when the response omits one")
    func refreshKeepsToken() async throws {
        let tokenBodies = LockedBox<[[String: String]]>([])
        let transport = scriptedAuthServer { fields in
            tokenBodies.mutate { $0.append(fields) }
            return jsonResponse(200, [
                "access_token": "at-new",
                "token_type": "bearer",
                "expires_in": 3600,
            ])
        }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "srv", serverURL: serverURL,
            credentials: MCPStoredCredentials(
                clientId: "c",
                tokenResponse: MCPOAuthTokenResponse(
                    accessToken: "at-old", refreshToken: "rt-keep"),
                grantedScopes: ["mcp.read"],
                tokenReceivedAt: 1_000
            )
        )
        let manager = makeManager(transport: transport, home: home)
        let refreshed = try await manager.refreshToken()
        #expect(refreshed.accessToken == "at-new")
        #expect(refreshed.refreshToken == "rt-keep")

        let body = try #require(tokenBodies.value.first)
        #expect(body["grant_type"] == "refresh_token")
        #expect(body["refresh_token"] == "rt-keep")
        #expect(body["scope"] == "mcp.read")

        // Persisted with the kept refresh token — parse the real file.
        let data = try Data(contentsOf: MCPCredentialStore.defaultPath(home: home))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require(object["srv:\(asBase)/mcp"] as? [String: Any])
        let tokenObject = try #require(entry["token_response"] as? [String: Any])
        #expect(tokenObject["access_token"] as? String == "at-new")
        #expect(tokenObject["refresh_token"] as? String == "rt-keep")
    }

    @Test("getAccessToken refreshes inside the 30s buffer and passes expiry-less tokens through")
    func accessTokenExpiryBuffer() async throws {
        let refreshCount = LockedBox<Int>(0)
        let transport = scriptedAuthServer { _ in
            refreshCount.mutate { $0 += 1 }
            return jsonResponse(200, [
                "access_token": "at-refreshed", "token_type": "bearer", "expires_in": 3600,
            ])
        }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // 10 seconds of life left (< 30s buffer) → refresh.
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "srv", serverURL: serverURL,
            credentials: MCPStoredCredentials(
                clientId: "c",
                tokenResponse: MCPOAuthTokenResponse(
                    accessToken: "at-stale", expiresIn: 3600, refreshToken: "rt"),
                tokenReceivedAt: 1_800_000_000 - 3_590
            )
        )
        let manager = makeManager(transport: transport, home: home)
        #expect(try await manager.getAccessToken() == "at-refreshed")
        #expect(refreshCount.value == 1)

        // Expiry-less token: returned as-is, no refresh (auth.rs:1647-1650).
        let home2 = try makeHome()
        defer { try? FileManager.default.removeItem(at: home2) }
        try MCPCredentialStore.insertAndSave(
            home: home2, serverName: "srv", serverURL: serverURL,
            credentials: MCPStoredCredentials(
                clientId: "c",
                tokenResponse: MCPOAuthTokenResponse(accessToken: "at-forever")
            )
        )
        let manager2 = makeManager(transport: transport, home: home2)
        #expect(try await manager2.getAccessToken() == "at-forever")
        #expect(refreshCount.value == 1)

        // Empty store → authorization required.
        let home3 = try makeHome()
        defer { try? FileManager.default.removeItem(at: home3) }
        let manager3 = makeManager(transport: transport, home: home3)
        await #expect(throws: MCPAuthError.authorizationRequired) {
            _ = try await manager3.getAccessToken()
        }
    }
}

// MARK: - Callback parsing (oauth.rs tests, ported)

@Suite("MCP OAuth callback parsing")
struct MCPOAuthCallbackTests {
    @Test("callback parses code, state, and RFC 9207 iss")
    func parsesAll() throws {
        let got = try mcpParseOAuthCallbackParams([
            "code": "auth-code", "state": "csrf", "iss": "https://auth.example.com",
        ]).get()
        #expect(got.code == "auth-code")
        #expect(got.state == "csrf")
        #expect(got.issuer == "https://auth.example.com")
    }

    @Test("iss stays optional for legacy servers")
    func issOptional() throws {
        let got = try mcpParseOAuthCallbackParams(["code": "c", "state": "s"]).get()
        #expect(got.issuer == nil)
    }

    @Test("code and state are required")
    func requiresCodeAndState() {
        #expect(mcpParseOAuthCallbackParams(["state": "s"])
            == .failure(MCPOAuthFlowError("Missing authorization code")))
        #expect(mcpParseOAuthCallbackParams(["code": "c"])
            == .failure(MCPOAuthFlowError("Missing state parameter")))
    }

    @Test("an OAuth error surfaces with upstream's copy")
    func surfacesError() {
        #expect(mcpParseOAuthCallbackParams([
            "error": "access_denied", "error_description": "user said no",
        ]) == .failure(MCPOAuthFlowError("OAuth error: access_denied - user said no")))
    }
}

// MARK: - Browser flow with the REAL listener

@Suite("MCP OAuth browser flow", .serialized)
struct MCPOAuthBrowserFlowTests {
    @Test("full flow: fake browser drives the real listener; tokens land on disk")
    func endToEndFlow() async throws {
        let transport = scriptedAuthServer { fields in
            #expect(fields["grant_type"] == "authorization_code")
            return jsonResponse(200, [
                "access_token": "at-flow",
                "token_type": "Bearer",
                "expires_in": 3600,
                "refresh_token": "rt-flow",
            ])
        }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let browser: @Sendable (URL) -> Void = { authURL in
            // The REAL listener's port travels in the redirect_uri.
            guard let redirect = queryValue(authURL, "redirect_uri"),
                  let redirectURL = URL(string: redirect),
                  let port = redirectURL.port,
                  let state = queryValue(authURL, "state") else { return }
            // No #expect in here: the block runs off the test's task context.
            // The success-page copy is pinned by `listenerRouting` below.
            DispatchQueue.global().async {
                socketGET(
                    port: UInt16(port),
                    target: "/callback?code=mock-code&state=\(state)"
                )
            }
        }

        try await mcpAuthenticateServer(
            serverName: "flow",
            serverURL: serverURL,
            home: home,
            transport: transport,
            byoConfig: nil,
            force: true,
            openBrowser: browser,
            timeoutSeconds: 30,
            singleFlight: MCPOAuthSingleFlight()
        )

        // The reachability proof is the REAL store file.
        let data = try Data(contentsOf: MCPCredentialStore.defaultPath(home: home))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require(object["flow:\(asBase)/mcp"] as? [String: Any])
        let tokenObject = try #require(entry["token_response"] as? [String: Any])
        #expect(tokenObject["access_token"] as? String == "at-flow")
        #expect(tokenObject["refresh_token"] as? String == "rt-flow")
    }

    @Test("a stray probe does not consume the wait; POST /callback is decisive")
    func listenerRouting() async throws {
        let listener = try MCPOAuthLoopbackListener(port: 0)
        defer { listener.closeListener() }
        let port = listener.port

        let waiter = Task {
            try await listener.awaitCallback(timeoutSeconds: 30)
        }
        // Give the accept loop a beat, then probe an unknown path (must 404
        // and keep waiting) followed by the decisive POST (upstream routes
        // GET and POST, oauth.rs:584).
        try await Task.sleep(nanoseconds: 100_000_000)
        let probe = socketGET(port: port, target: "/favicon.ico")
        #expect(probe.contains("404"))
        let response = socketGET(
            port: port, target: "/callback?code=c1&state=s1", method: "POST")
        #expect(response.contains("Authorization Complete"))

        let payload = try await waiter.value
        #expect(payload.code == "c1")
        #expect(payload.state == "s1")
    }

    @Test("a denied consent renders the failure page and fails the flow")
    func deniedConsent() async throws {
        let listener = try MCPOAuthLoopbackListener(port: 0)
        defer { listener.closeListener() }
        let port = listener.port

        let waiter = Task {
            try await listener.awaitCallback(timeoutSeconds: 30)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let body = socketGET(
            port: port,
            target: "/callback?error=access_denied&error_description=user%20said%20no"
        )
        #expect(body.contains("Authorization Failed"))

        await #expect(throws: MCPOAuthFlowError(
            "OAuth callback failed: OAuth error: access_denied - user said no"
        )) {
            _ = try await waiter.value
        }
    }

    @Test("refresh-first: a working refresh token never opens the browser")
    func refreshFirst() async throws {
        let browserOpened = LockedBox<Bool>(false)
        let transport = scriptedAuthServer { fields in
            #expect(fields["grant_type"] == "refresh_token")
            return jsonResponse(200, [
                "access_token": "at-refreshed", "token_type": "bearer", "expires_in": 3600,
            ])
        }
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try MCPCredentialStore.insertAndSave(
            home: home, serverName: "flow", serverURL: serverURL,
            credentials: MCPStoredCredentials(
                clientId: "c",
                tokenResponse: MCPOAuthTokenResponse(
                    accessToken: "at-old", refreshToken: "rt-good"),
                tokenReceivedAt: 1_000
            )
        )

        try await mcpAuthenticateServer(
            serverName: "flow",
            serverURL: serverURL,
            home: home,
            transport: transport,
            byoConfig: nil,
            force: true,
            openBrowser: { _ in browserOpened.mutate { $0 = true } },
            timeoutSeconds: 5,
            singleFlight: MCPOAuthSingleFlight()
        )
        #expect(!browserOpened.value)

        let stored = try MCPFileCredentialStorage(
            home: home, serverName: "flow", serverURL: serverURL
        ).load()
        #expect(stored?.tokenResponse?.accessToken == "at-refreshed")
    }
}

// MARK: - Tiny lock box

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
