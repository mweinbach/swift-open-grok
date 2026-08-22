import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import Testing
@testable import OpenGrokMCP

private actor MCPACPInvocationLog {
    private var requests: [(serverID: String, message: JSONValue)] = []

    func append(serverID: String, message: JSONValue) {
        requests.append((serverID, message))
    }

    func values() -> [(serverID: String, message: JSONValue)] {
        requests
    }
}

private actor MCPACPInvocationGate {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?

    func markStarted() {
        started = true
        waiter?.resume()
        waiter = nil
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

@Suite("MCP in-process ACP reverse bridge")
struct MCPACPTransportTests {
    @Test("ACP metadata uses serverId, ignores malformed entries, and keeps the first name")
    func metadataRegistration() throws {
        let metadata: [String: JSONValue] = [
            MCPACPWire.servers: .array([
                .object(["name": .string("tools"), "serverId": .string("srv_0")]),
                .object(["name": .string("tools"), "serverId": .string("srv_duplicate")]),
                .object(["name": .string("missing")]),
                .object(["name": .string("  "), "serverId": .string("srv_blank")]),
                .object(["name": .string("files"), "serverId": .string("srv_1")]),
                .string("not a server"),
            ]),
        ]

        let entries = MCPACPServerEntry.parse(from: metadata)
        #expect(entries == [
            MCPACPServerEntry(name: "tools", serverID: "srv_0"),
            MCPACPServerEntry(name: "files", serverID: "srv_1"),
        ])
        #expect(try JSONValue.encode(entries[0]) == .object([
            "name": .string("tools"),
            "serverId": .string("srv_0"),
        ]))
    }

    @Test("notifications stay local and the complete response retains the original numeric id")
    func notificationAndRequestCorrelation() async throws {
        let log = MCPACPInvocationLog()
        let invoker = ClosureMCPACPReverseInvoker { serverID, message, _ in
            await log.append(serverID: serverID, message: message)
            return .object([
                "jsonrpc": .string("2.0"),
                "id": .string("incorrect-client-id"),
                "result": .object(["accepted": .bool(true)]),
            ])
        }
        let transport = MCPACPTransport(
            serverID: "srv_0",
            sessionID: "session-a",
            invoker: invoker
        )

        let notification = try await transport.send(.notification(MCPNotification(
            method: "notifications/initialized"
        )))
        #expect(notification == nil)
        #expect(await log.values().isEmpty)

        let result = try await transport.send(.request(MCPRequest(
            id: .number(42),
            method: "tools/list",
            params: .object([:])
        )))
        guard case .response(let response)? = result else {
            Issue.record("expected complete MCP JSON-RPC response")
            return
        }
        #expect(response.id == .number(42))
        #expect(response.result?["accepted"] == .bool(true))
        let calls = await log.values()
        #expect(calls.count == 1)
        #expect(calls[0].serverID == "srv_0")
        #expect(calls[0].message["id"] == .number(.int64(42)))
        #expect(calls[0].message["method"] == .string("tools/list"))
        #expect(calls[0].message["sessionId"] == nil)
    }

    @Test("client handshake, discovery, and tool execution run through the actual bridge")
    func clientHandshakeAndToolExecution() async throws {
        let log = MCPACPInvocationLog()
        let invoker = ClosureMCPACPReverseInvoker { serverID, message, _ in
            await log.append(serverID: serverID, message: message)
            let id = message["id"] ?? .null
            let result: JSONValue
            switch message["method"]?.stringValue {
            case MCPMethod.initialize:
                result = try JSONValue.encode(MCPInitializeResult(
                    protocolVersion: .latest,
                    capabilities: MCPCapabilities(tools: MCPToolsCapability()),
                    serverInfo: MCPImplementation(name: "client-tools", version: "1.0")
                ))
            case MCPMethod.toolsList:
                result = try JSONValue.encode(MCPListToolsResult(tools: [MCPTool(name: "echo")]))
            case MCPMethod.toolsCall:
                result = try JSONValue.encode(MCPCallToolResult(content: [.text(text: "hello")]))
            default:
                throw MCPError.methodNotFound(message["method"]?.stringValue ?? "")
            }
            return .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": result,
            ])
        }
        let registry = MCPACPBridgeRegistry(
            sessionID: "session-a",
            servers: [MCPACPServerEntry(name: "client", serverID: "srv_0")],
            invoker: invoker
        )
        let transport = try await registry.open(serverID: "srv_0", sessionID: "session-a")
        let client = MCPClient(transport: transport)

        let initialized = try await client.initialize()
        #expect(initialized.serverInfo.name == "client-tools")
        let tools = try await client.listTools()
        #expect(tools.tools.map(\.name) == ["echo"])
        let output = try await client.callTool(MCPCallToolParams(name: "echo"))
        #expect(output.content == [.text(text: "hello")])

        let calls = await log.values()
        #expect(calls.map { $0.message["method"]?.stringValue } == [
            MCPMethod.initialize,
            MCPMethod.toolsList,
            MCPMethod.toolsCall,
        ])
        await registry.closeAll()
    }

    @Test("malformed reverse results become correlated JSON-RPC internal errors")
    func malformedResultFailsClosed() async throws {
        let invoker = ClosureMCPACPReverseInvoker { _, _, _ in .string("invalid") }
        let transport = MCPACPTransport(
            serverID: "srv_0",
            sessionID: "session-a",
            invoker: invoker
        )

        let result = try await transport.send(.request(MCPRequest(
            id: .string("request-7"),
            method: "tools/list"
        )))
        guard case .response(let response)? = result else {
            Issue.record("expected correlated error response")
            return
        }
        #expect(response.id == .string("request-7"))
        #expect(response.error?.code == MCPJSONRPCErrorCode.internalError)
        #expect(response.result == nil)
    }

    @Test("registry rejects cross-session and unadvertised server access")
    func registryEnforcesSessionAndServerBoundaries() async throws {
        let invoker = ClosureMCPACPReverseInvoker { _, _, _ in .null }
        let registry = MCPACPBridgeRegistry(
            sessionID: "session-a",
            servers: [MCPACPServerEntry(name: "tools", serverID: "srv_0")],
            invoker: invoker
        )

        do {
            let transport = try await registry.open(serverID: "srv_0", sessionID: "session-b")
            Issue.record("cross-session access unexpectedly opened \(transport.serverID)")
        } catch let error as MCPError {
            guard case .invalidRequest = error else {
                Issue.record("unexpected cross-session error: \(error)")
                return
            }
        }

        do {
            let transport = try await registry.open(serverID: "srv_unknown", sessionID: "session-a")
            Issue.record("unadvertised access unexpectedly opened \(transport.serverID)")
        } catch let error as MCPError {
            guard case .invalidRequest = error else {
                Issue.record("unexpected unadvertised-server error: \(error)")
                return
            }
        }

        let authorized = try await registry.open(serverID: "srv_0", sessionID: "session-a")
        #expect(authorized.sessionID == "session-a")
        await registry.closeAll()

        do {
            let transport = try await registry.open(serverID: "srv_0", sessionID: "session-a")
            Issue.record("closed registry unexpectedly opened \(transport.serverID)")
        } catch let error as MCPError {
            #expect(error == .transportClosed)
        }
    }

    @Test("closing a bridge cancels outstanding reverse requests")
    func closeCancelsOutstandingRequests() async throws {
        let gate = MCPACPInvocationGate()
        let invoker = ClosureMCPACPReverseInvoker { _, _, _ in
            await gate.markStarted()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .null
        }
        let transport = MCPACPTransport(
            serverID: "srv_0",
            sessionID: "session-a",
            invoker: invoker
        )
        let pending = Task {
            try await transport.send(.request(MCPRequest(id: .number(9), method: "tools/call")))
        }

        await gate.waitUntilStarted()
        await transport.close()

        do {
            let result = try await pending.value
            Issue.record("closed transport unexpectedly returned \(String(describing: result))")
        } catch let error as MCPError {
            #expect(error == .transportClosed)
        }
    }
}
