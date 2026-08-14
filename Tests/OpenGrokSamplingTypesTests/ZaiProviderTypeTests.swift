// ZaiProviderTypeTests.swift
//
// Z AI provider type surface, translated from the upstream identity and
// profile-matrix tests in `crates/codegen/xai-grok-sampling-types/src/types.rs`.

import Testing
import Foundation
@testable import OpenGrokSamplingTypes

@Suite("Z AI provider types")
struct ZaiProviderTypeTests {
    private func decode(_ raw: String) throws -> ModelProvider {
        try JSONDecoder().decode(ModelProvider.self, from: Data("\"\(raw)\"".utf8))
    }

    @Test("zai decodes its wire name and upstream serde aliases")
    func decodeAliases() throws {
        #expect(try decode("zai") == .zai)
        #expect(try decode("z_ai") == .zai)
        #expect(try decode("z-ai") == .zai)
        #expect(try decode("zai_api") == .zai)
        #expect(try decode("glm") == .zai)
    }

    @Test("zai identity round-trips through its stable wire name")
    func identityRoundTrip() throws {
        #expect(ModelProvider.zai.asString == "zai")
        #expect(ModelProvider.zai.name == "Z AI")

        let encoded = try JSONEncoder().encode(ModelProvider.zai)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"zai\"")
        #expect(try JSONDecoder().decode(ModelProvider.self, from: encoded) == .zai)
    }

    @Test("isZai discriminates exactly the zai identity")
    func isZaiPredicate() {
        #expect(ModelProvider.zai.isZai)
        #expect(!ModelProvider.zai.isXai)
        #expect(!ModelProvider.zai.isCodex)
        #expect(!ModelProvider.xai.isZai)
        #expect(!ModelProvider.deepseek.isZai)
        #expect(ProviderProfile.zai.isZai)
        #expect(!ProviderProfile.codex.isZai)
    }

    @Test("ZAI profile declares the upstream behavior matrix")
    func zaiProfileMatrix() {
        let profile = ModelProvider.zai.profile
        #expect(profile == ProviderProfile.zai)
        #expect(profile.provider == .zai)
        #expect(profile.id == "zai")
        #expect(profile.name == "Z AI")

        #expect(profile.backends.chatCompletions)
        #expect(profile.backends.responses == nil)
        #expect(!profile.backends.messages)
        #expect(profile.supportsBackend(.chatCompletions))
        #expect(!profile.supportsBackend(.responses))
        #expect(!profile.supportsBackend(.messages))
        #expect(profile.responsesDialect == nil)

        #expect(profile.codeModeTransport == .unsupported)
        #expect(profile.hostedToolDialect == nil)
        #expect(!profile.hasNativeWebSearch)
        #expect(profile.requestMetadata == .standardHeadersOnly)
        #expect(profile.sessionAuth == .apiKeyOnly)
        #expect(profile.xaiServices == .denied)
        #expect(!profile.allowsXaiServices)
    }

    @Test("ChatThinkingMode encodes and decodes properly")
    func chatThinkingModeCodable() throws {
        let mode = ChatThinkingMode.enabled
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(ChatThinkingMode.self, from: data)
        #expect(decoded.type == .enabled)
        #expect(decoded.clearThinking == false)
    }
}
