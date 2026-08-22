import Foundation
import Testing
@testable import OpenGrokModels
import OpenGrokSamplingTypes

@Suite("RunInfra provider-isolated model catalog")
struct RunInfraModelsParityTests {
    @Test("stored provider credentials trust only the official HTTPS host")
    func trustedProviderHost() {
        #expect(RunInfraModels.isTrustedAPIBaseURL("https://api.runinfra.ai/v1"))
        #expect(RunInfraModels.isTrustedAPIBaseURL("https://api.runinfra.ai/v1/models"))
        #expect(!RunInfraModels.isTrustedAPIBaseURL("http://api.runinfra.ai/v1"))
        #expect(!RunInfraModels.isTrustedAPIBaseURL("https://api.runinfra.ai.example/v1"))
        #expect(!RunInfraModels.isTrustedAPIBaseURL("https://api.x.ai/v1"))
        #expect(!RunInfraModels.isTrustedAPIBaseURL("not a url"))
    }

    @Test("configured endpoint overrides trim whitespace and trailing slashes")
    func configuredBaseURL() {
        #expect(RunInfraModels.apiBaseURL(environment: [:]) == "https://api.runinfra.ai/v1")
        #expect(
            RunInfraModels.apiBaseURL(environment: [
                RunInfraModels.apiBaseURLEnv: "  https://gateway.example/v2///  "
            ]) == "https://gateway.example/v2"
        )
        #expect(
            RunInfraModels.apiBaseURL(environment: [RunInfraModels.apiBaseURLEnv: "  /  "])
                == RunInfraModels.apiBaseURLDefault
        )
    }

    @Test("official gateway credential wins over the compatibility API-key alias")
    func environmentCredentialPriority() {
        #expect(
            RunInfraModels.environmentAPIKey(environment: [
                RunInfraModels.gatewayKeyEnv: "  primary-secret  ",
                RunInfraModels.apiKeyEnv: "alias-secret",
            ]) == "primary-secret"
        )
        #expect(
            RunInfraModels.environmentAPIKey(environment: [
                RunInfraModels.gatewayKeyEnv: " \t ",
                RunInfraModels.apiKeyEnv: "  alias-secret  ",
            ]) == "alias-secret"
        )
        #expect(RunInfraModels.environmentAPIKey(environment: [:]) == nil)
        #expect(RunInfraModels.environmentAPIKeyIsConfigured(environment: [
            RunInfraModels.apiKeyEnv: "alias-secret"
        ]))
    }

    @Test("stored credentials never follow an endpoint override to a foreign host")
    func storedCredentialsStayProviderScoped() {
        #expect(
            RunInfraModels.selectAPIKey(
                baseURL: RunInfraModels.apiBaseURLDefault,
                environmentKey: nil,
                storedKey: "  stored-secret  "
            ) == "stored-secret"
        )
        #expect(
            RunInfraModels.selectAPIKey(
                baseURL: "https://proxy.example/v1",
                environmentKey: nil,
                storedKey: "stored-secret"
            ) == nil
        )
        #expect(
            RunInfraModels.selectAPIKey(
                baseURL: "https://proxy.example/v1",
                environmentKey: " explicit-secret ",
                storedKey: "stored-secret"
            ) == "explicit-secret"
        )
    }

    @Test("curated hosted lineup preserves upstream ordering, credentials, and routing")
    func curatedHostedLineup() throws {
        let catalog = RunInfraModels.curatedCatalog()
        #expect(catalog.keys == [
            "runinfra:deepseek-v4-flash",
            "runinfra:nemotron-3-5-lightning-30b",
            "runinfra:qwen3-8-2-4t-a95b",
            "runinfra:qwen3-8-27b",
        ])

        for entry in catalog.values() {
            #expect(entry.info.provider == .runinfra)
            #expect(entry.info.apiBackend == .chatCompletions)
            #expect(entry.info.toolMode == .direct)
            #expect(entry.info.supportedInApi)
            #expect(!entry.info.supportsBackendSearch)
            #expect(entry.info.maxCompletionTokens == 32_768)
            #expect(entry.apiKey == nil)
            #expect(entry.envKey?.names == [
                RunInfraModels.gatewayKeyEnv,
                RunInfraModels.apiKeyEnv,
            ])
        }

        #expect(try #require(catalog["runinfra:nemotron-3-5-lightning-30b"]).info.name
            == "Nemotron 3.5 Lightning 30B")
        #expect(try #require(catalog["runinfra:qwen3-8-2-4t-a95b"]).info.name
            == "Qwen3.8 2.4T A95B")
        #expect(try #require(catalog["runinfra:qwen3-8-27b"]).info.name == "Qwen3.8 27B")
    }

    @Test("DeepSeek V4 Flash defaults to max reasoning and a 1,048,576-token context")
    func deepSeekV4FlashCapabilities() throws {
        let entry = try #require(RunInfraModels.curatedCatalog()["runinfra:deepseek-v4-flash"])
        #expect(entry.info.name == "DeepSeek V4 Flash")
        #expect(entry.info.contextWindow == 1_048_576)
        #expect(entry.info.maxCompletionTokens == 32_768)
        #expect(entry.info.supportsReasoningEffort)
        #expect(entry.info.reasoningEffort == .max)
        #expect(entry.info.reasoningEfforts.map(\.value) == [
            .none, .low, .medium, .high, .max
        ])
        #expect(entry.info.reasoningEfforts.filter(\.isDefault).map(\.value) == [.max])
        #expect(entry.info.reasoningEfforts.first?.description
            == "Answer only; skip the billed reasoning stream")
    }

    @Test("Qwen 2.4T refuses disabled reasoning while other hosted models permit it")
    func qwenReasoningCannotBeDisabled() throws {
        let catalog = RunInfraModels.curatedCatalog()
        let qwen = try #require(catalog["runinfra:qwen3-8-2-4t-a95b"])
        #expect(qwen.info.contextWindow == 262_144)
        #expect(qwen.info.reasoningEffort == .high)
        #expect(qwen.info.reasoningEfforts.map(\.value) == [.low, .medium, .high, .max])
        #expect(qwen.info.reasoningEfforts.filter(\.isDefault).map(\.value) == [.high])

        let nemotron = try #require(catalog["runinfra:nemotron-3-5-lightning-30b"])
        #expect(nemotron.info.reasoningEffort == .high)
        #expect(nemotron.info.reasoningEfforts.first?.value == ReasoningEffort.none)

        #expect(RunInfraModels.isKnownReasoningModel(modelID: "DEEPSEEK-V4-FLASH"))
        #expect(!RunInfraModels.isKnownReasoningModel(modelID: "workspace-deployment"))
    }

    @Test("verified workspace deployments remain visible but fail closed on reasoning")
    func dynamicWorkspaceDeployments() throws {
        let wire = Data(#"""
        {"object":"list","data":[
          {"id":" deepseek-v4-flash "},
          {"id":"  "},
          {"id":"workspace-deployment"}
        ]}
        """#.utf8)

        let catalog = try RunInfraModels.parseCatalog(
            wire,
            baseURL: "https://api.runinfra.ai/v1/"
        )

        #expect(catalog.keys == [
            "runinfra:deepseek-v4-flash",
            "runinfra:workspace-deployment",
        ])
        let deployment = try #require(catalog["runinfra:workspace-deployment"])
        #expect(deployment.info.name == "workspace-deployment")
        #expect(deployment.info.baseURL == RunInfraModels.apiBaseURLDefault)
        #expect(deployment.info.contextWindow == 262_144)
        #expect(deployment.info.maxCompletionTokens == 32_768)
        #expect(!deployment.info.supportsReasoningEffort)
        #expect(deployment.info.reasoningEffort == nil)
        #expect(deployment.info.reasoningEfforts.isEmpty)
    }

    @Test("positive served context and output limits override curated defaults")
    func servedWireLimitsOverrideCuratedDefaults() throws {
        let wire = Data(#"""
        {"data":[{
          "id":"deepseek-v4-flash",
          "object":"model",
          "owned_by":"runinfra",
          "created":1785679270,
          "availability":"available",
          "max_request_bytes":3670016,
          "context_window":500000,
          "max_output_tokens":16384,
          "max_concurrent_requests_per_api_key":16
        }]}
        """#.utf8)

        let snapshot = try RunInfraModels.parseCatalogSnapshot(
            wire,
            baseURL: RunInfraModels.apiBaseURLDefault,
            credentialFingerprint: "principal-a"
        )
        let entry = try #require(snapshot.entries["runinfra:deepseek-v4-flash"])
        #expect(entry.info.contextWindow == 500_000)
        #expect(entry.info.maxCompletionTokens == 16_384)
        #expect(snapshot.wireContextPresent)
        #expect(snapshot.isAuthoritative)
        #expect(snapshot.matchesCredential(fingerprint: "principal-a"))
        #expect(!snapshot.matchesCredential(fingerprint: "principal-b"))
    }

    @Test("zero served limits cannot erase nonzero curated model limits")
    func zeroWireLimitsRetainCuratedDefaults() throws {
        let wire = Data(#"""
        {"data":[
          {"id":"deepseek-v4-flash","context_window":0,"max_output_tokens":0},
          {"id":"workspace-deployment","context_window":0,"max_output_tokens":0}
        ]}
        """#.utf8)

        let snapshot = try RunInfraModels.parseCatalogSnapshot(
            wire,
            baseURL: RunInfraModels.apiBaseURLDefault,
            credentialFingerprint: "principal-a"
        )
        #expect(!snapshot.wireContextPresent)
        #expect(try #require(snapshot.entries["runinfra:deepseek-v4-flash"])
            .info.contextWindow == 1_048_576)
        #expect(try #require(snapshot.entries["runinfra:deepseek-v4-flash"])
            .info.maxCompletionTokens == 32_768)
        #expect(try #require(snapshot.entries["runinfra:workspace-deployment"])
            .info.contextWindow == 262_144)
    }

    @Test("empty or absent wire model lists use a non-authoritative curated fallback")
    func emptyResponsesUseNonAuthoritativeFallback() throws {
        for payload in [#"{"data":[]}"#, #"{"object":"list"}"#,
                        #"{"data":[{"id":"  "}]}"#] {
            let snapshot = try RunInfraModels.parseCatalogSnapshot(
                Data(payload.utf8),
                baseURL: RunInfraModels.apiBaseURLDefault,
                credentialFingerprint: "principal-a"
            )
            #expect(snapshot.entries.keys == RunInfraModels.curatedCatalog().keys)
            #expect(snapshot.credentialFingerprint == nil)
            #expect(!snapshot.isAuthoritative)
            #expect(!snapshot.matchesCredential(fingerprint: "principal-a"))
            #expect(!snapshot.wireContextPresent)
        }
    }

    @Test("malformed ids and out-of-range served token limits fail closed")
    func malformedWireResponsesFailClosed() {
        let malformedPayloads = [
            #"[]"#,
            #"{"data":null}"#,
            #"{"data":[{}]}"#,
            #"{"data":[{"id":4}]}"#,
            #"{"data":[{"id":"model","context_window":-1}]}"#,
            #"{"data":[{"id":"model","max_output_tokens":4294967296}]}"#,
        ]

        for payload in malformedPayloads {
            #expect(throws: ModelsError.self) {
                try RunInfraModels.parseCatalog(
                    Data(payload.utf8),
                    baseURL: RunInfraModels.apiBaseURLDefault
                )
            }
        }
    }

    @Test("fallback snapshots cannot be reused across credential principals")
    func snapshotCredentialIsolation() {
        let fallback = RunInfraModelsCatalog(
            entries: RunInfraModels.curatedCatalog(),
            credentialFingerprint: nil
        )
        #expect(!fallback.isAuthoritative)
        #expect(!fallback.matchesCredential(fingerprint: "principal-a"))

        let authenticated = RunInfraModelsCatalog(
            entries: RunInfraModels.curatedCatalog(),
            credentialFingerprint: "principal-a"
        )
        #expect(authenticated.isAuthoritative)
        #expect(authenticated.matchesCredential(fingerprint: "principal-a"))
        #expect(!authenticated.matchesCredential(fingerprint: "principal-b"))
    }

    @Test("provider credential fingerprints use the upstream BLAKE3 digest")
    func credentialFingerprintUsesBlake3() {
        #expect(
            RunInfraModels.credentialFingerprint(apiKey: "abc")
                == "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"
        )
    }

    @Test("provider error excerpts redact credentials, collapse newlines, and cap length")
    func errorExcerptsNeverLeakCredentials() {
        #expect(
            RunInfraModels.safeErrorExcerpt(
                "invalid runinfra-secret\r\nretry runinfra-secret",
                apiKey: "runinfra-secret"
            ) == "invalid [REDACTED]  retry [REDACTED]"
        )
        #expect(
            RunInfraModels.safeErrorExcerpt(String(repeating: "x", count: 700), apiKey: "secret")
                .count == 512
        )
    }
}
