import Foundation
import OpenGrokACP
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokTestSupport
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

private typealias JSONValue = OpenGrokShared.JSONValue

private struct SessionSearchPolicyFixture {
    let home: URL
    let workspace: URL
    var environment: [String: String]
    let gate: SessionSearchGate

    static func make(gate: SessionSearchGate = SessionSearchGate()) throws -> Self {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent(
            "opengrok-search-policy-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspace = home.appendingPathComponent("workspace", isDirectory: true)
        try manager.createDirectory(
            at: workspace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return Self(
            home: home,
            workspace: workspace,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path],
            gate: gate
        )
    }

    func seed(_ id: String, secret: String) async throws {
        var record = LiveConversationRecord.new(sessionID: id, workingDirectory: workspace)
        record.items = [.user("private question"), .assistant(AssistantItem(content: secret))]
        try await LiveConversationStore(openGrokHome: home).save(record)
    }

    func writePolicy(_ enabled: Bool, filename: String) throws {
        try Data("[features]\nsession_search = \(enabled)\n".utf8).write(
            to: home.appendingPathComponent(filename)
        )
    }

    func cli(query: String) throws -> (out: String, err: String) {
        let (streams, output, errors) = CLIStreams.buffered()
        try LiveSessionsComposition.run(
            options: CLISessionOptions(action: .search, json: true, query: query),
            environment: environment,
            streams: streams,
            cwd: workspace,
            sessionSearchGate: gate
        )
        return (output.contents, errors.contents)
    }

    func acp(
        query: String,
        includeContent: Bool = true,
        enabledAtLaunch: Bool = true
    ) async throws -> JSONValue {
        let runtime = ACPAgentRuntime(extensionRouter: LiveACPExtensionRouter.build(
            feedback: nil,
            models: LiveModelsACPHandler(
                catalogStore: LiveModelCatalogStore(
                    input: .default,
                    environment: environment,
                    openGrokHome: home,
                    transport: MockHTTPTransport(responses: [])
                ),
                modelSwitch: nil
            ),
            persistentSessions: LivePersistentSessionACPHandler(
                openGrokHome: home,
                environment: environment,
                searchGate: gate,
                enabledAtLaunch: enabledAtLaunch
            )
        ))
        let initialized = await runtime.handle(.request(
            id: .string("initialize"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _, nil) = try #require(initialized.first) else {
            throw ACPTransportError.invalidMessage("search-policy runtime failed to initialize")
        }
        let responses = await runtime.handle(.request(
            id: .string("search"),
            method: "x.ai/session/search",
            params: .object([
                "query": .string(query),
                "includeContent": .bool(includeContent),
            ])
        ))
        guard case .response(_, let response?, nil) = try #require(responses.first) else {
            throw ACPTransportError.invalidMessage("search-policy runtime returned no result")
        }
        return response
    }

    var indexExists: Bool {
        FileManager.default.fileExists(
            atPath: home.appendingPathComponent("sessions/session_search.sqlite").path
        )
    }

    func clean() {
        try? FileManager.default.removeItem(at: home)
    }
}

@Suite("Deployment-authoritative private session search", .serialized)
struct LiveSessionSearchPolicyParityTests {
    @Test("session search defaults on only within the supplied isolated launch environment")
    func explicitEnvironmentDefaultsOn() throws {
        let fixture = try SessionSearchPolicyFixture.make()
        defer { fixture.clean() }
        let result = resolveSessionSearchSetting(environment: fixture.environment)
        #expect(result.value)
        #expect(result.source == .default)
        #expect(fixture.gate.isIndexEnabled(environment: fixture.environment))
    }

    @Test("a requirements pin overrides a true caller environment and conflicting user settings")
    func requirementsDenyBeatsEnvironment() throws {
        var fixture = try SessionSearchPolicyFixture.make()
        defer { fixture.clean() }
        try fixture.writePolicy(true, filename: "config.toml")
        try fixture.writePolicy(false, filename: "requirements.toml")
        fixture.environment["GROK_SESSION_SEARCH"] = "1"
        let result = resolveSessionSearchSetting(environment: fixture.environment)
        #expect(result.value == false)
        #expect(result.source == .requirement)
        #expect(!fixture.gate.isIndexEnabled(environment: fixture.environment))
    }

    @Test("protected managed and system policy denies cannot be rearmed by environment overrides")
    func managedDenyBeatsEnvironment() throws {
        var fixture = try SessionSearchPolicyFixture.make()
        defer { fixture.clean() }
        try fixture.writePolicy(true, filename: "config.toml")
        try fixture.writePolicy(false, filename: "managed_config.toml")
        fixture.environment["OPENGROK_SESSION_SEARCH"] = "1"
        let result = resolveSessionSearchSetting(environment: fixture.environment)
        #expect(result.value == false)
        #expect(result.source == .managedConfig)
    }

    @Test("both live surfaces honor the supplied launch environment without inspecting ambient process state")
    func launchEnvironmentDisablesBothSurfaces() async throws {
        var fixture = try SessionSearchPolicyFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("environment-private", secret: "environment-secret-marker")
        fixture.environment["GROK_SESSION_SEARCH"] = "0"

        let acp = try await fixture.acp(query: "secret", includeContent: true)
        #expect(acp["result"]?["results"] == .array([]))
        let cli = try fixture.cli(query: "secret")
        #expect(cli.out.trimmingCharacters(in: .whitespacesAndNewlines) == "[]")
        #expect(cli.err.contains("GROK_SESSION_SEARCH environment variable"))
        #expect(!fixture.indexExists)
    }

    @Test("ACP construction consumes an authoritative launch-time disable before touching session history")
    func launchDecisionRemainsEnforced() async throws {
        let fixture = try SessionSearchPolicyFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("launch-private", secret: "launch-secret-marker")
        #expect(fixture.gate.isIndexEnabled(environment: fixture.environment))

        let response = try await fixture.acp(query: "secret", enabledAtLaunch: false)
        #expect(response["result"]?["results"] == .array([]))
        #expect(!fixture.indexExists)
    }

    @Test("environment still outranks ordinary user preferences in both directions")
    func environmentOutranksUserConfig() throws {
        var fixture = try SessionSearchPolicyFixture.make()
        defer { fixture.clean() }
        try fixture.writePolicy(false, filename: "config.toml")
        fixture.environment["GROK_SESSION_SEARCH"] = "true"
        #expect(resolveSessionSearchSetting(environment: fixture.environment)
            == Resolved(value: true, source: .env))
        fixture.environment["GROK_SESSION_SEARCH"] = "false"
        #expect(resolveSessionSearchSetting(environment: fixture.environment)
            == Resolved(value: false, source: .env))
    }

    @Test("independently readable requirements and managed denies survive corrupt user configuration")
    func protectedPolicySurvivesCorruptUserConfig() throws {
        var fixture = try SessionSearchPolicyFixture.make()
        defer { fixture.clean() }
        try Data("[features\nsession_search = true\n".utf8).write(
            to: fixture.home.appendingPathComponent("config.toml")
        )
        try fixture.writePolicy(false, filename: "requirements.toml")
        fixture.environment["GROK_SESSION_SEARCH"] = "1"
        #expect(resolveSessionSearchSetting(environment: fixture.environment)
            == Resolved(value: false, source: .requirement))

        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent("requirements.toml"))
        try fixture.writePolicy(false, filename: "managed_config.toml")
        #expect(resolveSessionSearchSetting(environment: fixture.environment)
            == Resolved(value: false, source: .managedConfig))
    }

    @Test("config outranks remote, while an unopposed remote disable permanently closes this process gate")
    func remotePrecedenceAndMonotonicLatch() throws {
        let fixture = try SessionSearchPolicyFixture.make()
        defer { fixture.clean() }
        let enabled = try parseTOML("[features]\nsession_search = true\n")
        #expect(resolveSessionSearchSetting(
            environment: fixture.environment,
            document: enabled,
            remote: false
        ) == Resolved(value: true, source: .config))

        #expect(LiveSessionSearchPolicy(environment: fixture.environment, gate: fixture.gate).apply())
        #expect(!LiveSessionSearchPolicy(
            environment: fixture.environment,
            remote: false,
            gate: fixture.gate
        ).apply())
        #expect(fixture.gate.closedBySource() == .remote)
        #expect(!LiveSessionSearchPolicy(
            environment: fixture.environment,
            remote: true,
            gate: fixture.gate
        ).apply())
    }

    @Test("CLI search honors deployment denial before reading or indexing either private transcript")
    func cliSearchCannotLeakManagedSessions() async throws {
        var fixture = try SessionSearchPolicyFixture.make()
        defer { fixture.clean() }
        let markerOne = "ENTERPRISE-PRIVATE-ALPHA-\(UUID().uuidString)"
        let markerTwo = "ENTERPRISE-PRIVATE-BETA-\(UUID().uuidString)"
        try await fixture.seed("first-private", secret: markerOne)
        try await fixture.seed("second-private", secret: markerTwo)
        try fixture.writePolicy(false, filename: "requirements.toml")
        fixture.environment["GROK_SESSION_SEARCH"] = "1"

        let output = try fixture.cli(query: "ENTERPRISE")
        #expect(output.out.trimmingCharacters(in: .whitespacesAndNewlines) == "[]")
        #expect(output.err.contains("requirements.toml pin"))
        #expect(!output.out.contains(markerOne))
        #expect(!output.out.contains(markerTwo))
        #expect(!fixture.indexExists)
    }

    @Test("ACP full-content and snippet queries are denied before any durable transcript or index access")
    func acpSearchCannotLeakManagedSessions() async throws {
        var fixture = try SessionSearchPolicyFixture.make()
        defer { fixture.clean() }
        let first = "RESTRICTED-ALPHA-\(UUID().uuidString)"
        let second = "RESTRICTED-BETA-\(UUID().uuidString)"
        try await fixture.seed("restricted-a", secret: first)
        try await fixture.seed("restricted-b", secret: second)
        try fixture.writePolicy(false, filename: "managed_config.toml")
        fixture.environment["OPENGROK_SESSION_SEARCH"] = "true"

        for includeContent in [true, false] {
            let response = try await fixture.acp(query: "RESTRICTED", includeContent: includeContent)
            #expect(response["result"]?["results"] == .array([]))
            #expect(response["result"]?["nextOffset"] == .null)
            #expect(response["result"]?["totalEstimate"]?.uint64Value == 0)
            #expect(response["result"]?["bootstrapping"]?.boolValue == false)
            let wire = try JSONEncoder().encode(response)
            #expect(!String(decoding: wire, as: UTF8.self).contains(first))
            #expect(!String(decoding: wire, as: UTF8.self).contains(second))
        }
        #expect(!fixture.indexExists)
    }

    @Test("allowed CLI and ACP queries consume the same real durable index and content")
    func authorizedSurfacesShareRealIndex() async throws {
        let fixture = try SessionSearchPolicyFixture.make()
        defer { fixture.clean() }
        let marker = "authorized-supernova-\(UUID().uuidString)"
        try await fixture.seed("searchable", secret: marker)

        let cli = try fixture.cli(query: "supernova")
        #expect(cli.out.contains("searchable"))
        #expect(fixture.indexExists)
        let acp = try await fixture.acp(query: "supernova")
        #expect(acp["result"]?["results"]?[0]?["sessionId"]?.stringValue == "searchable")
        #expect(acp["result"]?["results"]?[0]?["snippet"]?.stringValue?.contains("supernova")
            == true)
    }

    @Test("a runtime remote kill-switch closes every session using the same leader gate")
    func remoteDisableClosesSiblingSessions() async throws {
        let shared = SessionSearchGate()
        let first = try SessionSearchPolicyFixture.make(gate: shared)
        defer { first.clean() }
        let second = try SessionSearchPolicyFixture.make(gate: shared)
        defer { second.clean() }
        try await first.seed("first-session", secret: "orbit-secret-first")
        try await second.seed("second-session", secret: "orbit-secret-second")

        let initial = try await first.acp(query: "orbit")
        #expect(initial["result"]?["results"]?[0]?["sessionId"]?.stringValue == "first-session")
        #expect(!LiveSessionSearchPolicy(
            environment: first.environment,
            remote: false,
            gate: shared
        ).apply())
        let sibling = try await second.acp(query: "orbit", includeContent: true)
        #expect(sibling["result"]?["results"] == .array([]))
        #expect(!second.indexExists)
        #expect(!LiveSessionSearchPolicy(
            environment: second.environment,
            remote: true,
            gate: shared
        ).apply())
    }

    @Test("a newly written requirements kill-switch closes an already initialized search gate")
    func requirementsDisableAfterFirstSearch() async throws {
        let fixture = try SessionSearchPolicyFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("previously-visible", secret: "revocation-sensitive")
        let initial = try await fixture.acp(query: "revocation")
        #expect(initial["result"]?["results"]?[0]?["sessionId"]?.stringValue
            == "previously-visible")

        try fixture.writePolicy(false, filename: "requirements.toml")
        let blocked = try await fixture.acp(query: "revocation", includeContent: true)
        #expect(blocked["result"]?["results"] == .array([]))
        #expect(fixture.gate.closedBySource() == .requirement)
    }
}
