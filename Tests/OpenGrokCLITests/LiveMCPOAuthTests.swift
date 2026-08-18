// LiveMCPOAuthTests.swift
//
// MCP OAuth through the live seams (AGENTS.md §3): `open-grok mcp login`
// runs the REAL browser flow — real loopback listener, fake browser driving
// it over an actual socket, a real HTTP authorization+MCP server on
// 127.0.0.1 — and persists tokens into the REAL
// `$OPENGROK_HOME/mcp_credentials.json`; then the session connect path
// (`LiveMCPComposition.connectConfiguredServers`, the exact function
// `LiveComposition` calls at session start) attaches those tokens and the
// server's tools land in the advertised toolset. `/mcps` rendering is
// asserted through `LiveMCPStatusOverlay.lines`, the painter's input.
//
// Hermeticity: every endpoint is pinned to the test server or a dead
// loopback port; homes are isolated; assertions parse JSON.

import Foundation
import COpenGrokSockets
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokMCP
import OpenGrokShared
import OpenGrokTestSupport
import OpenGrokToolRegistry
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

// MARK: - Mock OAuth-protected MCP server

/// One real HTTP server playing both roles: the OAuth authorization server
/// (RFC 8414 well-known + DCR + token endpoint) and an MCP streamable-HTTP
/// server whose every JSON-RPC POST requires `Bearer at-live`.
private final class OAuthMCPHandler: HttpRequestHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var mcpAuthorizationHeaders: [String?] = []
    /// Set after start() so the metadata can carry absolute URLs.
    private var base = ""

    func setBase(_ base: String) {
        lock.lock(); self.base = base; lock.unlock()
    }

    var seenMCPAuthorizations: [String?] {
        lock.lock(); defer { lock.unlock() }
        return mcpAuthorizationHeaders
    }

    func handle(_ request: HttpRequest) -> HttpResponse {
        let currentBase: String = {
            lock.lock(); defer { lock.unlock() }
            return base
        }()
        switch (request.method, request.pathOnly) {
        case ("GET", "/mcp"):
            // The discovery probe: 401 with no resource metadata steers the
            // manager to the direct well-known ladder.
            return HttpResponse(status: 401, body: .bytes(Data()))
        case ("GET", "/.well-known/oauth-authorization-server/mcp"):
            let metadata = """
            {"authorization_endpoint":"http://127.0.0.1:9/authorize",\
            "token_endpoint":"\(currentBase)/token",\
            "registration_endpoint":"\(currentBase)/register"}
            """
            return HttpResponse(
                status: 200,
                headers: [("content-type", "application/json")],
                body: .bytes(Data(metadata.utf8))
            )
        case ("POST", "/register"):
            return HttpResponse(
                status: 201,
                headers: [("content-type", "application/json")],
                body: .bytes(Data(#"{"client_id":"live-client","redirect_uris":[]}"#.utf8))
            )
        case ("POST", "/token"):
            let token = """
            {"access_token":"at-live","token_type":"Bearer","expires_in":3600,\
            "refresh_token":"rt-live"}
            """
            return HttpResponse(
                status: 200,
                headers: [("content-type", "application/json")],
                body: .bytes(Data(token.utf8))
            )
        case ("POST", "/mcp"):
            let authorization = request.header("Authorization")
            lock.lock()
            mcpAuthorizationHeaders.append(authorization)
            lock.unlock()
            guard authorization == "Bearer at-live" else {
                return HttpResponse(status: 401, body: .bytes(Data()))
            }
            return mcpReply(request)
        default:
            return .notFound
        }
    }

    private func mcpReply(
        _ request: HttpRequest
    ) -> HttpResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let method = object["method"] as? String else {
            return HttpResponse(status: 400, body: .bytes(Data()))
        }
        // Notifications get an empty 202.
        guard let id = object["id"] else {
            return HttpResponse(status: 202, body: .bytes(Data()))
        }
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "live", "version": "1.0.0"],
            ]
        case "tools/list":
            result = [
                "tools": [[
                    "name": "echo",
                    "description": "Echo the supplied text.",
                    "inputSchema": ["type": "object"] as [String: Any],
                ]],
            ]
        case "shutdown":
            result = [:]
        default:
            result = [:]
        }
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        return HttpResponse(
            status: 200,
            headers: [("content-type", "application/json")],
            body: .bytes(data)
        )
    }
}

// MARK: - Helpers

private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-live-mcp-oauth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func makeToolset() -> FinalizedToolset {
    FinalizedToolset(
        tools: [],
        resources: ToolResources(
            cwd: NSTemporaryDirectory(),
            permissionPipeline: PermissionPipeline(
                permissions: PermissionHandle(allowAll: true, shellCwd: NSTemporaryDirectory()),
                hooks: FailOpenPreToolUseHookRunner(inner: nil)
            )
        ),
        codeModeNamespaces: [:],
        options: .unrestricted
    )
}

@discardableResult
private func socketGET(port: UInt16, target: String) -> String {
    var handle: OGSocketHandle = -1
    let connected = "127.0.0.1".withCString {
        og_socket_tcp_connect($0, port, 5.0, &handle)
    }
    guard connected == 0 else { return "" }
    defer { _ = og_socket_close(handle) }

    let request = "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
    let requestData = Data(request.utf8)
    let written = requestData.withUnsafeBytes {
        og_socket_write_all(handle, $0.baseAddress, $0.count)
    }
    guard written == Int64(requestData.count) else { return "" }

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = buffer.withUnsafeMutableBytes {
            og_socket_read(handle, $0.baseAddress, $0.count)
        }
        if count <= 0 { break }
        response.append(contentsOf: buffer.prefix(Int(count)))
    }
    return String(decoding: response, as: UTF8.self)
}

private func queryValue(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == name })?.value
}

private func writeConfig(home: URL, serverName: String, url: String) throws {
    let config = """
    [mcpServers.\(serverName)]
    url = "\(url)"
    """
    try config.write(
        to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
}

// MARK: - Tests

@Suite("MCP OAuth live seam", .serialized)
struct LiveMCPOAuthTests {
    @Test("mcp login + session connect: tokens flow end to end and tools are advertised")
    func loginThenConnect() async throws {
        let handler = OAuthMCPHandler()
        let server = HttpServer(handler: handler, basePath: "")
        try server.start()
        defer { server.stop() }
        handler.setBase(server.baseURL)
        let mcpURL = "\(server.baseURL)/mcp"

        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeConfig(home: home, serverName: "live", url: mcpURL)
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]

        // 1. The explicit trigger: `open-grok mcp login live`, with the fake
        //    browser delivering consent to the REAL loopback listener.
        let out = BufferedStream()
        let streams = CLIStreams(out: { out.write($0) }, err: { _ in })
        let browser: @Sendable (URL) -> Void = { authURL in
            guard let redirect = queryValue(authURL, "redirect_uri"),
                  let redirectURL = URL(string: redirect),
                  let port = redirectURL.port,
                  let state = queryValue(authURL, "state") else { return }
            DispatchQueue.global().async {
                socketGET(
                    port: UInt16(port),
                    target: "/callback?code=live-code&state=\(state)"
                )
            }
        }
        try await LiveMCPComposition.runLogin(
            options: CLIResourceOptions(action: "login", target: "live"),
            environment: environment,
            streams: streams,
            cwd: FileManager.default.temporaryDirectory,
            openBrowser: browser,
            timeoutSeconds: 30
        )
        #expect(out.contents.contains("Authenticated MCP server 'live'."))

        // 2. The tokens are on disk in the rmcp shape — parse the real file.
        let storePath = home.appendingPathComponent("mcp_credentials.json")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: storePath)) as? [String: Any])
        let entry = try #require(object["live:\(mcpURL)"] as? [String: Any])
        #expect(entry["client_id"] as? String == "live-client")
        let token = try #require(entry["token_response"] as? [String: Any])
        #expect(token["access_token"] as? String == "at-live")

        // 3. The session connect path — the same call LiveComposition makes —
        //    attaches the stored token and the tools reach the advertised set.
        let document = try parseTOML("""
        [mcpServers.live]
        url = "\(mcpURL)"
        """)
        let toolset = makeToolset()
        let connections = MCPSessionConnections()
        let results = await LiveMCPComposition.connectConfiguredServers(
            document: document,
            toolset: toolset,
            connections: connections,
            environment: environment
        )
        defer { Task { await connections.shutdown() } }

        #expect(results.count == 1)
        let connection = try #require(results.first)
        #expect(connection.failure == nil)
        #expect(connection.toolNames == ["live__echo"])
        // Reachability contract: the tool is in the set the model is offered.
        #expect(toolset.topLevelDefinitions().contains { $0.name == "live__echo" })

        // 4. `/mcps` renders the connection.
        let lines = LiveMCPStatusOverlay.lines(connections: results)
        #expect(lines.contains("● live — connected, 1 tool"))
        #expect(lines.contains("    live__echo"))

        // 5. Every MCP wire call carried the bearer token — header bytes.
        let seen = handler.seenMCPAuthorizations
        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy { $0 == "Bearer at-live" })
    }

    @Test("connecting an OAuth server with no stored token reports the login trigger")
    func connectWithoutTokens() async throws {
        let handler = OAuthMCPHandler()
        let server = HttpServer(handler: handler, basePath: "")
        try server.start()
        defer { server.stop() }
        handler.setBase(server.baseURL)
        let mcpURL = "\(server.baseURL)/mcp"

        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]

        let document = try parseTOML("""
        [mcpServers.live]
        url = "\(mcpURL)"
        """)
        let toolset = makeToolset()
        let connections = MCPSessionConnections()
        let results = await LiveMCPComposition.connectConfiguredServers(
            document: document,
            toolset: toolset,
            connections: connections,
            environment: environment
        )

        let connection = try #require(results.first)
        #expect(connection.failure
            == "authorization required — run `open-grok mcp login live` to sign in")
        // Nothing was advertised and nothing dialed the MCP endpoint with a
        // made-up token.
        #expect(toolset.topLevelDefinitions().isEmpty)
        #expect(handler.seenMCPAuthorizations.isEmpty)

        let lines = LiveMCPStatusOverlay.lines(connections: results)
        #expect(lines.contains(
            "✗ live — authorization required — run `open-grok mcp login live` to sign in"))
    }

    @Test("a static Authorization header skips OAuth entirely")
    func staticHeaderSkipsOAuth() async throws {
        let handler = OAuthMCPHandler()
        let server = HttpServer(handler: handler, basePath: "")
        try server.start()
        defer { server.stop() }
        handler.setBase(server.baseURL)
        let mcpURL = "\(server.baseURL)/mcp"

        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]

        // The configured header IS the auth: upstream never probes OAuth for
        // such servers (servers.rs:4294-4304). "at-live" is what the mock
        // accepts, so the connection must succeed with zero OAuth traffic.
        let document = try parseTOML("""
        [mcpServers.live]
        url = "\(mcpURL)"
        [mcpServers.live.headers]
        Authorization = "Bearer at-live"
        """)
        let toolset = makeToolset()
        let connections = MCPSessionConnections()
        let results = await LiveMCPComposition.connectConfiguredServers(
            document: document,
            toolset: toolset,
            connections: connections,
            environment: environment
        )
        defer { Task { await connections.shutdown() } }

        let connection = try #require(results.first)
        #expect(connection.failure == nil)
        #expect(connection.toolNames == ["live__echo"])
        // No credential store was created: OAuth never ran.
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent("mcp_credentials.json").path))
    }

    @Test("the parser routes `mcp login <name>` and the sync runner refuses it honestly")
    func parserAndSyncSurface() throws {
        let command = CLICommandParser.parse(
            ["mcp", "login", "live"], environment: [:])
        guard case .mcp(let options) = command else {
            Issue.record("expected an mcp command, got \(command)")
            return
        }
        #expect(options.action == "login")
        #expect(options.target == "live")

        // The synchronous `run` surface (CLIRunner.main) cannot host the
        // interactive flow; it must say so rather than claim "unknown".
        #expect(throws: CLIApplicationError.self) {
            try LiveMCPComposition.run(
                options: options,
                environment: ["HOME": "/nonexistent"],
                streams: CLIStreams(out: { _ in }, err: { _ in })
            )
        }
    }
}
