// ProviderExpansionParityTests.swift
//
// Provider identity and trust-contract parity for Rust
// `xai-grok-sampling-types/src/types.rs:1185-1222,1545-1599,1685-1782`.

import Foundation
import Testing
@testable import OpenGrokSamplingTypes

@Suite("Expanded provider identity and trust policy")
struct ProviderExpansionParityTests {
    private func decode(_ raw: String) throws -> ModelProvider {
        try JSONDecoder().decode(ModelProvider.self, from: Data("\"\(raw)\"".utf8))
    }

    @Test("RunInfra accepts exactly the upstream provider aliases")
    func runinfraAliases() throws {
        #expect(try decode("runinfra") == .runinfra)
        #expect(try decode("run_infra") == .runinfra)
        #expect(try decode("run-infra") == .runinfra)
        #expect(try decode("RUNINFRA") == .runinfra)
    }

    @Test("Gemini accepts Google's upstream API and AI Studio aliases")
    func geminiAliases() throws {
        for alias in ["gemini", "google", "google_gemini", "ai_studio", "aistudio", "gemini_api"] {
            #expect(try decode(alias) == .gemini)
        }
        #expect(try decode("GOOGLE_GEMINI") == .gemini)
    }

    @Test("OpenRouter accepts its canonical and separator aliases")
    func openRouterAliases() throws {
        #expect(try decode("openrouter") == .openRouter)
        #expect(try decode("open_router") == .openRouter)
        #expect(try decode("open-router") == .openRouter)
        #expect(try decode("OPENROUTER") == .openRouter)
    }

    @Test("aliases always encode back to canonical persisted identifiers")
    func canonicalEncoding() throws {
        let cases: [(ModelProvider, String)] = [
            (.runinfra, "runinfra"),
            (.gemini, "gemini"),
            (.openRouter, "openrouter"),
        ]

        for (provider, expected) in cases {
            #expect(provider.asString == expected)
            #expect(provider.rawValue == expected)
            let encoded = try JSONEncoder().encode(provider)
            #expect(String(decoding: encoded, as: UTF8.self) == "\"\(expected)\"")
            #expect(try JSONDecoder().decode(ModelProvider.self, from: encoded) == provider)
        }
    }

    @Test("display names match the Rust provider registry")
    func displayNames() {
        #expect(ModelProvider.runinfra.name == "RunInfra")
        #expect(ModelProvider.gemini.name == "Google Gemini")
        #expect(ModelProvider.openRouter.name == "OpenRouter")
        #expect(ProviderProfile.runinfra.name == "RunInfra")
        #expect(ProviderProfile.gemini.name == "Google Gemini")
        #expect(ProviderProfile.openRouter.name == "OpenRouter")
    }

    @Test("provider and profile predicates distinguish each new identity")
    func identityPredicates() {
        #expect(ModelProvider.runinfra.isRuninfra)
        #expect(!ModelProvider.runinfra.isGemini)
        #expect(!ModelProvider.runinfra.isOpenRouter)
        #expect(ModelProvider.gemini.isGemini)
        #expect(!ModelProvider.gemini.isRuninfra)
        #expect(!ModelProvider.gemini.isOpenRouter)
        #expect(ModelProvider.openRouter.isOpenRouter)
        #expect(!ModelProvider.openRouter.isRuninfra)
        #expect(!ModelProvider.openRouter.isGemini)
        #expect(ProviderProfile.runinfra.isRuninfra)
        #expect(ProviderProfile.gemini.isGemini)
        #expect(ProviderProfile.openRouter.isOpenRouter)
        #expect(!ProviderProfile.xai.isRuninfra)
        #expect(!ProviderProfile.codex.isGemini)
        #expect(!ProviderProfile.zai.isOpenRouter)
    }

    @Test("expanded providers expose only Chat Completions")
    func backendContracts() {
        for provider in [ModelProvider.runinfra, .gemini, .openRouter] {
            let profile = provider.profile
            #expect(profile.provider == provider)
            #expect(profile.id == provider.asString)
            #expect(profile.backends.chatCompletions)
            #expect(!profile.backends.messages)
            #expect(profile.backends.responses == nil)
            #expect(profile.supportsBackend(.chatCompletions))
            #expect(!profile.supportsBackend(.responses))
            #expect(!profile.supportsBackend(.messages))
            #expect(profile.responsesDialect == nil)
        }
    }

    @Test("expanded providers never inherit Codex or xAI authentication")
    func credentialIsolation() {
        for provider in [ModelProvider.runinfra, .gemini, .openRouter] {
            let profile = provider.profile
            #expect(profile.sessionAuth == .apiKeyOnly)
            #expect(profile.sessionAuth.isApiKeyOnly)
            #expect(!profile.sessionAuth.isXai)
            #expect(!profile.sessionAuth.isCodex)
            #expect(profile.requestMetadata == .standardHeadersOnly)
            #expect(!profile.requestMetadata.sendsXGrokHeaders)
        }
    }

    @Test("expanded providers cannot expose hosted tools, search, or xAI exports")
    func trustAndCapabilityBoundaries() {
        for provider in [ModelProvider.runinfra, .gemini, .openRouter] {
            let profile = provider.profile
            #expect(profile.codeModeTransport == .unsupported)
            #expect(profile.hostedToolDialect == nil)
            #expect(!profile.nativeWebSearch)
            #expect(!profile.hasNativeWebSearch)
            #expect(profile.xaiServices == .denied)
            #expect(!profile.allowsXaiServices)
        }
    }

    @Test("each canonical provider resolves its exact built-in profile")
    func profileIdentity() {
        #expect(ModelProvider.runinfra.profile == ProviderProfile.runinfra)
        #expect(ModelProvider.gemini.profile == ProviderProfile.gemini)
        #expect(ModelProvider.openRouter.profile == ProviderProfile.openRouter)
    }

    @Test("unknown aliases remain rejected rather than guessing a provider")
    func unknownAliasesFailClosed() {
        for invalid in ["runinfra_api", "google-ai", "gemini_studio", "openrouter_ai"] {
            #expect(throws: DecodingError.self) {
                try decode(invalid)
            }
        }
    }
}
