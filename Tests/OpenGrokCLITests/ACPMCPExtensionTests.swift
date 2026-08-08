// ACPMCPExtensionTests.swift
//
// The `x.ai/mcp/*` ACP extension family (Wave 15 item 3), asserted at the
// live seams (AGENTS.md §3):
//
//   * The handler under test is the SAME `LiveMCPACPHandler` the live
//     composition installs, built over a REAL MCP server on 127.0.0.1
//     (mock `HttpServer` speaking streamable-HTTP JSON-RPC), the REAL
//     connect path (`LiveMCPComposition.connectConfiguredServers`), a real
//     toolset, and the REAL trust-gated declaration source reading the
//     isolated home's `config.toml`.
//   * `auth_trigger` drives the REAL E7 OAuth flow: real loopback callback
//     listener, fake browser delivering consent over an actual socket, a
//     real authorization+MCP server requiring `Bearer at-live` — and then
//     asserts the tools landed in the RUNNING toolset and the tokens in the
//     real `$OPENGROK_HOME/mcp_credentials.json`.
//   * `upsert`/`delete` assert the CONFIG FILE after the call — the landed
//     TOML, not the handler's word for it — plus the live toolset mutation.
//   * One end-to-end leg runs over the real ws:// carrier (`ACPServeHost`
//     on a loopback socket), the same harness shape the credential-family
//     and notification-gateway suites use.
//
// Hermeticity: isolated homes, every endpoint pinned to a 127.0.0.1 mock,
// environments passed explicitly everywhere.

import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokMCP
import OpenGrokShared
import OpenGrokTestSupport
import OpenGrokToolRegistry
import OpenGrokWorkspace
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private typealias JSONValue = OpenGrokShared.JSONValue

// MARK: - Mock MCP servers

/// A plain (no-auth) streamable-HTTP MCP server: initialize, tools/list,
/// tools/call (echo) and resources/read, one JSON-RPC POST per message.
private final class PlainMCPHandler: HttpRequestHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var callArguments: [String] = []

    var seenCallArguments: [String] {
        lock.lock(); defer { lock.unlock() }
        return callArguments
    }

    func handle(_ request: HttpRequest) -> HttpResponse {
        guard request.method == "POST", request.pathOnly == "/mcp" else {
            return .notFound
        }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let method = object["method"] as? String else {
            return HttpResponse(status: 400, body: .bytes(Data()))
        }
        guard let id = object["id"] else {
            return HttpResponse(status: 202, body: .bytes(Data()))
        }
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "plain", "version": "1.0.0"],
            ]
        case "tools/list":
            result = [
                "tools": [[
                    "name": "echo",
                    "description": "Echo the supplied text.",
                    "inputSchema": ["type": "object"] as [String: Any],
                ]],
            ]
        case "tools/call":
            let params = object["params"] as? [String: Any]
            let arguments = params?["arguments"] as? [String: Any]
            let text = arguments?["text"] as? String ?? ""
            lock.lock()
            callArguments.append(text)
            lock.unlock()
            result = [
                "content": [["type": "text", "text": "echo:\(text)"]],
                "isError": false,
            ]
        case "resources/read":
            let params = object["params"] as? [String: Any]
            let uri = params?["uri"] as? String ?? ""
            result = [
                "contents": [[
                    "uri": uri,
                    "mimeType": "text/plain",
                    "text": "hello resource",
                ]],
            ]
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

/// The E7 mock: one server playing the OAuth authorization server (RFC 8414
/// well-known + DCR + token) AND a Bearer-gated MCP endpoint — the same
/// shape `LiveMCPOAuthTests` pins for `mcp login`.
private final class OAuthGatedMCPHandler: HttpRequestHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var base = ""

    func setBase(_ base: String) {
        lock.lock(); self.base = base; lock.unlock()
    }

    func handle(_ request: HttpRequest) -> HttpResponse {
        let currentBase: String = {
            lock.lock(); defer { lock.unlock() }
            return base
        }()
        switch (request.method, request.pathOnly) {
        case ("GET", "/mcp"):
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
            guard request.header("Authorization") == "Bearer at-live" else {
                return HttpResponse(status: 401, body: .bytes(Data()))
            }
            guard let object = try? JSONSerialization.jsonObject(with: request.body)
                as? [String: Any],
                let method = object["method"] as? String else {
                return HttpResponse(status: 400, body: .bytes(Data()))
            }
            guard let id = object["id"] else {
                return HttpResponse(status: 202, body: .bytes(Data()))
            }
            let result: [String: Any]
            switch method {
            case "initialize":
                result = [
                    "protocolVersion": "2025-06-18",
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": ["name": "gated", "version": "1.0.0"],
                ]
            case "tools/list":
                result = [
                    "tools": [[
                        "name": "echo",
                        "description": "Echo the supplied text.",
                        "inputSchema": ["type": "object"] as [String: Any],
                    ]],
                ]
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
        default:
            return .notFound
        }
    }
}

// MARK: - Helpers

private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-acp-mcp-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func pinnedEnvironment(home: URL) -> [String: String] {
    ["OPENGROK_HOME": home.path, "HOME": home.path]
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
    #if canImport(Darwin)
    let streamType = SOCK_STREAM
    #else
    let streamType = Int32(SOCK_STREAM.rawValue)
    #endif
    let fd = socket(AF_INET, streamType, 0)
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
    let request = "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
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

private func queryValue(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == name })?.value
}

/// One hermetic MCP-family fixture: isolated home whose `config.toml`
/// declares the given servers, the REAL connect path bringing them online
/// into a real toolset, the LIVE handler over the resulting state, and a
/// real `ACPAgentRuntime` (initialize + session/new performed) so the
/// session gates are exercised against the store the runtime actually
/// serves.
private struct MCPFamilyHarness {
    let home: URL
    let environment: [String: String]
    let toolset: FinalizedToolset
    let connections: MCPSessionConnections
    let state: LiveMCPACPState
    let handler: LiveMCPACPHandler
    let runtime: ACPAgentRuntime
    let gateway: ACPNotificationGateway
    let sessionID: String
    /// The initialize RESPONSE result from the harness's own handshake —
    /// the runtime's state machine refuses a second `initialize`, so
    /// meta-advertisement pins must read this capture.
    let initializeResult: JSONValue

    static func start(
        configTOML: String,
        openBrowser: (@Sendable (URL) -> Void)? = nil,
        authTimeoutSeconds: TimeInterval = 30
    ) async throws -> MCPFamilyHarness {
        let home = try makeHome()
        try configTOML.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let environment = pinnedEnvironment(home: home)

        // The REAL session-time connect: same function, same trust-gated
        // document source the live composition uses.
        let declarations = LiveMCPACPHandler.trustGatedDeclarationSource(
            workspaceRoot: home,
            environment: environment,
            cli: CLIPermissionOptions()
        )
        let toolset = makeToolset()
        let connections = MCPSessionConnections()
        var outcomes: [MCPServerConnection] = []
        for declaration in declarations().enabledServers {
            outcomes.append(await LiveMCPComposition.connect(
                declaration: declaration,
                toolset: toolset,
                connections: connections,
                environment: environment
            ))
        }

        let gateway = ACPNotificationGateway()
        let state = LiveMCPACPState(
            connections: connections,
            toolset: toolset,
            outcomes: outcomes
        )
        let handler = LiveMCPACPHandler(
            gateway: gateway,
            state: state,
            declarations: declarations,
            userConfigPath: home.appendingPathComponent("config.toml"),
            openGrokHome: home,
            environment: environment,
            openBrowser: openBrowser,
            authTimeoutSeconds: authTimeoutSeconds
        )
        let catalogStore = LiveModelCatalogStore(
            input: .default,
            environment: environment,
            openGrokHome: home,
            transport: MockHTTPTransport(responses: [])
        )
        let router = LiveACPExtensionRouter.build(
            feedback: nil,
            models: LiveModelsACPHandler(catalogStore: catalogStore, modelSwitch: nil),
            mcp: handler
        )
        let runtime = ACPAgentRuntime(extensionRouter: router)
        await gateway.attach(runtime)

        let initOutput = await runtime.handle(.request(
            id: .string("init"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, let initResult?, nil) = initOutput[0] else {
            throw ACPTransportError.invalidMessage("initialize failed: \(initOutput)")
        }
        let newOutput = await runtime.handle(.request(
            id: .string("new"),
            method: AgentMethodNames.sessionNew,
            params: .object(["cwd": .string(home.path), "mcpServers": .array([])])
        ))
        guard case .response(_, let newResult?, nil) = newOutput[0],
              let sessionID = newResult["sessionId"]?.stringValue else {
            throw ACPTransportError.invalidMessage("session/new failed: \(newOutput)")
        }

        return MCPFamilyHarness(
            home: home,
            environment: environment,
            toolset: toolset,
            connections: connections,
            state: state,
            handler: handler,
            runtime: runtime,
            gateway: gateway,
            sessionID: sessionID,
            initializeResult: initResult
        )
    }

    func call(
        _ method: String,
        id: String,
        params: JSONValue = .object([:])
    ) async -> (result: JSONValue?, error: AcpError?) {
        let output = await runtime.handle(.request(
            id: .string(id),
            method: method,
            params: params
        ))
        guard case .response(_, let result, let error) = output[0] else {
            return (nil, AcpError.internalError("no response for \(method)"))
        }
        return (result, error)
    }

    func shutdown() async {
        await connections.shutdown()
        try? FileManager.default.removeItem(at: home)
    }
}

// MARK: - Catalog / call / resource

@Suite("ACP x.ai/mcp family", .serialized)
struct ACPMCPExtensionTests {
    @Test("mcp/list without a session returns the plain catalog; with the live session it annotates state and tools")
    func listCatalogAndAnnotation() async throws {
        let mcp = PlainMCPHandler()
        let server = HttpServer(handler: mcp, basePath: "")
        try server.start()
        defer { server.stop() }
        let harness = try await MCPFamilyHarness.start(configTOML: """
        [mcpServers.plain]
        url = "\(server.baseURL)/mcp"
        """)
        defer { Task { await harness.shutdown() } }

        // Plain catalog: no session annotation without a sessionId.
        let (plain, plainError) = await harness.call("x.ai/mcp/list", id: "l1")
        #expect(plainError == nil)
        let plainServers = try #require(plain?["result"]?["servers"]?.arrayValue)
        #expect(plainServers.count == 1)
        #expect(plainServers[0]["name"]?.stringValue == "plain")
        #expect(plainServers[0]["source"]?.stringValue == "local")
        #expect(plainServers[0]["type"]?.stringValue == "http")
        #expect(plainServers[0]["url"]?.stringValue == "\(server.baseURL)/mcp")
        #expect(plainServers[0]["session"] == nil)

        // Unknown session: upstream logs and returns the plain catalog,
        // never an error (mcp.rs:932-937).
        let (unknown, unknownError) = await harness.call(
            "x.ai/mcp/list",
            id: "l2",
            params: .object(["sessionId": .string("no-such-session")])
        )
        #expect(unknownError == nil)
        #expect(unknown?["result"]?["servers"]?[0]?["session"] == nil)

        // The live session annotates: enabled, ready, unqualified tool names.
        let (annotated, annotatedError) = await harness.call(
            "x.ai/mcp/list",
            id: "l3",
            params: .object(["sessionId": .string(harness.sessionID)])
        )
        #expect(annotatedError == nil)
        let session = try #require(annotated?["result"]?["servers"]?[0]?["session"])
        #expect(session["enabled"]?.boolValue == true)
        #expect(session["status"]?.stringValue == "ready")
        let tools = try #require(session["tools"]?.arrayValue)
        #expect(tools.count == 1)
        #expect(tools[0]["name"]?.stringValue == "echo")
        #expect(tools[0]["enabled"]?.boolValue == true)
        #expect(tools[0]["description"]?.stringValue == "Echo the supplied text.")
    }

    @Test("mcp/call invokes the real tool outside the LLM loop and mirrors upstream's response shape")
    func callEndToEnd() async throws {
        let mcp = PlainMCPHandler()
        let server = HttpServer(handler: mcp, basePath: "")
        try server.start()
        defer { server.stop() }
        let harness = try await MCPFamilyHarness.start(configTOML: """
        [mcpServers.plain]
        url = "\(server.baseURL)/mcp"
        """)
        defer { Task { await harness.shutdown() } }

        let (result, error) = await harness.call(
            "x.ai/mcp/call",
            id: "c1",
            params: .object([
                "sessionId": .string(harness.sessionID),
                "server": .string("plain"),
                "tool": .string("echo"),
                "arguments": .object(["text": .string("over-acp")]),
            ])
        )
        #expect(error == nil)
        let payload = try #require(result?["result"])
        #expect(payload["content"]?[0]?["type"]?.stringValue == "text")
        #expect(payload["content"]?[0]?["text"]?.stringValue == "echo:over-acp")
        #expect(payload["isError"]?.boolValue == false)
        // The REAL server saw the call — not a stub answering for it.
        #expect(mcp.seenCallArguments == ["over-acp"])

        // Unknown server: upstream's copy (mcp.rs:862).
        let (missing, missingError) = await harness.call(
            "x.ai/mcp/call",
            id: "c2",
            params: .object(["server": .string("ghost"), "tool": .string("echo")])
        )
        #expect(missing == nil)
        #expect(missingError?.code == .internalError)
        #expect(missingError?.data == .string("server 'ghost' not found"))

        // Unknown session: invalid_params "session not found" (mcp.rs:1201).
        let (_, sessionError) = await harness.call(
            "x.ai/mcp/call",
            id: "c3",
            params: .object([
                "sessionId": .string("nope"),
                "server": .string("plain"),
                "tool": .string("echo"),
            ])
        )
        #expect(sessionError?.code == .invalidParams)
        #expect(sessionError?.data == .string("session not found"))
    }

    @Test("mcp/read_resource reads through the live client")
    func readResource() async throws {
        let mcp = PlainMCPHandler()
        let server = HttpServer(handler: mcp, basePath: "")
        try server.start()
        defer { server.stop() }
        let harness = try await MCPFamilyHarness.start(configTOML: """
        [mcpServers.plain]
        url = "\(server.baseURL)/mcp"
        """)
        defer { Task { await harness.shutdown() } }

        let (result, error) = await harness.call(
            "x.ai/mcp/read_resource",
            id: "r1",
            params: .object([
                "server": .string("plain"),
                "uri": .string("mem://greeting"),
            ])
        )
        #expect(error == nil)
        let contents = try #require(result?["result"]?["contents"]?.arrayValue)
        #expect(contents.count == 1)
        #expect(contents[0]["uri"]?.stringValue == "mem://greeting")
        #expect(contents[0]["mimeType"]?.stringValue == "text/plain")
        #expect(contents[0]["text"]?.stringValue == "hello resource")
        #expect(contents[0]["blob"] == nil)
    }

    // MARK: Refusals under the prefix

    @Test("initialize _meta does not advertise the unimplemented x.ai/mcp/sdk reverse bridge")
    func initializeMetaDoesNotAdvertiseSDKBridge() async throws {
        // Upstream advertises `"x.ai/mcp/sdk": true` (acp_agent.rs:700-702,
        // wire.rs:25-27) because it CAN drive in-process SDK MCP servers
        // over the reverse `x.ai/mcp/sdk_call` channel. This port cannot
        // (LiveMCPACPHandlers.swift header), and the SDK enables
        // `transport="acp"` on that flag alone — so its absence is
        // load-bearing, not an omission. This pin fails the moment someone
        // advertises the flag without landing the bridge.
        let harness = try await MCPFamilyHarness.start(configTOML: "")
        defer { Task { await harness.shutdown() } }
        // The harness's own handshake response — the runtime's state
        // machine refuses a second initialize, so the pin reads the
        // captured result.
        let result = harness.initializeResult
        #expect(result["meta"]?["x.ai/mcp/sdk"] == nil)
        #expect(result["_meta"]?["x.ai/mcp/sdk"] == nil)
    }

    @Test("setup/toggle/toggle_tool are refused with the terminal error; unknown prefix names (incl. inbound sdk_call) get upstream's bare method_not_found")
    func prefixRefusals() async throws {
        let harness = try await MCPFamilyHarness.start(configTOML: "")
        defer { Task { await harness.shutdown() } }

        // Upstream serves these; the port refuses with the data-carrying
        // terminal error so "not ported" is distinguishable.
        for (index, method) in ["x.ai/mcp/setup", "x.ai/mcp/toggle", "x.ai/mcp/toggle_tool"]
            .enumerated() {
            let (result, error) = await harness.call(method, id: "ref-\(index)")
            #expect(result == nil, "\(method)")
            #expect(error?.code == .methodNotFound, "\(method)")
            #expect(
                error?.data == .string("unknown ACP extension method: \(method)"),
                "\(method)"
            )
        }

        // Upstream's OWN refusal for unknown names under the prefix — bare
        // method_not_found, NO data (mcp.rs:387; the sdk_call regression
        // pin, mcp.rs:1952-1965). The emit-only reverse method must never
        // resolve to a forward handler.
        for (index, method) in ["x.ai/mcp/sdk_call", "x.ai/mcp/definitely_not_real"]
            .enumerated() {
            let (result, error) = await harness.call(method, id: "bare-\(index)")
            #expect(result == nil, "\(method)")
            #expect(error?.code == .methodNotFound, "\(method)")
            #expect(error?.message == "Method not found", "\(method)")
            #expect(error?.data == nil, "\(method) must carry no data")
        }
    }

    // MARK: auth_status / auth_trigger (the real E7 flow)

    @Test("auth_status reports needs_auth, auth_trigger runs the real OAuth flow, stores tokens, and registers the tools live")
    func authTriggerEndToEnd() async throws {
        let gated = OAuthGatedMCPHandler()
        let server = HttpServer(handler: gated, basePath: "")
        try server.start()
        defer { server.stop() }
        gated.setBase(server.baseURL)
        let mcpURL = "\(server.baseURL)/mcp"

        // The fake browser drives the REAL loopback callback listener the
        // flow opens — consent over an actual socket, the E7 pattern.
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
        let harness = try await MCPFamilyHarness.start(
            configTOML: """
            [mcpServers.gated]
            url = "\(mcpURL)"
            """,
            openBrowser: browser
        )
        defer { Task { await harness.shutdown() } }

        // The connect path deferred OAuth: no client, no tools, and
        // auth_status says so.
        #expect(harness.toolset.topLevelDefinitions().isEmpty)
        let (before, beforeError) = await harness.call(
            "x.ai/mcp/auth_status",
            id: "as1",
            params: .object(["session_id": .string(harness.sessionID)])
        )
        #expect(beforeError == nil)
        let beforeServers = try #require(before?["result"]?["servers"]?.arrayValue)
        #expect(beforeServers.count == 1)
        #expect(beforeServers[0]["server_name"]?.stringValue == "gated")
        #expect(beforeServers[0]["status"]?.stringValue == "needs_auth")

        // The trigger: REAL browser flow, REAL listener, REAL token store.
        let (triggered, triggerError) = await harness.call(
            "x.ai/mcp/auth_trigger",
            id: "at1",
            params: .object([
                "session_id": .string(harness.sessionID),
                "server_name": .string("gated"),
            ])
        )
        #expect(triggerError == nil)
        #expect(triggered?["result"]?["status"]?.stringValue == "authenticated")
        #expect(triggered?["result"]?["error"] == nil)

        // The store write landed — parse the real credentials file.
        let storePath = harness.home.appendingPathComponent("mcp_credentials.json")
        let stored = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: storePath)) as? [String: Any])
        let entry = try #require(stored["gated:\(mcpURL)"] as? [String: Any])
        let token = try #require(entry["token_response"] as? [String: Any])
        #expect(token["access_token"] as? String == "at-live")

        // Reachability: the tools are in the RUNNING toolset now — what the
        // model is actually offered, not a composition mirror.
        #expect(harness.toolset.topLevelDefinitions().contains { $0.name == "gated__echo" })

        // And auth_status clears.
        let (after, _) = await harness.call(
            "x.ai/mcp/auth_status",
            id: "as2",
            params: .object(["session_id": .string(harness.sessionID)])
        )
        #expect(after?["result"]?["servers"]?.arrayValue?.isEmpty == true)
    }

    @Test("auth_trigger refusal arms ride inside the payload with upstream's copy")
    func authTriggerRefusalArms() async throws {
        let harness = try await MCPFamilyHarness.start(configTOML: """
        [mcpServers.local]
        command = "/usr/bin/true"
        """)
        defer { Task { await harness.shutdown() } }
        let sid = harness.sessionID

        // Managed prefix → grok.com (acp_session_impl/mcp.rs:406-408).
        let (managed, _) = await harness.call(
            "x.ai/mcp/auth_trigger",
            id: "arm1",
            params: .object([
                "session_id": .string(sid), "server_name": .string("grok_com_linear"),
            ])
        )
        #expect(managed?["result"]?["status"]?.stringValue == "failed")
        #expect(managed?["result"]?["error"]?.stringValue == "To authenticate, visit grok.com")

        // Not configured (acp_session_impl/mcp.rs:459).
        let (missing, _) = await harness.call(
            "x.ai/mcp/auth_trigger",
            id: "arm2",
            params: .object([
                "session_id": .string(sid), "server_name": .string("ghost"),
            ])
        )
        #expect(missing?["result"]?["status"]?.stringValue == "failed")
        #expect(missing?["result"]?["error"]?.stringValue
            == "MCP server 'ghost' not found in config")

        // Stdio server (acp_session_impl/mcp.rs:460-465).
        let (stdio, _) = await harness.call(
            "x.ai/mcp/auth_trigger",
            id: "arm3",
            params: .object([
                "session_id": .string(sid), "server_name": .string("local"),
            ])
        )
        #expect(stdio?["result"]?["status"]?.stringValue == "failed")
        #expect(stdio?["result"]?["error"]?.stringValue
            == "MCP server 'local' does not use OAuth")

        // Missing session is the only protocol error (mcp.rs:1531).
        let (_, sessionError) = await harness.call(
            "x.ai/mcp/auth_trigger",
            id: "arm4",
            params: .object([
                "session_id": .string("nope"), "server_name": .string("local"),
            ])
        )
        #expect(sessionError?.code == .invalidParams)
        #expect(sessionError?.data == .string("session not found"))
    }

    // MARK: upsert / delete — the config writes

    @Test("upsert persists to config.toml and live-connects; delete removes the config entry and tears the server down")
    func upsertThenDelete() async throws {
        let mcp = PlainMCPHandler()
        let server = HttpServer(handler: mcp, basePath: "")
        try server.start()
        defer { server.stop() }
        let harness = try await MCPFamilyHarness.start(configTOML: "")
        defer { Task { await harness.shutdown() } }
        let configPath = harness.home.appendingPathComponent("config.toml")

        // Before: nothing configured, nothing advertised.
        #expect(harness.toolset.topLevelDefinitions().isEmpty)

        let (upserted, upsertError) = await harness.call(
            "x.ai/mcp/upsert",
            id: "u1",
            params: .object([
                "session_id": .string(harness.sessionID),
                "server_name": .string("added"),
                "url": .string("\(server.baseURL)/mcp"),
            ])
        )
        #expect(upsertError == nil)
        #expect(upserted?["result"]?["ok"]?.boolValue == true)

        // The write landed in the real file: the declaration is readable
        // back through the same loader the session connect uses.
        let written = try String(contentsOf: configPath, encoding: .utf8)
        #expect(written.contains("added"), "config.toml must carry the server: \(written)")
        let reloaded = LiveMCPComposition.loadForEdit(at: configPath)
            .map { MCPConfigLoader.load(from: $0) }
        #expect(reloaded?.servers.first?.name == "added")

        // The live half: tools registered into the running toolset, and a
        // session-annotated list shows the server ready.
        #expect(harness.toolset.topLevelDefinitions().contains { $0.name == "added__echo" })
        let (listed, _) = await harness.call(
            "x.ai/mcp/list",
            id: "u2",
            params: .object(["sessionId": .string(harness.sessionID)])
        )
        let row = try #require(listed?["result"]?["servers"]?.arrayValue?.first {
            $0["name"]?.stringValue == "added"
        })
        #expect(row["session"]?["status"]?.stringValue == "ready")

        // Delete: config entry removed, tools unregistered, client gone.
        let (deleted, deleteError) = await harness.call(
            "x.ai/mcp/delete",
            id: "d1",
            params: .object([
                "session_id": .string(harness.sessionID),
                "server_name": .string("added"),
            ])
        )
        #expect(deleteError == nil)
        #expect(deleted?["result"]?["ok"]?.boolValue == true)
        let afterDelete = LiveMCPComposition.loadForEdit(at: configPath)
            .map { MCPConfigLoader.load(from: $0) }
        #expect(afterDelete?.servers.isEmpty != false)
        #expect(!harness.toolset.topLevelDefinitions().contains { $0.name == "added__echo" })
        #expect(await harness.connections.names().isEmpty)

        // Deleting a never-configured name: upstream's copy, byte-exact
        // (mcp.rs:1919-1924).
        let (_, missingError) = await harness.call(
            "x.ai/mcp/delete",
            id: "d2",
            params: .object([
                "session_id": .string(harness.sessionID),
                "server_name": .string("added"),
            ])
        )
        #expect(missingError?.code == .invalidParams)
        #expect(missingError?.data == .string(
            "server 'added' not found in config.toml (only locally-configured servers can be deleted)"
        ))
    }

    @Test("upsert refuses a blank transport and a disabled config before touching the session")
    func upsertRefusals() async throws {
        let harness = try await MCPFamilyHarness.start(configTOML: "")
        defer { Task { await harness.shutdown() } }

        // Blank transport: refused before anything persists.
        let (_, blankError) = await harness.call(
            "x.ai/mcp/upsert",
            id: "ub1",
            params: .object([
                "session_id": .string(harness.sessionID),
                "server_name": .string("blank"),
                "url": .string(""),
            ])
        )
        #expect(blankError?.code == .invalidParams)
        let blankData = blankError?.data?.stringValue ?? ""
        #expect(blankData.hasPrefix("invalid params: "), "got \(blankData)")
        let configText = (try? String(
            contentsOf: harness.home.appendingPathComponent("config.toml"),
            encoding: .utf8
        )) ?? ""
        #expect(!configText.contains("blank"), "a refused upsert must not persist")

        // Disabled config: persists but cannot be live-added
        // (mcp.rs:1884-1887).
        let (_, disabledError) = await harness.call(
            "x.ai/mcp/upsert",
            id: "ub2",
            params: .object([
                "session_id": .string(harness.sessionID),
                "server_name": .string("dormant"),
                "url": .string("http://127.0.0.1:9/mcp"),
                "enabled": .bool(false),
            ])
        )
        #expect(disabledError?.code == .invalidParams)
        #expect(disabledError?.data == .string("server config is disabled"))
        let persisted = try String(
            contentsOf: harness.home.appendingPathComponent("config.toml"),
            encoding: .utf8
        )
        #expect(persisted.contains("dormant"), "the disabled config still persists: \(persisted)")
    }
}

// MARK: - ws:// carrier

private func wsConnect(
    to endpoint: ACPServeEndpoint,
    secret: String
) async throws -> ACPWebSocketConnectionTransport {
    let channel = try await WebSocketNetworkChannel.connect(
        host: endpoint.host,
        port: endpoint.port
    )
    let connection = try await WebSocketClientUpgrade.connect(
        channel: channel,
        host: endpoint.address,
        target: endpoint.path + "?server-key=\(secret)"
    )
    return ACPWebSocketConnectionTransport(connection: connection)
}

private func wsDrain(
    _ transport: ACPWebSocketConnectionTransport,
    limit: Int = 40,
    until match: (ACPMessage) -> Bool
) async throws -> ACPMessage {
    for _ in 0..<limit {
        let message = try await transport.receive()
        if match(message) { return message }
    }
    throw ACPTransportError.closed
}

@Suite("ACP x.ai/mcp family over ws://", .serialized)
struct ACPMCPExtensionServeTests {
    @Test("mcp/list and mcp/call answer over the real WebSocket carrier")
    func listAndCallOverWS() async throws {
        let mcp = PlainMCPHandler()
        let server = HttpServer(handler: mcp, basePath: "")
        try server.start()
        defer { server.stop() }
        let harness = try await MCPFamilyHarness.start(configTOML: """
        [mcpServers.plain]
        url = "\(server.baseURL)/mcp"
        """)
        defer { Task { await harness.shutdown() } }

        // The serve host mints a runtime per connection over a SHARED
        // session store — the same shape LiveServeComposition builds.
        let sessionStore = InMemoryACPSessionStore()
        let router = LiveACPExtensionRouter.build(
            feedback: nil,
            models: LiveModelsACPHandler(
                catalogStore: LiveModelCatalogStore(
                    input: .default,
                    environment: harness.environment,
                    openGrokHome: harness.home,
                    transport: MockHTTPTransport(responses: [])
                ),
                modelSwitch: nil
            ),
            mcp: harness.handler
        )
        let gateway = harness.gateway
        let host = ACPServeHost(
            configuration: ACPServeConfiguration(
                host: "127.0.0.1",
                port: 0,
                secret: "mcp-secret",
                keepAliveInterval: nil
            ),
            makeRuntime: {
                let runtime = ACPAgentRuntime(store: sessionStore, extensionRouter: router)
                await gateway.attach(runtime)
                return runtime
            }
        )
        let endpoint = try await host.start()
        let served = Task { await host.run() }
        defer {
            served.cancel()
            Task { await host.stop() }
        }

        let client = try await wsConnect(to: endpoint, secret: "mcp-secret")
        try await client.send(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: .object([
                "protocolVersion": .number(.int64(1)),
                "clientCapabilities": .object([:]),
            ])
        ))
        _ = try await wsDrain(client) { $0.id == .number(1) }
        try await client.send(.request(
            id: .number(2),
            method: AgentMethodNames.sessionNew,
            params: .object(["cwd": .string(harness.home.path), "mcpServers": .array([])])
        ))
        let created = try await wsDrain(client) { $0.id == .number(2) }
        guard case .response(_, .object(let sessionObject)?, _) = created,
              case .string(let wsSessionID)? = sessionObject["sessionId"] else {
            Issue.record("no sessionId in \(created)")
            return
        }

        try await client.send(.request(
            id: .number(3),
            method: "x.ai/mcp/list",
            params: .object(["sessionId": .string(wsSessionID)])
        ))
        let listed = try await wsDrain(client) { $0.id == .number(3) }
        guard case .response(_, let listResult?, nil) = listed else {
            Issue.record("mcp/list failed over ws: \(listed)")
            return
        }
        let row = try #require(listResult["result"]?["servers"]?[0])
        #expect(row["name"]?.stringValue == "plain")
        #expect(row["session"]?["status"]?.stringValue == "ready")

        try await client.send(.request(
            id: .number(4),
            method: "x.ai/mcp/call",
            params: .object([
                "sessionId": .string(wsSessionID),
                "server": .string("plain"),
                "tool": .string("echo"),
                "arguments": .object(["text": .string("ws-carrier")]),
            ])
        ))
        let called = try await wsDrain(client) { $0.id == .number(4) }
        guard case .response(_, let callResult?, nil) = called else {
            Issue.record("mcp/call failed over ws: \(called)")
            return
        }
        #expect(callResult["result"]?["content"]?[0]?["text"]?.stringValue == "echo:ws-carrier")
        #expect(mcp.seenCallArguments.contains("ws-carrier"))

        await client.close()
    }
}
