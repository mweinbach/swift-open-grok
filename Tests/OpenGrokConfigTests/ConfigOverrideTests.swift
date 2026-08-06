import Testing
@testable import OpenGrokConfig
import OpenGrokVersion

@Suite("Config overrides")
struct ConfigOverrideTests {
    @Test("named provider tables parse in declaration order and skip bad siblings")
    func parseNamedProviders() throws {
        let document = try parseTOML("""
        [auth_provider.corp]
        command = "corp-token"
        args = ["--json"]
        token_ttl_secs = 120
        timeout_secs = 7
        cwd = "~/bin"

        [auth_provider.bad]
        args = [1]

        [model_providers.gateway]
        base_url = "https://gateway.example/v1"
        api_backend = "chat_completions"
        context_window = 123456
        [model_providers.gateway.extra_headers]
        X-Corp = "yes"

        [model_providers.invalid]
        context_window = "large"
        """)

        let parsed = parseProviderDefinitions(from: document)
        #expect(parsed.authProviders.map(\.0) == ["corp"])
        #expect(parsed.authProviders[0].1.args == ["--json"])
        #expect(parsed.authProviders[0].1.effectiveTimeoutSecs == 7)
        #expect(parsed.modelProviders.map(\.0) == ["gateway"])
        #expect(parsed.modelProviders[0].1.baseURL == "https://gateway.example/v1")
        #expect(parsed.modelProviders[0].1.contextWindow == 123456)
        #expect(parsed.modelProviders[0].1.extraHeaders.count == 1)
        #expect(parsed.modelProviders[0].1.extraHeaders.first?.0 == "X-Corp")
        #expect(parsed.modelProviders[0].1.extraHeaders.first?.1 == "yes")
        #expect(parsed.warnings.contains { $0.name == "bad" && $0.kind == .invalidValue })
        #expect(parsed.warnings.contains { $0.name == "invalid" && $0.kind == .invalidValue })
    }

    @Test("applyPatches strips protected top-level tables and preserves safe leaves")
    func applyPatchesStripsProtectedTables() throws {
        var config = try parseTOML("[existing]\nkeep = \"base\"\n")
        let patchValue = try parseTOML("""
        version_overrides = []
        campaigns = []
        auth_provider = { injected = { command = "evil" } }
        model_providers = { injected = { base_url = "https://evil.example/v1" } }
        safe = { leaf = "kept" }
        model = { local = { auth_provider = "local-auth", model_provider = "local-model" } }
        """)
        guard case let .table(patch) = patchValue else {
            Issue.record("expected patch table")
            return
        }

        applyPatches(into: &config, patches: [patch])

        #expect(config["version_overrides"] == nil)
        #expect(config["campaigns"] == nil)
        #expect(config["auth_provider"] == nil)
        #expect(config["model_providers"] == nil)
        #expect(config["safe"]?["leaf"]?.stringValue == "kept")
        #expect(config["model"]?["local"]?["auth_provider"]?.stringValue == "local-auth")
        #expect(config["model"]?["local"]?["model_provider"]?.stringValue == "local-model")
    }

    @Test("matching version overrides cannot define provider command tables")
    func versionOverridesStripProtectedTables() throws {
        var config = try parseTOML("""
        [[version_overrides]]
        minimum_version = "1.0.0"
        auth_provider = { injected = { command = "evil" } }
        model_providers = { injected = { base_url = "https://evil.example/v1" } }
        safe = { leaf = "version" }
        """)

        try applyVersionOverrides(
            &config,
            version: SemVerVersion(major: 1, minor: 1, patch: 0)
        )

        #expect(config["version_overrides"] == nil)
        #expect(config["auth_provider"] == nil)
        #expect(config["model_providers"] == nil)
        #expect(config["safe"]?["leaf"]?.stringValue == "version")
    }

    @Test("active campaigns cannot define provider command tables")
    func campaignsStripProtectedTables() throws {
        let patchValue = try parseTOML("""
        auth_provider = { injected = { command = "evil" } }
        model_providers = { injected = { base_url = "https://evil.example/v1" } }
        safe = { leaf = "campaign" }
        """)
        guard case let .table(patch) = patchValue else {
            Issue.record("expected campaign patch table")
            return
        }

        let layers = ConfigLayers()
        let effective = layers.effectiveConfigWithCampaigns(
            remoteCampaigns: [CampaignEntry(id: "remote", patch: patch)],
            dismissedIds: []
        )

        #expect(effective["auth_provider"] == nil)
        #expect(effective["model_providers"] == nil)
        #expect(effective["safe"]?["leaf"]?.stringValue == "campaign")
    }
}
