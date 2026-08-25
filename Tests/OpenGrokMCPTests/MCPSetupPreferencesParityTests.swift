import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import Testing

@testable import OpenGrokMCP

@Suite("MCP setup preferences and transport resolution")
struct MCPSetupPreferencesParityTests {
    @Test("missing setup preferences initialize an owner-private upstream-shaped store")
    func persistsOwnerPrivatePreferences() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(MCPSetupPreferencesStore.load(home: home) == .missing)
        let entry = McpServerPreferences(
            values: ["region": "us"],
            source: McpPreferenceSource(kind: "config", scope: "user"),
            updatedAt: "2026-08-25T12:00:00Z"
        )
        let previous = try MCPSetupPreferencesStore.updateServer(
            named: "configured",
            preferences: entry,
            home: home
        )
        #expect(previous == nil)
        #expect(MCPSetupPreferencesStore.load(home: home).file.servers["configured"] == entry)

        let path = MCPSetupPreferencesStore.path(home: home)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        )
        #expect(object["version"] as? Int == 1)
        let servers = try #require(object["servers"] as? [String: Any])
        let stored = try #require(servers["configured"] as? [String: Any])
        #expect(stored["values"] as? [String: String] == ["region": "us"])
        #expect(stored["updatedAt"] as? String == "2026-08-25T12:00:00Z")
        #expect(stored["updated_at"] == nil)

        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
        #endif
    }

    @Test("corrupt setup preferences never overwrite unrelated existing bytes")
    func corruptPreferencesFailClosed() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let path = MCPSetupPreferencesStore.path(home: home)
        let original = Data("{not valid json; preserve me".utf8)
        try original.write(to: path)

        #expect(MCPSetupPreferencesStore.load(home: home) == .corrupt)
        #expect(MCPSetupPreferencesStore.load(home: home).isWritable == false)
        #expect(throws: MCPSetupPreferencesError.unreadable) {
            try MCPSetupPreferencesStore.updateServer(
                named: "configured",
                preferences: McpServerPreferences(values: ["region": "us"]),
                home: home
            )
        }
        #expect(try Data(contentsOf: path) == original)
    }

    @Test("server-local rollback preserves independent servers and newer selections")
    func rollbackIsConditionalAndPreservesOtherServers() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = McpServerPreferences(values: ["region": "us"])
        let second = McpServerPreferences(values: ["region": "eu"])
        let unrelated = McpServerPreferences(values: ["account": "independent"])

        let original = try MCPSetupPreferencesStore.updateServer(
            named: "configured", preferences: first, home: home
        )
        #expect(original == nil)
        let independent = try MCPSetupPreferencesStore.updateServer(
            named: "unrelated", preferences: unrelated, home: home
        )
        #expect(independent == nil)
        let replaced = try MCPSetupPreferencesStore.updateServer(
            named: "configured", preferences: second, home: home
        )
        #expect(replaced == first)

        let staleRollback = try MCPSetupPreferencesStore.restoreServer(
            named: "configured",
            previous: nil,
            ifCurrentIs: first,
            home: home
        )
        #expect(staleRollback == false)

        let restored = try MCPSetupPreferencesStore.restoreServer(
            named: "configured",
            previous: first,
            ifCurrentIs: second,
            home: home
        )
        #expect(restored)
        let snapshot = MCPSetupPreferencesStore.load(home: home).file
        #expect(snapshot.servers["configured"] == first)
        #expect(snapshot.servers["unrelated"] == unrelated)
    }

    @Test("blank setup transports remain discoverable without being dialable")
    func blankSetupTransportRemainsVisible() throws {
        let document = try setupDocument(url: "")
        let loaded = MCPConfigLoader.load(from: document)
        #expect(loaded.servers.isEmpty)
        #expect(loaded.enabledServers.isEmpty)
        #expect(loaded.problems.isEmpty)

        let unresolved = try #require(loaded.setupRequiredServers.first)
        #expect(unresolved.name == "configured")
        #expect(unresolved.config.setup?.fields.first?.id == "region")
        #expect(throws: MCPConnectError.setupRequired("configured")) {
            try unresolved.makeTransport(httpTransport: URLSessionHTTPTransport())
        }
    }

    @Test("validated setup preferences resolve URL and private headers before transport exposure")
    func preferencesResolveTemplates() throws {
        let document = try setupDocument(url: "{{endpoint}}")
        let preferences = McpPreferencesFile(servers: [
            "configured": McpServerPreferences(values: ["region": "us"]),
        ])
        let loaded = MCPConfigLoader.load(from: document, preferences: preferences)
        #expect(loaded.problems.isEmpty)
        #expect(loaded.setupRequiredServers.isEmpty)
        #expect(loaded.setupServers.count == 1)

        let declaration = try #require(loaded.enabledServers.first)
        #expect(declaration.config.setup == nil)
        guard case .streamableHttp(let url, _, _, let headers, _, _, _) =
            declaration.config.transport
        else {
            Issue.record("setup declaration did not resolve to HTTP")
            return
        }
        #expect(url == "https://us.example.test/mcp")
        #expect(headers?["Authorization"] == "Bearer owner-private-token")
    }

    @Test("unknown select options remain setup-required and invalid schemas remain visible")
    func invalidSelectionAndSchemaCannotConnect() throws {
        let document = try setupDocument(url: "{{endpoint}}")
        let rejected = MCPConfigLoader.load(
            from: document,
            preferences: McpPreferencesFile(servers: [
                "configured": McpServerPreferences(values: ["region": "unlisted"]),
            ])
        )
        #expect(rejected.servers.isEmpty)
        #expect(rejected.setupRequiredServers.map(\.name) == ["configured"])

        let malformed = try parseTOML("""
        [mcpServers.broken]
        url = "{{endpoint}}"

        [mcpServers.broken.setup]
        fields = []
        """)
        let invalid = MCPConfigLoader.load(from: malformed)
        #expect(invalid.servers.isEmpty)
        #expect(invalid.setupRequiredServers.map(\.name) == ["broken"])
        #expect(invalid.problems.first?.message.contains("exactly one select field") == true)
    }

    @Test("JSON MCP declarations follow the same setup-resolution boundary")
    func jsonDeclarationsResolvePreferences() throws {
        let configuration = """
        {"mcpServers":{"configured":{"url":"{{endpoint}}","setup":{
          "fields":[{"id":"region","label":"Region","type":"select",
                     "options":[{"label":"US","value":"us"}]}],
          "variables":{"endpoint":{"from":"region", "map":{"us":"https://us.test/mcp"}}}
        }}}}
        """
        let unresolved = MCPConfigLoader.load(jsonData: Data(configuration.utf8))
        #expect(unresolved.servers.isEmpty)
        #expect(unresolved.setupRequiredServers.map(\.name) == ["configured"])

        let resolved = MCPConfigLoader.load(
            jsonData: Data(configuration.utf8),
            preferences: McpPreferencesFile(servers: [
                "configured": McpServerPreferences(values: ["region": "us"]),
            ])
        )
        #expect(resolved.enabledServers.first?.transportSummary == "https://us.test/mcp")
    }

    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-mcp-setup-\(UUID().uuidString)")
    }

    private func setupDocument(url: String) throws -> TOMLValue {
        try parseTOML("""
        [mcpServers.configured]
        url = "\(url)"
        headers = { Authorization = "Bearer {{token}}" }

        [[mcpServers.configured.setup.fields]]
        id = "region"
        label = "Region"
        type = "select"
        required = true
        options = [{ label = "United States", value = "us" }]

        [mcpServers.configured.setup.variables.endpoint]
        from = "region"
        map = { us = "https://us.example.test/mcp" }

        [mcpServers.configured.setup.variables.token]
        from = "region"
        map = { us = "owner-private-token" }
        """)
    }
}
