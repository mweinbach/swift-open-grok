import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import Testing
@testable import OpenGrokMCP

private actor ProgressServerHandler: MCPServerHandler {
    private var requests: [MCPCallToolParams] = []
    private var holding = false

    func holdCalls() {
        holding = true
    }

    func releaseCalls() {
        holding = false
    }

    func recordedRequests() -> [MCPCallToolParams] {
        requests
    }

    func callTool(_ params: MCPCallToolParams) async throws -> MCPCallToolResult {
        requests.append(params)
        while holding {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return MCPCallToolResult(content: [.text(text: params.name)])
    }
}

private actor ProgressCollector {
    private var values: [MCPProgressParams] = []

    func record(_ value: MCPProgressParams) {
        values.append(value)
    }

    func snapshot() -> [MCPProgressParams] {
        values
    }
}

private struct ProgressHarness {
    let handler: ProgressServerHandler
    let transport: MCPInMemoryTransport
    let client: MCPClient

    static func make() async throws -> ProgressHarness {
        let handler = ProgressServerHandler()
        let server = MCPServer(
            configuration: MCPServerConfiguration(
                serverInfo: MCPImplementation(name: "progress", version: "1"),
                capabilities: MCPCapabilities(tools: MCPToolsCapability())
            ),
            handler: handler
        )
        let transport = MCPInMemoryTransport(server: server)
        let client = MCPClient(transport: transport)
        _ = try await client.initialize()
        return ProgressHarness(handler: handler, transport: transport, client: client)
    }

    func request(at index: Int = 0) async throws -> MCPCallToolParams {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let requests = await handler.recordedRequests()
            if requests.indices.contains(index) {
                return requests[index]
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw MCPError.internalError("timed out waiting for MCP tool request")
    }

    func token(at index: Int = 0) async throws -> JsonRpcId {
        let request = try await request(at: index)
        guard let value = request.meta?["progressToken"]?.stringValue else {
            throw MCPError.internalError("MCP tool request has no progress token")
        }
        return .string(value)
    }

    func sendProgress(
        token: JsonRpcId,
        progress: Double,
        total: Double? = nil,
        message: String? = nil
    ) async throws {
        let params = MCPProgressParams(
            progressToken: token,
            progress: progress,
            total: total,
            message: message
        )
        let notification = MCPNotification(
            method: MCPMethod.progress,
            params: try JSONValue.encode(params)
        )
        let wire = try MCPWireCodec.encode(.notification(notification))
        guard case .notification(let decoded) = try MCPWireCodec.decode(wire) else {
            throw MCPError.internalError("progress notification failed its JSON-RPC round trip")
        }
        await transport.receiveServerNotification(decoded)
    }

    func close() async {
        await handler.releaseCalls()
        await client.close()
    }
}

@Suite("MCP call-scoped JSON-RPC progress")
struct MCPCallProgressTests {
    @Test("streaming calls receive genuine ordered progress and preserve existing metadata")
    func receivesCorrelatedProgress() async throws {
        let harness = try await ProgressHarness.make()
        let collector = ProgressCollector()
        await harness.handler.holdCalls()

        let task = Task {
            try await harness.client.callTool(
                MCPCallToolParams(
                    name: "work",
                    arguments: .object([:]),
                    meta: .object(["existing": .string("preserved")])
                ),
                onProgress: { await collector.record($0) }
            )
        }

        let token = try await harness.token()
        let request = try await harness.request()
        #expect(request.meta?["existing"] == .string("preserved"))
        try await harness.sendProgress(token: token, progress: 1, total: 3, message: "first")
        try await harness.sendProgress(token: token, progress: 2, total: 3, message: "second")
        await harness.handler.releaseCalls()

        let result = try await task.value
        #expect(result.isError == false)
        let updates = await collector.snapshot()
        #expect(updates.map(\.message) == ["first", "second"])
        #expect(updates.map(\.progress) == [1, 2])
        #expect(updates.allSatisfy { $0.progressToken == token && $0.total == 3 })
        await harness.close()
    }

    @Test("unknown tokens and notifications from another client never cross delivery boundaries")
    func rejectsUnknownAndCrossClientNotifications() async throws {
        let first = try await ProgressHarness.make()
        let second = try await ProgressHarness.make()
        let firstUpdates = ProgressCollector()
        let secondUpdates = ProgressCollector()
        await first.handler.holdCalls()
        await second.handler.holdCalls()

        let firstCall = Task {
            try await first.client.callTool(
                MCPCallToolParams(name: "first"),
                onProgress: { await firstUpdates.record($0) }
            )
        }
        let secondCall = Task {
            try await second.client.callTool(
                MCPCallToolParams(name: "second"),
                onProgress: { await secondUpdates.record($0) }
            )
        }

        let firstToken = try await first.token()
        let secondToken = try await second.token()
        #expect(firstToken != secondToken)

        try await first.sendProgress(token: .string("unknown"), progress: 99, message: "spoof")
        try await first.sendProgress(token: secondToken, progress: 98, message: "cross-client")
        try await second.sendProgress(token: firstToken, progress: 97, message: "cross-client")
        try await first.sendProgress(token: firstToken, progress: 1, message: "first-only")
        try await second.sendProgress(token: secondToken, progress: 2, message: "second-only")
        await first.handler.releaseCalls()
        await second.handler.releaseCalls()

        _ = try await firstCall.value
        _ = try await secondCall.value
        #expect(await firstUpdates.snapshot().map(\.message) == ["first-only"])
        #expect(await secondUpdates.snapshot().map(\.message) == ["second-only"])
        await first.close()
        await second.close()
    }

    @Test("simultaneous calls on the same client each receive only their own token")
    func isolatesConcurrentCalls() async throws {
        let harness = try await ProgressHarness.make()
        let firstUpdates = ProgressCollector()
        let secondUpdates = ProgressCollector()
        await harness.handler.holdCalls()

        let firstCall = Task {
            try await harness.client.callTool(
                MCPCallToolParams(name: "alpha"),
                onProgress: { await firstUpdates.record($0) }
            )
        }
        _ = try await harness.request(at: 0)
        let secondCall = Task {
            try await harness.client.callTool(
                MCPCallToolParams(name: "beta"),
                onProgress: { await secondUpdates.record($0) }
            )
        }

        let firstToken = try await harness.token(at: 0)
        let secondToken = try await harness.token(at: 1)
        #expect(firstToken != secondToken)
        try await harness.sendProgress(token: secondToken, progress: 2, message: "beta")
        try await harness.sendProgress(token: firstToken, progress: 1, message: "alpha")
        await harness.handler.releaseCalls()

        _ = try await firstCall.value
        _ = try await secondCall.value
        #expect(await firstUpdates.snapshot().map(\.message) == ["alpha"])
        #expect(await secondUpdates.snapshot().map(\.message) == ["beta"])
        await harness.close()
    }

    @Test("cancellation retires its progress token immediately")
    func cancellationRemovesProgressRoute() async throws {
        let harness = try await ProgressHarness.make()
        let updates = ProgressCollector()
        await harness.handler.holdCalls()

        let call = Task {
            try await harness.client.callTool(
                MCPCallToolParams(name: "cancelled"),
                onProgress: { await updates.record($0) }
            )
        }
        let token = try await harness.token()
        call.cancel()
        do {
            _ = try await call.value
            Issue.record("cancelled MCP tool call unexpectedly succeeded")
        } catch {
            #expect(error is MCPError || error is CancellationError)
        }

        try await harness.sendProgress(token: token, progress: 1, message: "too late")
        #expect(await updates.snapshot().isEmpty)
        await harness.close()
    }

    @Test("ordinary tool calls never request or receive fabricated progress")
    func ordinaryCallsRemainUnchanged() async throws {
        let harness = try await ProgressHarness.make()
        let result = try await harness.client.callTool(
            MCPCallToolParams(
                name: "ordinary",
                meta: .object(["existing": .string("untouched")])
            )
        )

        #expect(result.isError == false)
        let request = try await harness.request()
        #expect(request.meta == .object(["existing": .string("untouched")]))
        #expect(request.meta?["progressToken"] == nil)
        await harness.close()
    }
}
