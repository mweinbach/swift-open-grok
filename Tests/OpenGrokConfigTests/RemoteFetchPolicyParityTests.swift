import Foundation
import Testing
@testable import OpenGrokConfig

@Suite("Deployment-authoritative remote fetch policy")
struct RemoteFetchPolicyParityTests {
    @Test("an absent remote-fetch policy defaults to enabled")
    func absentPolicyDefaultsOn() {
        #expect(remoteFetchEnabled(from: ConfigLayers()))
    }

    @Test("the user preference applies when no deployment policy exists")
    func userPreference() throws {
        var layers = ConfigLayers()
        layers.user = try policy(false)
        #expect(!remoteFetchEnabled(from: layers))

        layers.user = try policy(true)
        #expect(remoteFetchEnabled(from: layers))
    }

    @Test("managed policy outranks contradictory user configuration in both directions")
    func managedOutranksUser() throws {
        var layers = ConfigLayers()
        layers.user = try policy(true)
        layers.managed = try policy(false)
        #expect(!remoteFetchEnabled(from: layers))

        layers.user = try policy(false)
        layers.managed = try policy(true)
        #expect(remoteFetchEnabled(from: layers))
    }

    @Test("system-managed policy outranks contradictory user configuration")
    func systemManagedOutranksUser() throws {
        var layers = ConfigLayers()
        layers.user = try policy(true)
        layers.systemManaged = try policy(false)
        #expect(!remoteFetchEnabled(from: layers))

        layers.user = try policy(false)
        layers.systemManaged = try policy(true)
        #expect(remoteFetchEnabled(from: layers))
    }

    @Test("user-managed policy outranks the system-managed layer")
    func managedOutranksSystemManaged() throws {
        var layers = ConfigLayers()
        layers.managed = try policy(false)
        layers.systemManaged = try policy(true)
        #expect(!remoteFetchEnabled(from: layers))

        layers.managed = try policy(true)
        layers.systemManaged = try policy(false)
        #expect(remoteFetchEnabled(from: layers))
    }

    @Test("a requirements pin outranks managed and user policy in both directions")
    func requirementsOutrankManaged() throws {
        var layers = ConfigLayers()
        layers.user = try policy(true)
        layers.managed = try policy(true)
        layers.userRequirements = try policy(false)
        #expect(!remoteFetchEnabled(from: layers))

        layers.user = try policy(false)
        layers.managed = try policy(false)
        layers.userRequirements = try policy(true)
        #expect(remoteFetchEnabled(from: layers))
    }

    @Test("system requirements outrank user requirements and MDM outranks both")
    func requirementsTierOrdering() throws {
        var layers = ConfigLayers()
        layers.userRequirements = try policy(true)
        layers.systemRequirements = try policy(false)
        #expect(!remoteFetchEnabled(from: layers))

        layers.mdmRequirements = try policy(true)
        #expect(remoteFetchEnabled(from: layers))

        layers.systemRequirements = try policy(true)
        layers.mdmRequirements = try policy(false)
        #expect(!remoteFetchEnabled(from: layers))
    }

    @Test("missing or non-boolean higher-tier values do not mask valid lower policy")
    func nonBooleanPolicyIsAbsent() throws {
        var layers = ConfigLayers()
        layers.user = try policy(false)
        layers.managed = try parseTOML("[features]\nremote_fetch = \"true\"\n")
        layers.userRequirements = try parseTOML("[features]\nanother_flag = true\n")
        #expect(!remoteFetchEnabled(from: layers))
    }

    @Test("the corruption fallback remains enabled only when every administrator tier is absent")
    func absentFallbackPolicyDefaultsOn() {
        #expect(remoteFetchEnabledFromPolicyLayers(
            requirements: nil,
            managed: nil,
            systemManaged: nil
        ))
    }

    @Test("independently loaded managed and system-managed denies survive full-load failure")
    func fallbackPreservesManagedDenies() throws {
        #expect(!remoteFetchEnabledFromPolicyLayers(
            requirements: nil,
            managed: try policy(false),
            systemManaged: nil
        ))
        #expect(!remoteFetchEnabledFromPolicyLayers(
            requirements: nil,
            managed: nil,
            systemManaged: try policy(false)
        ))
    }

    @Test("the corruption fallback retains requirements then managed then system-managed precedence")
    func fallbackPolicyTierOrdering() throws {
        #expect(remoteFetchEnabledFromPolicyLayers(
            requirements: try policy(true),
            managed: try policy(false),
            systemManaged: try policy(false)
        ))
        #expect(!remoteFetchEnabledFromPolicyLayers(
            requirements: nil,
            managed: try policy(false),
            systemManaged: try policy(true)
        ))
    }

    @Test("the public disk resolver honors a managed deny despite a user enable")
    func diskManagedDenyBeatsUserEnable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try writePolicy(true, filename: "config.toml", in: fixture.home)
        try writePolicy(false, filename: "managed_config.toml", in: fixture.home)

        #expect(!resolveTrustedRemoteFetchEnabled(environment: fixture.environment))
    }

    @Test("the public disk resolver preserves managed allow over a user disable")
    func diskManagedAllowBeatsUserDisable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try writePolicy(false, filename: "config.toml", in: fixture.home)
        try writePolicy(true, filename: "managed_config.toml", in: fixture.home)

        #expect(resolveTrustedRemoteFetchEnabled(environment: fixture.environment))
    }

    @Test("an independently readable requirements deny survives corrupt user config")
    func corruptUserConfigPreservesRequirementsDeny() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try writeRaw("[features\nremote_fetch = true\n", filename: "config.toml", in: fixture.home)
        try writePolicy(true, filename: "managed_config.toml", in: fixture.home)
        try writePolicy(false, filename: "requirements.toml", in: fixture.home)

        #expect(!resolveTrustedRemoteFetchEnabled(environment: fixture.environment))
    }

    @Test("an independently readable managed deny survives corrupt user config")
    func corruptUserConfigPreservesManagedDeny() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try writeRaw("[features\nremote_fetch = true\n", filename: "config.toml", in: fixture.home)
        try writePolicy(false, filename: "managed_config.toml", in: fixture.home)

        #expect(!resolveTrustedRemoteFetchEnabled(environment: fixture.environment))
    }

    @Test("requirements precedence survives corrupt user config in the allow direction")
    func corruptUserConfigPreservesRequirementsPrecedence() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try writeRaw("[features\nremote_fetch = false\n", filename: "config.toml", in: fixture.home)
        try writePolicy(false, filename: "managed_config.toml", in: fixture.home)
        try writePolicy(true, filename: "requirements.toml", in: fixture.home)

        #expect(resolveTrustedRemoteFetchEnabled(environment: fixture.environment))
    }

    @Test("corrupt managed config cannot hide an independently readable requirements deny")
    func corruptManagedConfigPreservesRequirementsDeny() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try writeRaw("[features\nremote_fetch = true\n", filename: "managed_config.toml", in: fixture.home)
        try writePolicy(false, filename: "requirements.toml", in: fixture.home)

        #expect(!resolveTrustedRemoteFetchEnabled(environment: fixture.environment))
    }

    @Test("there is no environment-variable bypass for an administrator deny")
    func noEnvironmentBypass() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try writePolicy(false, filename: "managed_config.toml", in: fixture.home)
        var environment = fixture.environment
        environment["GROK_REMOTE_FETCH"] = "true"
        environment["OPENGROK_REMOTE_FETCH"] = "true"

        #expect(!resolveTrustedRemoteFetchEnabled(environment: environment))
    }

    private func policy(_ enabled: Bool) throws -> TOMLValue {
        try parseTOML("[features]\nremote_fetch = \(enabled)\n")
    }

    private func makeFixture() throws -> (home: URL, environment: [String: String]) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-remote-fetch-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (home, ["OPENGROK_HOME": home.path, "HOME": home.path])
    }

    private func writePolicy(_ enabled: Bool, filename: String, in directory: URL) throws {
        try writeRaw("[features]\nremote_fetch = \(enabled)\n", filename: filename, in: directory)
    }

    private func writeRaw(_ text: String, filename: String, in directory: URL) throws {
        try text.write(
            to: directory.appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )
    }
}
