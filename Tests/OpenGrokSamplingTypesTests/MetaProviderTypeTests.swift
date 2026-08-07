// MetaProviderTypeTests.swift
//
// Meta provider type surface, translated from the upstream identity and
// profile-matrix tests in `crates/codegen/xai-grok-sampling-types/src/types.rs`
// (serde aliases types.rs:1094-1095, names types.rs:1465/1479, META profile
// types.rs:1349-1362, matrix case types.rs:1836-1851).

import Testing
import Foundation
@testable import OpenGrokSamplingTypes

@Suite("Meta provider types")
struct MetaProviderTypeTests {
    private func decode(_ raw: String) throws -> ModelProvider {
        try JSONDecoder().decode(ModelProvider.self, from: Data("\"\(raw)\"".utf8))
    }

    @Test("meta decodes its wire name and upstream serde aliases")
    func decodeAliases() throws {
        // types.rs:1094-1095: `#[serde(alias = "meta_ai", alias = "meta_api")]`.
        #expect(try decode("meta") == .meta)
        #expect(try decode("meta_ai") == .meta)
        #expect(try decode("meta_api") == .meta)
    }

    @Test("meta identity round-trips through its stable wire name")
    func identityRoundTrip() throws {
        #expect(ModelProvider.meta.asString == "meta")
        #expect(ModelProvider.meta.name == "Meta API")

        let encoded = try JSONEncoder().encode(ModelProvider.meta)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"meta\"")
        #expect(try JSONDecoder().decode(ModelProvider.self, from: encoded) == .meta)
    }

    @Test("isMeta discriminates exactly the meta identity")
    func isMetaPredicate() {
        #expect(ModelProvider.meta.isMeta)
        #expect(!ModelProvider.meta.isXai)
        #expect(!ModelProvider.meta.isCodex)
        #expect(!ModelProvider.xai.isMeta)
        #expect(!ModelProvider.deepseek.isMeta)
        #expect(ProviderProfile.meta.isMeta)
        #expect(!ProviderProfile.codex.isMeta)
        #expect(ResponsesDialect.meta.isMeta)
        #expect(!ResponsesDialect.deepSeek.isMeta)
    }

    /// Mirror of the META row in upstream's profile matrix (types.rs:1836-1851).
    @Test("META profile declares the upstream behavior matrix")
    func metaProfileMatrix() {
        let profile = ModelProvider.meta.profile
        #expect(profile == ProviderProfile.meta)
        #expect(profile.provider == .meta)
        #expect(profile.id == "meta")
        #expect(profile.name == "Meta API")

        #expect(!profile.backends.chatCompletions)
        #expect(profile.backends.responses == .meta)
        #expect(!profile.backends.messages)
        #expect(!profile.supportsBackend(.chatCompletions))
        #expect(profile.supportsBackend(.responses))
        #expect(!profile.supportsBackend(.messages))
        #expect(profile.responsesDialect == .meta)

        #expect(profile.codeModeTransport == .functionEnvelope)
        #expect(profile.hostedToolDialect == .openAi)
        #expect(profile.hasNativeWebSearch)
        #expect(profile.requestMetadata == .standardHeadersOnly)
        #expect(profile.sessionAuth == .apiKeyOnly)
        #expect(profile.xaiServices == .denied)
        #expect(!profile.allowsXaiServices)
    }
}
