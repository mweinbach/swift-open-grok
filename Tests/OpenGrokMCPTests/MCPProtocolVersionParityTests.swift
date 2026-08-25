import OpenGrokShared
import Testing
@testable import OpenGrokMCP

private actor MCPProtocolVersionRecordingTransport: MCPTransport {
    private let server: MCPServer
    private var messages: [MCPWireMessage] = []

    init(server: MCPServer) {
        self.server = server
    }

    func send(_ message: MCPWireMessage) async throws -> MCPWireMessage? {
        messages.append(message)
        return try await server.handle(message)
    }

    func close() async {
        await server.close()
    }

    func requests() -> [MCPRequest] {
        messages.compactMap { message in
            guard case .request(let request) = message else { return nil }
            return request
        }
    }

    func notifications() -> [MCPNotification] {
        messages.compactMap { message in
            guard case .notification(let notification) = message else { return nil }
            return notification
        }
    }
}

@Suite("MCP protocol version parity")
struct MCPProtocolVersionParityTests {
    @Test("protocol version constants preserve every supported wire date")
    func protocolVersionConstants() {
        #expect(MCPProtocolVersion.november2025.rawValue == "2025-11-25")
        #expect(MCPProtocolVersion.latest == .november2025)
        #expect(MCPProtocolVersion.june2025.rawValue == "2025-06-18")
        #expect(MCPProtocolVersion.march2025.rawValue == "2025-03-26")
        #expect(MCPProtocolVersion.november2024.rawValue == "2024-11-05")
        #expect(OpenGrokMCP.defaultProtocolVersion == .november2025)

        let expected: [MCPProtocolVersion] = [
            .november2025,
            .june2025,
            .march2025,
            .november2024,
        ]
        #expect(MCPClientConfiguration().protocolVersion == .november2025)
        #expect(MCPClientConfiguration().supportedProtocolVersions == expected)
        #expect(MCPServerConfiguration().supportedProtocolVersions == expected)
    }

    @Test("initialize offers the pinned version without inventing capabilities")
    func initializeOffersPinnedVersion() async throws {
        let server = MCPServer()
        let transport = MCPProtocolVersionRecordingTransport(server: server)
        let client = MCPClient(transport: transport)

        let result = try await client.initialize()
        let request = try #require(await transport.requests().first)

        #expect(request.method == MCPMethod.initialize)
        #expect(request.params?["protocolVersion"] == .string("2025-11-25"))
        #expect(request.params?["capabilities"] == .object([:]))
        #expect(result.protocolVersion == .november2025)
        #expect(await client.protocolVersion() == .november2025)
        #expect(await server.negotiatedProtocolVersion() == .november2025)
        #expect(await transport.notifications().map(\.method) == [MCPMethod.initialized])
    }

    @Test(
        "client accepts every supported legacy server version",
        arguments: [
            MCPProtocolVersion.june2025,
            MCPProtocolVersion.march2025,
            MCPProtocolVersion.november2024,
        ]
    )
    func acceptsLegacyServerVersion(_ serverVersion: MCPProtocolVersion) async throws {
        let server = MCPServer(configuration: MCPServerConfiguration(
            supportedProtocolVersions: [serverVersion]
        ))
        let transport = MCPProtocolVersionRecordingTransport(server: server)
        let client = MCPClient(transport: transport)

        let result = try await client.initialize()
        let request = try #require(await transport.requests().first)

        #expect(request.params?["protocolVersion"] == .string("2025-11-25"))
        #expect(result.protocolVersion == serverVersion)
        #expect(await client.protocolVersion() == serverVersion)
        #expect(await server.negotiatedProtocolVersion() == serverVersion)
        #expect(await client.state() == .initialized)
    }

    @Test(
        "server preserves explicitly requested compatible protocol versions",
        arguments: [
            MCPProtocolVersion.november2025,
            MCPProtocolVersion.june2025,
            MCPProtocolVersion.march2025,
            MCPProtocolVersion.november2024,
        ]
    )
    func preservesRequestedSupportedVersion(_ requestedVersion: MCPProtocolVersion) async throws {
        let server = MCPServer()
        let transport = MCPProtocolVersionRecordingTransport(server: server)
        let client = MCPClient(
            transport: transport,
            configuration: MCPClientConfiguration(protocolVersion: requestedVersion)
        )

        let result = try await client.initialize()
        let request = try #require(await transport.requests().first)

        #expect(request.params?["protocolVersion"] == .string(requestedVersion.rawValue))
        #expect(result.protocolVersion == requestedVersion)
        #expect(await client.protocolVersion() == requestedVersion)
        #expect(await server.negotiatedProtocolVersion() == requestedVersion)
    }

    @Test("unsupported future server versions fail closed before initialization")
    func rejectsUnsupportedFutureVersion() async throws {
        let futureVersion = MCPProtocolVersion("2026-07-28")
        let server = MCPServer(configuration: MCPServerConfiguration(
            supportedProtocolVersions: [futureVersion]
        ))
        let transport = MCPProtocolVersionRecordingTransport(server: server)
        let client = MCPClient(transport: transport)

        do {
            let result = try await client.initialize()
            Issue.record("unexpectedly accepted protocol version \(result.protocolVersion.rawValue)")
        } catch let error as MCPError {
            #expect(error == .capabilityUnsupported("protocol version 2026-07-28"))
        }

        let request = try #require(await transport.requests().first)
        #expect(request.params?["protocolVersion"] == .string("2025-11-25"))
        #expect(await client.state() == .disconnected)
        #expect(await client.protocolVersion() == nil)
        #expect(await client.initializeResultValue() == nil)
        #expect(await transport.notifications().isEmpty)
    }
}
