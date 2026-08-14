// ZaiModelsTests.swift
//
// Tests for Z AI model catalog discovery, trusted base URLs, fallback models,
// and reasoning effort option matrices.

import Foundation
import Testing
@testable import OpenGrokModels
import OpenGrokSamplingTypes

@Suite("Z AI models catalog")
struct ZaiModelsTests {
    @Test("isTrustedAPIBaseURL validates api.z.ai over https")
    func trustedAPIBaseURL() {
        #expect(ZaiModels.isTrustedAPIBaseURL("https://api.z.ai/api/coding/paas/v4"))
        #expect(ZaiModels.isTrustedAPIBaseURL("https://api.z.ai/api/paas/v4"))
        #expect(ZaiModels.isTrustedAPIBaseURL("https://api.z.ai/v1"))
        #expect(!ZaiModels.isTrustedAPIBaseURL("http://api.z.ai/api/coding/paas/v4"))
        #expect(!ZaiModels.isTrustedAPIBaseURL("https://evil.com/api/coding/paas/v4"))
    }

    @Test("isKnownReasoningModel matches prefixes case-insensitively")
    func reasoningModelDetection() {
        #expect(ZaiModels.isKnownReasoningModel(modelID: "glm-5.2"))
        #expect(ZaiModels.isKnownReasoningModel(modelID: "glm-5-turbo"))
        #expect(ZaiModels.isKnownReasoningModel(modelID: "GLM-5.1"))
        #expect(ZaiModels.isKnownReasoningModel(modelID: "glm-4.7"))
        #expect(ZaiModels.isKnownReasoningModel(modelID: "glm-4.6"))
        #expect(ZaiModels.isKnownReasoningModel(modelID: "glm-4.5"))
        #expect(ZaiModels.isKnownReasoningModel(modelID: "glm-4-32b-0414-128k"))
        #expect(!ZaiModels.isKnownReasoningModel(modelID: "glm-4-flash"))
        #expect(!ZaiModels.isKnownReasoningModel(modelID: "gpt-4o"))
    }

    @Test("reasoning effort options contain Low, Medium, High, Max with High as default")
    func reasoningEffortsOptions() throws {
        let opts = ZaiModels.zaiReasoningEfforts()
        #expect(opts.count == 4)
        #expect(opts.map(\.value) == [.low, .medium, .high, .max])
        #expect(opts.map(\.id) == ["low", "medium", "high", "max"])

        let highOpt = try #require(opts.first { $0.value == .high })
        #expect(highOpt.isDefault)
        #expect(highOpt.label == "High")

        let maxOpt = try #require(opts.first { $0.value == .max })
        #expect(!maxOpt.isDefault)
        #expect(maxOpt.label == "Max")
    }

    @Test("fallback catalog contains all 8 curated models with provider zai and direct tools")
    func fallbackCatalogContents() throws {
        let catalog = ZaiModels.fallbackCatalog(baseURL: ZaiModels.apiBaseURLDefault)
        #expect(catalog.count == 8)
        #expect(ZaiModels.fallbackModelIDs.count == 8)

        for id in ZaiModels.fallbackModelIDs {
            let key = "zai:\(id)"
            let entry = try #require(catalog[key], "missing entry for \(key)")
            #expect(entry.info.provider == .zai)
            #expect(entry.info.apiBackend == .chatCompletions)
            #expect(entry.info.toolMode == .direct)
            #expect(entry.info.supportsReasoningEffort)
            #expect(entry.info.reasoningEffort == .high)
            #expect(entry.info.reasoningEfforts.count == 4)
            #expect(entry.envKey?.primary == ZaiModels.apiKeyEnv)
        }
    }

    @Test("parseCatalog parses wire models or returns fallback on empty")
    func parseCatalog() throws {
        let wireJSON = """
        {
            "data": [
                { "id": "glm-5.2" },
                { "id": "custom-glm-model" }
            ]
        }
        """
        let catalog = try ZaiModels.parseCatalog(
            Data(wireJSON.utf8),
            baseURL: ZaiModels.apiBaseURLDefault
        )
        #expect(catalog.count == 2)
        #expect(catalog["zai:glm-5.2"] != nil)
        #expect(catalog["zai:custom-glm-model"] != nil)

        // Empty data returns fallback catalog
        let emptyJSON = """
        { "data": [] }
        """
        let fallback = try ZaiModels.parseCatalog(
            Data(emptyJSON.utf8),
            baseURL: ZaiModels.apiBaseURLDefault
        )
        #expect(fallback.count == 8)
    }
}
