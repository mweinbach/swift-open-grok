import Foundation
import OpenGrokACP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

@Suite("ACP initialize capability and metadata parity")
struct ACPInitializeCapabilityParityTests {
    private func initialize(
        configuration: ACPAgentConfiguration = ACPAgentConfiguration()
    ) async throws -> (response: InitializeResponse, wire: JSONValue) {
        let transport = InProcessACPTransport.makePair()
        let runtime = ACPAgentRuntime(configuration: configuration)
        let host = ACPStdioHost(runtime: runtime, transport: transport.agent)
        let serving = Task { await host.run() }

        do {
            try await transport.client.send(.request(
                id: .number(1),
                method: AgentMethodNames.initialize,
                params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
            ))
            let message = try await transport.client.receive()
            guard case .response(.number(1), let result?, nil) = message else {
                throw ACPRuntimeError.transport("initialize did not return a successful response")
            }
            let response = try result.decode(InitializeResponse.self)
            await host.shutdown()
            await transport.client.close()
            await serving.value
            return (response, result)
        } catch {
            await host.shutdown()
            await transport.client.close()
            await serving.value
            throw error
        }
    }

    @Test("runtime advertises implemented MCP transports without claiming unavailable prompt media")
    func defaultCapabilitiesAndRealVersionReachRuntimeHost() async throws {
        let initialized = try await initialize()
        let capabilities = initialized.response.agentCapabilities

        #expect(capabilities.loadSession)
        #expect(capabilities.mcpCapabilities.http)
        #expect(capabilities.mcpCapabilities.sse)
        #expect(!capabilities.promptCapabilities.embeddedContext)
        #expect(!capabilities.promptCapabilities.image)
        #expect(!capabilities.promptCapabilities.audio)

        let agentInfo = try #require(initialized.response.agentInfo)
        #expect(agentInfo.name == OpenGrokACPExtension.executable)
        #expect(!agentInfo.version.isEmpty)
        #expect(agentInfo.version != "0.0.0")
        #expect(initialized.response.meta?["grokShell"] == .bool(true))
        #expect(initialized.response.meta?["agentVersion"] == .string(agentInfo.version))
        #expect(initialized.response.meta?["currentWorkingDirectory"] == nil)
        #expect(initialized.response.meta?["defaultAuthMethodId"] == nil)
        #expect(initialized.response.meta?["modelProviders"] == nil)
        #expect(initialized.response.meta?["availableCommands"] == nil)
        #expect(initialized.response.meta?["sessionRecap"] == nil)
        #expect(initialized.response.meta?["x.ai/pluginDirs"] == nil)

        let wireCapabilities = try #require(initialized.wire["agentCapabilities"])
        #expect(wireCapabilities["mcpCapabilities"]?["http"] == .bool(true))
        #expect(wireCapabilities["mcpCapabilities"]?["sse"] == .bool(true))
        #expect(wireCapabilities["promptCapabilities"]?["embeddedContext"] == .bool(false))
        #expect(wireCapabilities["promptCapabilities"]?["image"] == .bool(false))
        #expect(wireCapabilities["promptCapabilities"]?["audio"] == .bool(false))
    }

    @Test("explicit live composition metadata and embedded-context support survive the host wire")
    func injectedMetadataPreservesExistingExtensions() async throws {
        let command = AvailableCommand(
            name: "recap",
            description: "Summarize the current session",
            input: .unstructured(hint: "focus"),
            meta: ["scope": .string("session")]
        )
        let configuration = ACPAgentConfiguration(
            agentCapabilities: ACPAgentConfiguration.defaultAgentCapabilities(
                supportsEmbeddedContext: true
            ),
            authMethods: [AuthMethod(id: AuthMethodId("api-key"))],
            agentInfo: Implementation(name: "open-grok", version: "9.8.7"),
            meta: [
                "preserved": .string("existing-extension"),
                "agentVersion": .string("stale-version"),
            ],
            initializationMetadata: OpenGrokInitializeMetadata(
                currentWorkingDirectory: "/tmp/actual-acp-workspace",
                defaultAuthMethodId: AuthMethodId("api-key"),
                modelProviders: ["grok-4": .string("xai")],
                availableCommands: [command],
                sessionRecap: false,
                pluginDirectoriesSupported: false
            )
        )
        let initialized = try await initialize(configuration: configuration)

        #expect(initialized.response.agentCapabilities.promptCapabilities.embeddedContext)
        #expect(!initialized.response.agentCapabilities.promptCapabilities.image)
        #expect(!initialized.response.agentCapabilities.promptCapabilities.audio)
        #expect(initialized.response.agentInfo?.version == "9.8.7")

        let metadata = try #require(initialized.response.meta)
        #expect(metadata["preserved"] == .string("existing-extension"))
        #expect(metadata["grokShell"] == .bool(true))
        #expect(metadata["agentVersion"] == .string("9.8.7"))
        #expect(metadata["currentWorkingDirectory"] == .string("/tmp/actual-acp-workspace"))
        #expect(metadata["defaultAuthMethodId"] == .string("api-key"))
        #expect(metadata["modelProviders"] == .object(["grok-4": .string("xai")]))
        #expect(metadata["sessionRecap"] == .bool(false))
        #expect(metadata["x.ai/pluginDirs"] == .bool(false))

        let advertisedCommands = try #require(metadata["availableCommands"]?.arrayValue)
        #expect(advertisedCommands.count == 1)
        let advertisedCommand = try #require(advertisedCommands.first)
        #expect(advertisedCommand["name"] == .string("recap"))
        #expect(advertisedCommand["description"] == .string("Summarize the current session"))
        #expect(advertisedCommand["input"]?["hint"] == .string("focus"))
        #expect(advertisedCommand["_meta"]?["scope"] == .string("session"))
    }

    @Test("typed metadata retains Rust's plugin capability spelling and omits unknown facts")
    func typedMetadataUsesCompatibleOptionalWireFields() throws {
        let metadata = OpenGrokInitializeMetadata(
            currentWorkingDirectory: "/tmp/project",
            defaultAuthMethodId: AuthMethodId("oidc"),
            pluginDirectoriesSupported: false
        )
        let encoded = try JSONValue.encode(metadata)

        #expect(encoded["currentWorkingDirectory"] == .string("/tmp/project"))
        #expect(encoded["defaultAuthMethodId"] == .string("oidc"))
        #expect(encoded["x.ai/pluginDirs"] == .bool(false))
        #expect(encoded["pluginDirectoriesSupported"] == nil)
        #expect(encoded["modelProviders"] == nil)
        #expect(encoded["availableCommands"] == nil)
        #expect(encoded["sessionRecap"] == nil)
        #expect(try encoded.decode(OpenGrokInitializeMetadata.self) == metadata)
    }
}
