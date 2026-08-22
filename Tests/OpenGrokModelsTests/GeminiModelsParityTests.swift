import Foundation
import Testing
@testable import OpenGrokModels
import OpenGrokSamplingTypes

@Suite("Google Gemini provider parity")
struct GeminiModelsParityTests {
    private let curatedIDs = [
        "gemini-3.7-flash",
        "gemini-3.6-flash",
        "gemini-3.5-flash-lite",
        "gemini-3.1-pro-preview",
    ]

    @Test("official OpenAI-compatible endpoint and environment aliases match upstream")
    func endpointConstants() {
        #expect(
            GeminiModels.apiBaseURLDefault
                == "https://generativelanguage.googleapis.com/v1beta/openai"
        )
        #expect(GeminiModels.apiBaseURLEnv == "OPENGROK_GEMINI_API_BASE_URL")
        #expect(GeminiModels.apiKeyEnv == "GEMINI_API_KEY")
        #expect(GeminiModels.googleAPIKeyEnv == "GOOGLE_API_KEY")
    }

    @Test("endpoint overrides trim whitespace and slashes and blank values fall back")
    func endpointOverride() {
        #expect(GeminiModels.apiBaseURL(environment: [:]) == GeminiModels.apiBaseURLDefault)
        #expect(
            GeminiModels.apiBaseURL(environment: [
                GeminiModels.apiBaseURLEnv: "  https://proxy.example/v1///  "
            ]) == "https://proxy.example/v1"
        )
        #expect(
            GeminiModels.apiBaseURL(environment: [GeminiModels.apiBaseURLEnv: "  ///  "])
                == GeminiModels.apiBaseURLDefault
        )
    }

    @Test("stored-key trust requires HTTPS and Google's exact provider host")
    func trustedHost() {
        #expect(GeminiModels.isTrustedAPIBaseURL(GeminiModels.apiBaseURLDefault))
        #expect(GeminiModels.isTrustedAPIBaseURL(
            "https://generativelanguage.googleapis.com/v1beta/openai/models"
        ))
        #expect(!GeminiModels.isTrustedAPIBaseURL(
            "http://generativelanguage.googleapis.com/v1beta/openai"
        ))
        #expect(!GeminiModels.isTrustedAPIBaseURL(
            "https://generativelanguage.googleapis.com.evil.example/v1"
        ))
        #expect(!GeminiModels.isTrustedAPIBaseURL(
            "https://generativelanguage.googleapis.com@evil.example/v1"
        ))
        #expect(!GeminiModels.isTrustedAPIBaseURL("https://api.x.ai/v1"))
    }

    @Test("stored keys never follow untrusted overrides while explicit keys remain usable")
    func storedCredentialIsolation() {
        #expect(
            GeminiModels.selectAPIKey(
                baseURL: GeminiModels.apiBaseURLDefault,
                environmentKey: nil,
                storedKey: "  stored-gemini-secret  "
            ) == "stored-gemini-secret"
        )
        #expect(
            GeminiModels.selectAPIKey(
                baseURL: "https://proxy.example/v1",
                environmentKey: nil,
                storedKey: "stored-gemini-secret"
            ) == nil
        )
        #expect(
            GeminiModels.selectAPIKey(
                baseURL: "https://proxy.example/v1",
                environmentKey: "  explicit-proxy-key  ",
                storedKey: "stored-gemini-secret"
            ) == "explicit-proxy-key"
        )
    }

    @Test("GEMINI_API_KEY precedes GOOGLE_API_KEY and blank primary falls back")
    func credentialAliasPrecedence() {
        #expect(
            GeminiModels.environmentAPIKey(environment: [
                GeminiModels.apiKeyEnv: "  gemini-primary  ",
                GeminiModels.googleAPIKeyEnv: "google-secondary",
            ]) == "gemini-primary"
        )
        #expect(
            GeminiModels.apiKey(environment: [
                GeminiModels.apiKeyEnv: "  \t ",
                GeminiModels.googleAPIKeyEnv: "  google-secondary  ",
            ]) == "google-secondary"
        )
        #expect(GeminiModels.environmentAPIKey(environment: [:]) == nil)
        #expect(!GeminiModels.environmentAPIKeyIsConfigured(environment: [:]))
        #expect(GeminiModels.environmentAPIKeyIsConfigured(environment: [
            GeminiModels.googleAPIKeyEnv: "google-secondary"
        ]))
    }

    @Test("curated catalog always contains exactly four reviewed models in Rust order")
    func exactCuratedMembershipAndOrder() {
        #expect(GeminiModels.curated.map(\.id) == curatedIDs)
        #expect(
            GeminiModels.curatedCatalog().keys
                == curatedIDs.map { "gemini:\($0)" }
        )
    }

    @Test("every curated entry uses Gemini chat completions, direct tools and scoped aliases")
    func curatedEntryMetadata() throws {
        let catalog = GeminiModels.curatedCatalog(baseURL: "https://proxy.example/v1///")
        for curated in GeminiModels.curated {
            let entry = try #require(catalog[GeminiModels.catalogKey(modelID: curated.id)])
            #expect(entry.info.id == "gemini:\(curated.id)")
            #expect(entry.info.model == curated.id)
            #expect(entry.info.name == curated.name)
            #expect(entry.info.description == curated.description)
            #expect(entry.info.provider == .gemini)
            #expect(entry.info.apiBackend == .chatCompletions)
            #expect(entry.info.toolMode == .direct)
            #expect(entry.info.baseURL == "https://proxy.example/v1")
            #expect(entry.info.contextWindow == 1_048_576)
            #expect(entry.info.maxCompletionTokens == 65_536)
            #expect(entry.info.supportsReasoningEffort)
            #expect(!entry.info.supportsBackendSearch)
            #expect(entry.info.supportedInApi)
            #expect(entry.envKey?.names == ["GEMINI_API_KEY", "GOOGLE_API_KEY"])
            #expect(entry.apiKey == nil)
        }
    }

    @Test("3.7 Flash and 3.1 Pro cannot offer unsupported minimal thinking")
    func restrictedReasoningMenus() throws {
        let catalog = GeminiModels.curatedCatalog()
        for id in ["gemini-3.7-flash", "gemini-3.1-pro-preview"] {
            let info = try #require(catalog["gemini:\(id)"]).info
            #expect(info.reasoningEfforts.map(\.value) == [.low, .medium, .high])
            #expect(!GeminiModels.supportsMinimalReasoning(modelID: id))
        }
    }

    @Test("3.6 Flash and Flash-Lite offer minimal thinking")
    func minimalReasoningMenus() throws {
        let catalog = GeminiModels.curatedCatalog()
        for id in ["gemini-3.6-flash", "gemini-3.5-flash-lite"] {
            let info = try #require(catalog["gemini:\(id)"]).info
            #expect(info.reasoningEfforts.map(\.value) == [.minimal, .low, .medium, .high])
            #expect(GeminiModels.supportsMinimalReasoning(modelID: id))
        }
    }

    @Test("each model has exactly one upstream model-specific default reasoning effort")
    func modelSpecificReasoningDefaults() throws {
        let expectations: [(String, ReasoningEffort)] = [
            ("gemini-3.7-flash", .medium),
            ("gemini-3.6-flash", .medium),
            ("gemini-3.5-flash-lite", .minimal),
            ("gemini-3.1-pro-preview", .high),
        ]
        let catalog = GeminiModels.curatedCatalog()
        for (id, expected) in expectations {
            let info = try #require(catalog["gemini:\(id)"]).info
            #expect(info.reasoningEffort == expected)
            #expect(info.reasoningEfforts.filter(\.isDefault).map(\.value) == [expected])
            #expect(GeminiModels.defaultReasoningEffort(modelID: id) == expected)
        }
    }

    @Test("unsupported thinking effort values are normalized exactly like the Rust sampler")
    func reasoningEffortNormalization() {
        #expect(GeminiModels.normalizedReasoningEffort(
            modelID: "gemini-3.6-flash", effort: .none
        ) == nil)
        #expect(GeminiModels.normalizedReasoningEffort(
            modelID: "gemini-3.7-flash", effort: .minimal
        ) == .low)
        #expect(GeminiModels.normalizedReasoningEffort(
            modelID: "gemini-3.1-pro-preview", effort: .minimal
        ) == .low)
        #expect(GeminiModels.normalizedReasoningEffort(
            modelID: "gemini-3.5-flash-lite", effort: .minimal
        ) == .minimal)
        #expect(GeminiModels.normalizedReasoningEffort(modelID: nil, effort: .minimal) == .minimal)
        for effort in [ReasoningEffort.xhigh, .max, .ultra] {
            #expect(GeminiModels.normalizedReasoningEffort(
                modelID: "gemini-3.1-pro-preview", effort: effort
            ) == .high)
        }
    }

    @Test("curated context overrides are slug-scoped and zero never replaces the fallback")
    func contextOverride() throws {
        let catalog = GeminiModels.curatedCatalog(contextBySlug: [
            "gemini-3.7-flash": 2_097_152,
            "gemini-3.6-flash": 0,
            "imagen-4.0-generate-001": 99,
        ])
        #expect(try #require(catalog["gemini:gemini-3.7-flash"]).info.contextWindow == 2_097_152)
        #expect(try #require(catalog["gemini:gemini-3.6-flash"]).info.contextWindow == 1_048_576)
        #expect(catalog.count == 4)
    }

    @Test("wire metadata enriches curated context and output limits without adding remote models")
    func remoteMetadataEnrichment() throws {
        let data = Data(#"""
        {"data":[
          {"id":" models/gemini-3.7-flash ","context_window":2097152,"max_output_tokens":8192},
          {"id":"gemini-3.6-flash","context_length":1500000,"output_token_limit":32768},
          {"id":"gemini-3.5-flash-lite","input_token_limit":2000000},
          {"id":"imagen-4.0-generate-001","context_window":9999999},
          {"id":"gemini-2.5-flash","context_window":9999999}
        ]}
        """#.utf8)

        let catalog = try GeminiModels.parseCatalog(data, baseURL: GeminiModels.apiBaseURLDefault)
        #expect(catalog.keys == curatedIDs.map { "gemini:\($0)" })
        let flash37 = try #require(catalog["gemini:gemini-3.7-flash"])
        #expect(flash37.info.contextWindow == 2_097_152)
        #expect(flash37.info.maxCompletionTokens == 8_192)
        let flash36 = try #require(catalog["gemini:gemini-3.6-flash"])
        #expect(flash36.info.contextWindow == 1_500_000)
        #expect(flash36.info.maxCompletionTokens == 32_768)
        #expect(try #require(catalog["gemini:gemini-3.5-flash-lite"]).info.contextWindow == 2_000_000)
        #expect(try #require(catalog["gemini:gemini-3.1-pro-preview"]).info.contextWindow == 1_048_576)
        #expect(catalog["gemini:imagen-4.0-generate-001"] == nil)
        #expect(catalog["gemini:gemini-2.5-flash"] == nil)
    }

    @Test("remote omission, empty arrays and missing data never remove curated entries")
    func remoteResponseCannotRemoveModels() throws {
        for response in [
            #"{"data":[]}"#,
            #"{"object":"list"}"#,
            #"{"data":[{"id":"imagen-4.0-generate-001"}]}"#,
        ] {
            let catalog = try GeminiModels.parseCatalog(
                Data(response.utf8),
                baseURL: GeminiModels.apiBaseURLDefault
            )
            #expect(catalog.keys == curatedIDs.map { "gemini:\($0)" })
        }
    }

    @Test("context parsing returns only positive limits for reviewed raw Gemini slugs")
    func contextEnrichmentProjection() throws {
        let response = Data(#"""
        {"data":[
          {"id":"models/gemini-3.7-flash","context_length":2097152},
          {"id":"gemini-3.6-flash","max_output_tokens":8192},
          {"id":"gemini-3.5-flash-lite","context_window":0},
          {"id":"imagen-4.0-generate-001","context_window":888888}
        ]}
        """#.utf8)
        #expect(try GeminiModels.parseContextEnrichment(response) == [
            "gemini-3.7-flash": 2_097_152
        ])
    }

    @Test("present zero-priority limits suppress lower-priority aliases like serde's or chain")
    func zeroValuePriority() throws {
        let response = Data(#"""
        {"data":[{"id":"gemini-3.7-flash","context_window":0,
          "context_length":2097152,"max_output_tokens":0,"output_token_limit":8192}]}
        """#.utf8)
        let entry = try #require(GeminiModels.parseCatalog(
            response,
            baseURL: GeminiModels.apiBaseURLDefault
        )["gemini:gemini-3.7-flash"])
        #expect(entry.info.contextWindow == GeminiModels.defaultContextWindow)
        #expect(entry.info.maxCompletionTokens == GeminiModels.defaultMaxOutputTokens)
    }

    @Test("duplicate enriched wire records replace earlier reviewed model limits")
    func duplicateWireRecords() throws {
        let response = Data(#"""
        {"data":[
          {"id":"gemini-3.7-flash","context_window":1200000,"max_output_tokens":8192},
          {"id":"gemini-3.7-flash","context_length":2100000}
        ]}
        """#.utf8)
        let entry = try #require(GeminiModels.parseCatalog(
            response,
            baseURL: GeminiModels.apiBaseURLDefault
        )["gemini:gemini-3.7-flash"])
        #expect(entry.info.contextWindow == 2_100_000)
        #expect(entry.info.maxCompletionTokens == GeminiModels.defaultMaxOutputTokens)
    }

    @Test("malformed roots, model records and null data fail instead of publishing partial catalogs")
    func malformedRemoteResponsesFailClosed() {
        let malformed = [
            "[1,2,3]",
            #"{"data":null}"#,
            #"{"data":{}}"#,
            #"{"data":[{}]}"#,
            #"{"data":[{"id":17}]}"#,
            #"{"data":[{"id":"gemini-3.7-flash","context_window":1.5}]}"#,
        ]
        for response in malformed {
            #expect(throws: ModelsError.self) {
                try GeminiModels.parseCatalog(
                    Data(response.utf8),
                    baseURL: GeminiModels.apiBaseURLDefault
                )
            }
        }
    }

    @Test("negative and overflowing context or output limits fail serde-compatible decoding")
    func malformedNumericLimitsFailClosed() {
        let malformed = [
            #"{"data":[{"id":"gemini-3.7-flash","context_window":-1}]}"#,
            #"{"data":[{"id":"gemini-3.7-flash","context_window":18446744073709551616}]}"#,
            #"{"data":[{"id":"gemini-3.7-flash","max_output_tokens":4294967296}]}"#,
            #"{"data":[{"id":"imagen-other","max_output_tokens":-1}]}"#,
        ]
        for response in malformed {
            #expect(throws: ModelsError.self) {
                try GeminiModels.parseCatalog(
                    Data(response.utf8),
                    baseURL: GeminiModels.apiBaseURLDefault
                )
            }
        }
    }

    @Test("credential fingerprints use Rust-compatible full BLAKE3 digests")
    func credentialFingerprints() {
        #expect(
            GeminiModels.credentialFingerprint(apiKey: "")
                == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
        )
        let first = GeminiModels.credentialFingerprint(apiKey: "gemini-first-secret")
        let second = GeminiModels.credentialFingerprint(apiKey: "gemini-second-secret")
        #expect(first.count == 64)
        #expect(first != second)
        #expect(first == GeminiModels.credentialFingerprint(apiKey: "gemini-first-secret"))
        #expect(!first.contains("gemini-first-secret"))
    }

    @Test("cached catalogs require the same authenticated credential and never accept missing hashes")
    func cacheCredentialIsolation() {
        let fingerprint = GeminiModels.credentialFingerprint(apiKey: "gemini-first-secret")
        let catalog = GeminiModelsCatalog(
            entries: GeminiModels.curatedCatalog(),
            credentialFingerprint: fingerprint
        )
        #expect(catalog.isAuthoritative)
        #expect(catalog.matchesCredential(fingerprint: fingerprint))
        #expect(!catalog.matchesCredential(fingerprint: nil))
        #expect(!catalog.matchesCredential(fingerprint: GeminiModels.credentialFingerprint(
            apiKey: "gemini-second-secret"
        )))
        let unauthenticated = GeminiModelsCatalog(entries: GeminiModels.curatedCatalog())
        #expect(!unauthenticated.matchesCredential(fingerprint: nil))
        #expect(!unauthenticated.matchesCredential(fingerprint: fingerprint))
    }

    @Test("enrichment status ignores uncurated remote records and preserves authentication")
    func enrichedCatalogState() throws {
        let fingerprint = GeminiModels.credentialFingerprint(apiKey: "gemini-catalog-secret")
        let enriched = try GeminiModels.enrichedCatalog(
            Data(#"{"data":[{"id":"gemini-3.6-flash","max_output_tokens":8192}]}"#.utf8),
            baseURL: GeminiModels.apiBaseURLDefault,
            credentialFingerprint: fingerprint
        )
        #expect(enriched.enriched)
        #expect(enriched.matchesCredential(fingerprint: fingerprint))

        let uncuratedOnly = try GeminiModels.enrichedCatalog(
            Data(#"{"data":[{"id":"imagen-4","context_window":999999}]}"#.utf8),
            baseURL: GeminiModels.apiBaseURLDefault,
            credentialFingerprint: fingerprint
        )
        #expect(!uncuratedOnly.enriched)
        #expect(uncuratedOnly.entries.keys == curatedIDs.map { "gemini:\($0)" })
    }

    @Test("provider error excerpts redact reflected keys, collapse newlines and cap output")
    func safeProviderErrors() {
        #expect(
            GeminiModels.safeErrorExcerpt(
                "request rejected for gemini-secret\r\ntry again",
                apiKey: "gemini-secret"
            ) == "request rejected for [REDACTED]  try again"
        )
        #expect(GeminiModels.safeErrorExcerpt(String(repeating: "x", count: 600), apiKey: "secret").count == 512)
    }
}
